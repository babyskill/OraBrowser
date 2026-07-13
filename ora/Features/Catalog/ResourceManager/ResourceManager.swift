import AppKit
import Foundation
import OSLog

// MARK: - Hibernation Level

enum HibernationLevel: Int, Codable, Sendable, Comparable {
    case l0Active = 0
    case l1Grace = 1
    case l2Throttled = 2
    case l3Snapshotted = 3
    case l4DeepHibernation = 4
    case l5Recycled = 5

    static func < (lhs: HibernationLevel, rhs: HibernationLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .l0Active: "L0 Active"
        case .l1Grace: "L1 Grace"
        case .l2Throttled: "L2 Throttled"
        case .l3Snapshotted: "L3 Snapshotted"
        case .l4DeepHibernation: "L4 Deep Hibernation"
        case .l5Recycled: "L5 Recycled"
        }
    }
}

// MARK: - Catalog Resource State

struct CatalogResourceState: Sendable {
    let catalogID: CatalogID
    var level: HibernationLevel
    var lastInteractionAt: Date
    var isOccluded: Bool
    var isKey: Bool
    var isPinned: Bool
    var hasActiveActivity: Bool
    var estimatedCost: Double
    var generation: Int

    init(
        catalogID: CatalogID,
        level: HibernationLevel = .l0Active,
        lastInteractionAt: Date = Date(),
        isOccluded: Bool = false,
        isKey: Bool = false,
        isPinned: Bool = false,
        hasActiveActivity: Bool = false,
        estimatedCost: Double = 150.0,
        generation: Int = 1
    ) {
        self.catalogID = catalogID
        self.level = level
        self.lastInteractionAt = lastInteractionAt
        self.isOccluded = isOccluded
        self.isKey = isKey
        self.isPinned = isPinned
        self.hasActiveActivity = hasActiveActivity
        self.estimatedCost = estimatedCost
        self.generation = generation
    }
}

// MARK: - Resource Manager Callbacks

struct ResourceManagerCallbacks {
    var releasePage: (CatalogID) -> Void
    var recyclePageAndShell: (CatalogID) -> Void
    var captureSnapshot: (CatalogID) async -> Void
    var restoreSnapshot: (CatalogID) -> NSImage?

    init(
        releasePage: @escaping (CatalogID) -> Void = { _ in },
        recyclePageAndShell: @escaping (CatalogID) -> Void = { _ in },
        captureSnapshot: @escaping (CatalogID) async -> Void = { _ in },
        restoreSnapshot: @escaping (CatalogID) -> NSImage? = { _ in nil }
    ) {
        self.releasePage = releasePage
        self.recyclePageAndShell = recyclePageAndShell
        self.captureSnapshot = captureSnapshot
        self.restoreSnapshot = restoreSnapshot
    }
}

// MARK: - Resource Manager Diagnostics

struct ResourceManagerDiagnostics: Sendable {
    let budgetMode: RAMBudgetMode
    let pressureLevel: MemoryPressureLevel
    let totalCatalogs: Int
    let levelDistribution: [HibernationLevel: Int]
    let activeEvictions: Int
}

// MARK: - Resource Manager

@MainActor
final class ResourceManager {
    private let logger = Logger(subsystem: "com.orabrowser.app", category: "ResourceManager")

    let policyEngine = ResourcePolicyEngine()
    let pressureMonitor: PressureMonitor
    let snapshotStore: SnapshotStore

    private var states: [CatalogID: CatalogResourceState] = [:]
    private var leases: [CatalogID: Set<ActivityLease>] = [:]
    private var budgetConfig: BudgetConfig
    private var callbacks: ResourceManagerCallbacks
    private var evaluationTimer: Timer?
    private var activeEvictions = 0

    private let evaluationInterval: TimeInterval

    init(
        pressureMonitor: PressureMonitor? = nil,
        snapshotStore: SnapshotStore? = nil,
        budgetConfig: BudgetConfig = BudgetConfig.config(for: RAMBudgetMode.current),
        callbacks: ResourceManagerCallbacks = ResourceManagerCallbacks(),
        evaluationInterval: TimeInterval = 5.0
    ) {
        let pm = pressureMonitor ?? PressureMonitor()
        let ss = snapshotStore ?? SnapshotStore()
        self.pressureMonitor = pm
        self.snapshotStore = ss
        self.budgetConfig = budgetConfig
        self.callbacks = callbacks
        self.evaluationInterval = evaluationInterval

        pm.onPressureChange = { [weak self] level in
            Task { @MainActor in
                self?.handlePressureChange(level)
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard evaluationTimer == nil else { return }
        evaluationTimer = Timer.scheduledTimer(
            withTimeInterval: evaluationInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateAllStates()
            }
        }
        logger.debug("ResourceManager started with mode: \(self.budgetConfig.mode.rawValue, privacy: .public)")
    }

    func stop() {
        evaluationTimer?.invalidate()
        evaluationTimer = nil
        pressureMonitor.stopMonitoring()
        logger.debug("ResourceManager stopped")
    }

    // MARK: - Callbacks Configuration

    func setCallbacks(_ callbacks: ResourceManagerCallbacks) {
        self.callbacks = callbacks
    }

    func updateBudgetConfig(_ config: BudgetConfig) {
        budgetConfig = config
    }

    // MARK: - State Registration

    func register(catalogID: CatalogID, isPinned: Bool = false, estimatedCost: Double = 150.0, generation: Int = 1) {
        guard states[catalogID] == nil else { return }
        states[catalogID] = CatalogResourceState(
            catalogID: catalogID,
            level: .l0Active,
            lastInteractionAt: Date(),
            isOccluded: false,
            isKey: true,
            isPinned: isPinned,
            estimatedCost: estimatedCost,
            generation: generation
        )
        logger.debug("Registered catalog: \(catalogID.rawValue, privacy: .public)")
    }

    func unregister(catalogID: CatalogID) {
        states.removeValue(forKey: catalogID)
        logger.debug("Unregistered catalog: \(catalogID.rawValue, privacy: .public)")
    }

    // MARK: - Event Handling

    func handleFocusGained(catalogID: CatalogID) {
        guard var state = states[catalogID] else { return }
        state.isKey = true
        state.lastInteractionAt = Date()
        state.isOccluded = false
        states[catalogID] = state
        promoteIfNeeded(catalogID: catalogID)
    }

    func handleFocusLost(catalogID: CatalogID) {
        guard var state = states[catalogID] else { return }
        state.isKey = false
        state.lastInteractionAt = Date()
        states[catalogID] = state
    }

    func handleOcclusionChange(catalogID: CatalogID, isOccluded: Bool) {
        guard var state = states[catalogID] else { return }
        state.isOccluded = isOccluded
        if isOccluded {
            state.lastInteractionAt = Date()
        }
        states[catalogID] = state
    }

    func handleInteraction(catalogID: CatalogID) {
        guard var state = states[catalogID] else { return }
        state.lastInteractionAt = Date()
        states[catalogID] = state
        if state.level >= .l1Grace {
            promoteIfNeeded(catalogID: catalogID)
        }
    }

    func setPinned(_ pinned: Bool, for catalogID: CatalogID) {
        guard var state = states[catalogID] else { return }
        state.isPinned = pinned
        states[catalogID] = state
    }

    func setActiveActivity(_ active: Bool, for catalogID: CatalogID) {
        guard var state = states[catalogID] else { return }
        state.hasActiveActivity = active
        states[catalogID] = state
    }

    func updateGeneration(_ generation: Int, for catalogID: CatalogID) {
        guard var state = states[catalogID] else { return }
        state.generation = generation
        states[catalogID] = state
    }

    // MARK: - Lease Management

    func acquireLease(
        for catalogID: CatalogID,
        type: LeaseType,
        duration: TimeInterval,
        metadata: [String: String] = [:]
    ) {
        let lease = ActivityLease(
            catalogID: catalogID,
            type: type,
            expiresAt: Date().addingTimeInterval(duration),
            metadata: metadata
        )
        var set = leases[catalogID] ?? []
        set = set.filter { $0.type != type }
        set.insert(lease)
        leases[catalogID] = set
        updateActivityState(for: catalogID)
        logger.debug("Lease acquired: \(type.rawValue, privacy: .public) for \(catalogID.rawValue, privacy: .public)")
    }

    func releaseLease(for catalogID: CatalogID, type: LeaseType) {
        guard var set = leases[catalogID] else { return }
        set = set.filter { $0.type != type }
        leases[catalogID] = set.isEmpty ? nil : set
        updateActivityState(for: catalogID)
        logger.debug("Lease released: \(type.rawValue, privacy: .public) for \(catalogID.rawValue, privacy: .public)")
    }

    func hasActiveLeases(for catalogID: CatalogID) -> Bool {
        guard var set = leases[catalogID] else { return false }
        set = set.filter { !$0.isExpired }
        leases[catalogID] = set.isEmpty ? nil : set
        return !set.isEmpty
    }

    // MARK: - Query

    func state(for catalogID: CatalogID) -> CatalogResourceState? {
        states[catalogID]
    }

    func currentLevel(for catalogID: CatalogID) -> HibernationLevel? {
        states[catalogID]?.level
    }

    func livePageCount() -> Int {
        states.values.filter { $0.level < .l4DeepHibernation }.count
    }

    func diagnostics() -> ResourceManagerDiagnostics {
        var distribution: [HibernationLevel: Int] = [:]
        for level in HibernationLevel.allCases {
            distribution[level] = states.values.filter { $0.level == level }.count
        }
        return ResourceManagerDiagnostics(
            budgetMode: budgetConfig.mode,
            pressureLevel: pressureMonitor.currentLevel,
            totalCatalogs: states.count,
            levelDistribution: distribution,
            activeEvictions: activeEvictions
        )
    }

    // MARK: - Private: Evaluation

    private func updateActivityState(for catalogID: CatalogID) {
        let active = hasActiveLeases(for: catalogID)
        setActiveActivity(active, for: catalogID)
    }

    private func evaluateAllStates() {
        let now = Date()
        let pressureLevel = pressureMonitor.currentLevel

        for (catalogID, state) in states where state.level < .l5Recycled {
            guard !hasActiveLeases(for: catalogID) else { continue }

            let nextLevel = policyEngine.nextLevel(
                from: state.level,
                state: state,
                config: budgetConfig,
                now: now,
                pressureLevel: pressureLevel
            )

            guard nextLevel != state.level else { continue }

            var updated = state
            updated.level = nextLevel
            states[catalogID] = updated
            logger.debug("Catalog \(catalogID.rawValue, privacy: .public) → \(nextLevel.label, privacy: .public)")

            executeLevelAction(catalogID: catalogID, from: state.level, to: nextLevel)
        }

        enforceBudget()
    }

    private func promoteIfNeeded(catalogID: CatalogID) {
        guard let state = states[catalogID] else { return }
        let promoted = policyEngine.promoteLevel(from: state.level, state: state)
        guard promoted != state.level else { return }

        var updated = state
        updated.level = promoted
        states[catalogID] = updated
        logger
            .debug("Catalog \(catalogID.rawValue, privacy: .public) ↑ promoted to \(promoted.label, privacy: .public)")

        if promoted <= .l2Throttled {
            restoreFromSnapshotIfNeeded(catalogID: catalogID, level: promoted)
        }
    }

    private func enforceBudget() {
        let liveCount = livePageCount()
        guard liveCount > budgetConfig.maxLivePages else { return }

        let excess = liveCount - budgetConfig.maxLivePages
        let candidates = policyEngine.evictionCandidates(
            from: Array(states.values),
            count: excess,
            pressureLevel: pressureMonitor.currentLevel,
            now: Date()
        )

        for catalogID in candidates {
            evictToL4(catalogID: catalogID)
        }
    }

    private func executeLevelAction(
        catalogID: CatalogID,
        from oldLevel: HibernationLevel,
        to newLevel: HibernationLevel
    ) {
        switch newLevel {
        case .l3Snapshotted:
            if oldLevel < .l3Snapshotted {
                Task { @MainActor [weak self] in
                    await self?.callbacks.captureSnapshot(catalogID)
                }
            }

        case .l4DeepHibernation:
            if oldLevel < .l4DeepHibernation {
                Task { @MainActor [weak self] in
                    await self?.callbacks.captureSnapshot(catalogID)
                }
                callbacks.releasePage(catalogID)
                activeEvictions += 1
                logger.info("L4: Released page for \(catalogID.rawValue, privacy: .public)")
            }

        case .l5Recycled:
            if oldLevel < .l4DeepHibernation {
                Task { @MainActor [weak self] in
                    await self?.callbacks.captureSnapshot(catalogID)
                }
                callbacks.releasePage(catalogID)
            }
            callbacks.recyclePageAndShell(catalogID)
            activeEvictions += 1
            logger.info("L5: Recycled page+shell for \(catalogID.rawValue, privacy: .public)")

        default:
            break
        }
    }

    private func evictToL4(catalogID: CatalogID) {
        guard var state = states[catalogID], state.level < .l4DeepHibernation else { return }
        guard !hasActiveLeases(for: catalogID) else { return }

        state.level = .l4DeepHibernation
        states[catalogID] = state

        Task { @MainActor [weak self] in
            await self?.callbacks.captureSnapshot(catalogID)
        }
        callbacks.releasePage(catalogID)
        activeEvictions += 1
        logger.info("Budget eviction: L4 for \(catalogID.rawValue, privacy: .public)")
    }

    private func restoreFromSnapshotIfNeeded(catalogID: CatalogID, level: HibernationLevel) {
        guard level <= .l2Throttled else { return }
        let image = callbacks.restoreSnapshot(catalogID)
        if image != nil {
            logger.debug("Restored snapshot for \(catalogID.rawValue, privacy: .public)")
        }
    }

    // MARK: - Private: Pressure Response

    private func handlePressureChange(_ level: MemoryPressureLevel) {
        logger.warning("Memory pressure: \(String(describing: level), privacy: .public)")

        switch level {
        case .critical:
            executeEmergencyEviction()
        case .warning:
            trimNonEssentialWindows()
        case .normal:
            break
        }
    }

    private func executeEmergencyEviction() {
        let candidates = policyEngine.evictionCandidates(
            from: Array(states.values),
            count: max(1, states.count / 2),
            pressureLevel: .critical,
            now: Date()
        )
        for catalogID in candidates {
            evictToL4(catalogID: catalogID)
        }
    }

    private func trimNonEssentialWindows() {
        let candidates = policyEngine.evictionCandidates(
            from: Array(states.values),
            count: max(1, states.count / 4),
            pressureLevel: .warning,
            now: Date()
        )
        for catalogID in candidates {
            if let state = states[catalogID], state.level < .l3Snapshotted {
                var updated = state
                updated.level = .l3Snapshotted
                states[catalogID] = updated
                Task { @MainActor [weak self] in
                    await self?.callbacks.captureSnapshot(catalogID)
                }
            }
        }
    }
}

// MARK: - HibernationLevel CaseIterable

extension HibernationLevel: CaseIterable {}
