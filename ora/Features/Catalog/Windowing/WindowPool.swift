import AppKit
import Foundation

@MainActor
final class ReusableWindowShell {
    let shellID: ShellID
    let compatibility: ShellCompatibility
    let window: NSWindow
    let pageHostView: NSView

    private(set) var isWarm: Bool
    private(set) var createdAt: Date
    private(set) var lastTouchedAt: Date

    private var hostingController: NSViewController?

    init(
        shellID: ShellID = ShellID(),
        compatibility: ShellCompatibility = .current,
        window: NSWindow,
        pageHostView: NSView = NSView()
    ) {
        self.shellID = shellID
        self.compatibility = compatibility
        self.window = window
        self.pageHostView = pageHostView
        self.isWarm = true
        self.createdAt = Date()
        self.lastTouchedAt = Date()
        pageHostView.autoresizingMask = [.width, .height]
    }

    func setHostingController(_ controller: NSViewController?) {
        hostingController = controller
        window.contentViewController = controller
    }

    func makeNeutralContent() {
        guard window.contentViewController == hostingController else { return }
        let vc = NSViewController()
        vc.view = NSView(frame: window.contentView?.bounds ?? .zero)
        setHostingController(vc)
    }

    func clearPageHost() {
        pageHostView.subviews.forEach { $0.removeFromSuperview() }
    }

    func markCold() {
        isWarm = false
        touch()
    }

    func markWarm() {
        isWarm = true
        touch()
    }

    func touch() {
        lastTouchedAt = Date()
    }

    func destroy() {
        clearPageHost()
        setHostingController(nil)
        window.delegate = nil
        window.close()
    }

    func isStale(_ referenceDate: Date, ttl: TimeInterval) -> Bool {
        return referenceDate.timeIntervalSince(lastTouchedAt) > ttl
    }
}

// MARK: - Window Pool Diagnostics

struct WindowPoolDiagnostics: Sendable {
    let warmShellCount: Int
    let coldShellCount: Int
    let warmCapacity: Int
    let coldCapacity: Int
    let warmTTLSeconds: TimeInterval
    let coldTTLSeconds: TimeInterval
    let totalAcquires: Int
    let warmHits: Int
    let coldHits: Int
    let misses: Int
    let resetFailures: Int
    let overflows: Int
}

// MARK: - Pool Capacity Config

struct WindowPoolCapacity: Sendable {
    let warmMax: Int
    let coldMax: Int

    static func `default`() -> WindowPoolCapacity {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let gb = Double(physicalMemory) / 1_073_741_824.0
        switch gb {
        case ..<12:
            return WindowPoolCapacity(warmMax: 2, coldMax: 4)
        case ..<28:
            return WindowPoolCapacity(warmMax: 4, coldMax: 8)
        default:
            return WindowPoolCapacity(warmMax: 6, coldMax: 12)
        }
    }
}

enum WindowPoolTrimReason: Sendable {
    case memoryPressure
    case thermalSerious
    case appBackground
    case terminate
}

struct ShellDescriptor: Hashable, Sendable {
    let shellID: ShellID
    let compatibility: ShellCompatibility
    let isWarm: Bool
    let createdAt: Date
    let lastTouchedAt: Date
}

// MARK: - Window Pool

@MainActor
final class WindowPool {
    private var warmStacks: [ShellCompatibility: [ReusableWindowShell]] = [:]
    private var coldStacks: [ShellCompatibility: [ReusableWindowShell]] = [:]
    private let warmTTL: TimeInterval = 300
    private let coldTTL: TimeInterval = 1200

    private let resetContract: ShellResetContract
    private var capacity: WindowPoolCapacity
    private let enabled: Bool

    private var totalAcquires = 0
    private var warmHits = 0
    private var coldHits = 0
    private var misses = 0
    private var resetFailures = 0
    private var overflows = 0

    init(resetContract: ShellResetContract, capacity: WindowPoolCapacity = .default(), enabled: Bool = true) {
        self.resetContract = resetContract
        self.capacity = capacity
        self.enabled = enabled
    }

    // MARK: - Acquire

    func acquire(_ request: WindowAcquireRequest) throws -> WindowLease {
        totalAcquires += 1

        if !enabled {
            misses += 1
            let shell = createShell(compatibility: request.shellCompatibility)
            let lease = WindowLease(
                shellID: shell.shellID,
                catalogID: request.catalogID,
                generation: request.generation,
                compatibility: request.shellCompatibility,
                shell: shell
            )
            lease.setState(.binding)
            return lease
        }

        if let shell = popWarm(compatibility: request.shellCompatibility) {
            warmHits += 1
            shell.touch()
            let lease = WindowLease(
                shellID: shell.shellID,
                catalogID: request.catalogID,
                generation: request.generation,
                compatibility: request.shellCompatibility,
                shell: shell
            )
            lease.setState(.binding)
            return lease
        }

        if let shell = popCold(compatibility: request.shellCompatibility) {
            coldHits += 1
            shell.markWarm()
            shell.touch()
            let lease = WindowLease(
                shellID: shell.shellID,
                catalogID: request.catalogID,
                generation: request.generation,
                compatibility: request.shellCompatibility,
                shell: shell
            )
            lease.setState(.binding)
            return lease
        }

        misses += 1
        let shell = createShell(compatibility: request.shellCompatibility)
        let lease = WindowLease(
            shellID: shell.shellID,
            catalogID: request.catalogID,
            generation: request.generation,
            compatibility: request.shellCompatibility,
            shell: shell
        )
        lease.setState(.binding)
        return lease
    }

    // MARK: - Release

    func release(_ lease: WindowLease, reason: WindowLeaseReleaseReason) async {
        lease.beginRelease()

        guard enabled else {
            lease.clearBinding()
            lease.destroy(reason: .terminate)
            return
        }

        let context = ShellReleaseContext(
            windowLeaseID: lease.id,
            catalogID: lease.catalogID,
            generation: lease.generation,
            reason: reason
        )
        resetContract.prepareForRelease(context)
        lease.shell.window.makeFirstResponder(nil)
        lease.shell.window.orderOut(nil)
        let report = await resetContract.reset(lease.shell)

        lease.setState(.reset)

        do {
            let clean = resetContract.validateClean(lease.shell)
            guard report.isClean, clean.isClean else {
                resetFailures += 1
                lease.destroy(reason: .resetFailed(report))
                return
            }
        }

        lease.clearBinding()
        lease.setState(.pooled)
        await enqueue(lease.shell)
    }

    private func enqueue(_ shell: ReusableWindowShell) async {
        shell.markWarm()
        shell.makeNeutralContent()
        shell.touch()

        if totalWarmCount() < capacity.warmMax {
            var list = warmStacks[shell.compatibility] ?? []
            list.append(shell)
            warmStacks[shell.compatibility] = list
            return
        }

        if totalColdCount() < capacity.coldMax {
            shell.markCold()
            var list = coldStacks[shell.compatibility] ?? []
            list.append(shell)
            coldStacks[shell.compatibility] = list
            return
        }

        overflows += 1
        shell.destroy()
    }

    // MARK: - Trim

    func trim(to target: WindowPoolCapacity, reason: WindowPoolTrimReason) {
        capacity = target
        trimOverflow(reason: reason)
        trimExpired(reason: reason)
    }

    private func trimOverflow(reason: WindowPoolTrimReason) {
        while totalWarmCount() > capacity.warmMax {
            if let shell = popOldestWarm() {
                shell.destroy()
            }
        }

        while totalColdCount() > capacity.coldMax {
            if let shell = popOldestCold() {
                shell.destroy()
            }
        }

        if reason != .terminate { return }
        for shell in allShells() {
            shell.markCold()
            shell.destroy()
        }
        warmStacks.removeAll()
        coldStacks.removeAll()
    }

    func invalidate(where predicate: (ShellDescriptor) -> Bool) {
        warmStacks = warmStacks.compactMapValues { shells in
            let filtered = shells.filter { shell in
                let descriptor = ShellDescriptor(
                    shellID: shell.shellID,
                    compatibility: shell.compatibility,
                    isWarm: true,
                    createdAt: shell.createdAt,
                    lastTouchedAt: shell.lastTouchedAt
                )
                if predicate(descriptor) {
                    shell.destroy()
                    return false
                }
                return true
            }
            return filtered.isEmpty ? nil : filtered
        }

        coldStacks = coldStacks.compactMapValues { shells in
            let filtered = shells.filter { shell in
                let descriptor = ShellDescriptor(
                    shellID: shell.shellID,
                    compatibility: shell.compatibility,
                    isWarm: false,
                    createdAt: shell.createdAt,
                    lastTouchedAt: shell.lastTouchedAt
                )
                if predicate(descriptor) {
                    shell.destroy()
                    return false
                }
                return true
            }
            return filtered.isEmpty ? nil : filtered
        }
    }

    func diagnostics() -> WindowPoolDiagnostics {
        WindowPoolDiagnostics(
            warmShellCount: totalWarmCount(),
            coldShellCount: totalColdCount(),
            warmCapacity: capacity.warmMax,
            coldCapacity: capacity.coldMax,
            warmTTLSeconds: warmTTL,
            coldTTLSeconds: coldTTL,
            totalAcquires: totalAcquires,
            warmHits: warmHits,
            coldHits: coldHits,
            misses: misses,
            resetFailures: resetFailures,
            overflows: overflows
        )
    }

    func drain() {
        for shell in allShells() {
            shell.destroy()
        }
        warmStacks.removeAll()
        coldStacks.removeAll()
    }

    // MARK: - Private

    private func popWarm(compatibility: ShellCompatibility) -> ReusableWindowShell? {
        guard var shells = warmStacks[compatibility], !shells.isEmpty else { return nil }
        let shell = shells.removeLast()
        if shells.isEmpty {
            warmStacks[compatibility] = nil
        } else {
            warmStacks[compatibility] = shells
        }
        return shell
    }

    private func popCold(compatibility: ShellCompatibility) -> ReusableWindowShell? {
        guard var shells = coldStacks[compatibility], !shells.isEmpty else { return nil }
        let shell = shells.removeLast()
        if shells.isEmpty {
            coldStacks[compatibility] = nil
        } else {
            coldStacks[compatibility] = shells
        }
        return shell
    }

    private func popOldestWarm() -> ReusableWindowShell? {
        var foundDate = Date.distantFuture
        var found: (ShellCompatibility, Int)?

        for (compatibility, shells) in warmStacks {
            for (index, shell) in shells.enumerated() {
                if shell.lastTouchedAt < foundDate {
                    foundDate = shell.lastTouchedAt
                    found = (compatibility, index)
                }
            }
        }

        guard let (candidateCompat, candidateIndex) = found else { return nil }
        let candidate = warmStacks[candidateCompat]?.remove(at: candidateIndex)
        if warmStacks[candidateCompat]?.isEmpty == true {
            warmStacks[candidateCompat] = nil
        }
        return candidate
    }

    private func popOldestCold() -> ReusableWindowShell? {
        var foundDate = Date.distantFuture
        var found: (ShellCompatibility, Int)?

        for (compatibility, shells) in coldStacks {
            for (index, shell) in shells.enumerated() {
                if shell.lastTouchedAt < foundDate {
                    foundDate = shell.lastTouchedAt
                    found = (compatibility, index)
                }
            }
        }

        guard let (candidateCompat, candidateIndex) = found else { return nil }
        let candidate = coldStacks[candidateCompat]?.remove(at: candidateIndex)
        if coldStacks[candidateCompat]?.isEmpty == true {
            coldStacks[candidateCompat] = nil
        }
        return candidate
    }

    private func totalWarmCount() -> Int {
        warmStacks.values.reduce(0) { $0 + $1.count }
    }

    private func totalColdCount() -> Int {
        coldStacks.values.reduce(0) { $0 + $1.count }
    }

    private func allShells() -> [ReusableWindowShell] {
        warmStacks.values.flatMap { $0 } + coldStacks.values.flatMap { $0 }
    }

    private func createShell(compatibility: ShellCompatibility) -> ReusableWindowShell {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 500, height: 360)
        window.collectionBehavior = [.fullScreenPrimary]
        window.level = .normal

        let host = NSView(frame: window.contentView?.bounds ?? .zero)
        host.autoresizingMask = [.width, .height]
        window.contentView = host

        let shell = ReusableWindowShell(
            compatibility: compatibility,
            window: window,
            pageHostView: NSView(frame: host.bounds)
        )
        shell.pageHostView.frame = host.bounds
        return shell
    }

    private func trimExpired(reason: WindowPoolTrimReason) {
        _ = reason
        let now = Date()

        for (compatibility, shells) in warmStacks {
            var filtered = shells
            filtered.removeAll { shell in
                if shell.isStale(now, ttl: warmTTL) {
                    shell.destroy()
                    return true
                }
                return false
            }
            warmStacks[compatibility] = filtered.isEmpty ? nil : filtered
        }

        for (compatibility, shells) in coldStacks {
            var filtered = shells
            filtered.removeAll { shell in
                if shell.isStale(now, ttl: coldTTL) {
                    shell.destroy()
                    return true
                }
                return false
            }
            coldStacks[compatibility] = filtered.isEmpty ? nil : filtered
        }
    }
}
