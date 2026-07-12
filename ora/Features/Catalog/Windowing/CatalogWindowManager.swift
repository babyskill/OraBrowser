import AppKit
import Foundation
import OSLog

@MainActor
final class CatalogWindowManager {
    private let registry: CatalogRegistryProtocol
    private let layoutManager: WindowLayoutManager
    private let rootFactory: CatalogRootFactory
    private let dependenciesFactory: CatalogDependenciesFactory
    private let windowPool: WindowPool
    private let webRuntime: WebRuntime
    private let resetContract: ShellResetContract
    private let snapshotOverlayEnabled: Bool
    private let logger = Logger(subsystem: "com.orabrowser.app", category: "CatalogWindowManager")

    private var windowLeases: [CatalogID: WindowLease] = [:]
    private var pageLeases: [CatalogID: PageLease] = [:]
    private var shellStates: [CatalogID: CatalogShellState] = [:]

    init(
        registry: CatalogRegistryProtocol,
        layoutManager: WindowLayoutManager,
        rootFactory: @escaping CatalogRootFactory,
        dependenciesFactory: @escaping CatalogDependenciesFactory,
        windowPool: WindowPool,
        webRuntime: WebRuntime,
        resetContract: ShellResetContract,
        snapshotOverlayEnabled: Bool
    ) {
        self.registry = registry
        self.layoutManager = layoutManager
        self.rootFactory = rootFactory
        self.dependenciesFactory = dependenciesFactory
        self.windowPool = windowPool
        self.webRuntime = webRuntime
        self.resetContract = resetContract
        self.snapshotOverlayEnabled = snapshotOverlayEnabled
    }

    func open(_ request: OpenCatalogRequest) throws -> CatalogID {
        let fingerprint = normalizedFingerprint(request.configurationFingerprint)
        let snapshot = try registry.create(CreateCatalogRequest(
            startURL: request.startURL,
            profileID: request.profileID,
            isPrivate: request.isPrivate,
            configurationFingerprint: fingerprint,
            placement: request.preferredPlacement,
            workspaceID: nil
        ))
        try present(snapshot, placement: request.preferredPlacement)
        return snapshot.id
    }

    func restore(_ snapshot: CatalogSnapshot) throws {
        guard windowLeases[snapshot.id] == nil else {
            try focus(snapshot.id)
            return
        }
        try present(snapshot, placement: snapshot.placement)
    }

    func focus(_ id: CatalogID) throws {
        guard let lease = windowLeases[id], lease.isActive else {
            throw CatalogWindowError.catalogNotFound(id)
        }
        lease.orderFront()
    }

    func reload(_ id: CatalogID) {
        guard let pageLease = pageLeases[id], pageLease.state == .active else { return }
        shellStates[id]?.setOverlayState(snapshotOverlayEnabled ? .skeleton : .blank)
        pageLease.reload()
    }

    func navigate(_ id: CatalogID, to url: URL) throws {
        guard let windowLease = windowLeases[id], let pageLease = pageLeases[id] else {
            throw CatalogWindowError.catalogNotFound(id)
        }
        pageLease.load(URLRequest(url: url))
        try registry.updateNavigation(CatalogNavigationUpdate(
            catalogID: id,
            currentURL: url,
            title: nil,
            generation: windowLease.generation
        ))
    }

    func focusLocation(_ id: CatalogID) {
        guard let window = windowLeases[id]?.controller?.window else { return }
        NotificationCenter.default.post(name: .showLauncher, object: window)
    }

    func toggleFullScreen(_ id: CatalogID) {
        windowLeases[id]?.controller?.window?.toggleFullScreen(nil)
    }

    func close(_ id: CatalogID, reason: CloseReason = .userInitiated) async {
        guard let windowLease = windowLeases[id] else { return }

        do {
            try registry.markClosed(id, generation: windowLease.generation)
        } catch {
            logger.error("Failed to persist catalog close: \(String(describing: error), privacy: .public)")
        }

        shellStates[id]?.setOverlayState(.blank)
        windowLease.controller?.window?.orderOut(nil)

        if let pageLease = pageLeases.removeValue(forKey: id) {
            windowLease.detachPage(expectedPageLeaseID: pageLease.id)
            webRuntime.releasePage(pageLease, reason: releaseReason(for: reason))
        }

        guard windowLeases[id]?.id == windowLease.id else { return }
        windowLeases.removeValue(forKey: id)
        shellStates.removeValue(forKey: id)
        await windowPool.release(windowLease, reason: windowReleaseReason(for: reason))
    }

    func closeAll(reason: CloseReason) async {
        for id in Array(windowLeases.keys) {
            await close(id, reason: reason)
        }
    }

    func catalogID(for window: NSWindow?) -> CatalogID? {
        guard let window else { return nil }
        return windowLeases.first { $0.value.controller?.window === window }?.key
    }

    private func present(_ snapshot: CatalogSnapshot, placement: CatalogWindowPlacement?) throws {
        guard windowLeases[snapshot.id] == nil else {
            throw CatalogWindowError.duplicateCatalog(snapshot.id)
        }

        let lease = try windowPool.acquire(WindowAcquireRequest(
            catalogID: snapshot.id,
            generation: snapshot.generation,
            shellCompatibility: .current,
            placement: placement
        ))
        let controller = CatalogWindowController(shell: lease.shell, layoutManager: layoutManager)
        lease.attach(controller: controller)

        let context = CatalogWindowContext(
            catalogID: snapshot.id,
            profileID: snapshot.profileID,
            generation: snapshot.generation
        )
        let actions = makeActions(catalogID: snapshot.id)
        let binding = CatalogShellBinding(
            catalogID: snapshot.id,
            generation: snapshot.generation,
            profileID: snapshot.profileID,
            title: snapshot.title,
            startURL: snapshot.currentURL,
            isPrivate: snapshot.isPrivate,
            configurationFingerprint: snapshot.configurationFingerprint,
            windowPlacement: placement
        )
        let state = CatalogShellState(
            binding: binding,
            context: context,
            actions: actions,
            dependencies: dependenciesFactory(context)
        )
        state.setOverlayState(snapshotOverlayEnabled ? .skeleton : .blank)

        controller.bind(
            catalogID: snapshot.id,
            generation: snapshot.generation,
            windowLeaseID: lease.id,
            placement: placement,
            eventSink: self,
            rootFactory: rootFactory,
            state: state,
            layoutManager: layoutManager
        )

        do {
            try registry.markVisible(snapshot.id, generation: snapshot.generation)
        } catch {
            lease.destroy(reason: .compatibilityInvalidated)
            throw error
        }

        lease.setState(.visible)
        windowLeases[snapshot.id] = lease
        shellStates[snapshot.id] = state
        lease.orderFront()
        acquirePage(for: snapshot, windowLease: lease)
    }

    private func acquirePage(for snapshot: CatalogSnapshot, windowLease: WindowLease) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let pageLease = try webRuntime.acquirePage(for: PageAcquireRequest(
                    catalogID: snapshot.id,
                    generation: snapshot.generation,
                    profileID: snapshot.profileID,
                    isPrivate: snapshot.isPrivate,
                    configurationFingerprint: snapshot.configurationFingerprint
                ))
                guard isCurrent(windowLease, catalogID: snapshot.id) else {
                    webRuntime.releasePage(pageLease, reason: .recycle)
                    return
                }

                pageLease.onReady = { [weak self] pageLeaseID in
                    self?.showLiveSurface(
                        catalogID: snapshot.id,
                        windowLeaseID: windowLease.id,
                        pageLeaseID: pageLeaseID,
                        generation: snapshot.generation
                    )
                }
                pageLease.onLoadError = { [weak self] pageLeaseID, error, _ in
                    self?.showPageError(
                        error,
                        catalogID: snapshot.id,
                        windowLeaseID: windowLease.id,
                        pageLeaseID: pageLeaseID,
                        generation: snapshot.generation
                    )
                }
                pageLeases[snapshot.id] = pageLease
                try windowLease.attach(pageLease)
                pageLease.load(URLRequest(url: snapshot.currentURL))
            } catch {
                guard isCurrent(windowLease, catalogID: snapshot.id) else { return }
                shellStates[snapshot.id]?.setOverlayState(.error(CatalogSurfaceError(
                    message: "Unable to open this page.",
                    isRetryable: true
                )))
                logger.error("Page acquisition failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func showLiveSurface(
        catalogID: CatalogID,
        windowLeaseID: WindowLeaseID,
        pageLeaseID: PageLeaseID,
        generation: Int
    ) {
        guard let windowLease = windowLeases[catalogID],
              windowLease.id == windowLeaseID,
              windowLease.generation == generation,
              pageLeases[catalogID]?.id == pageLeaseID
        else { return }

        shellStates[catalogID]?.setOverlayState(.fadingToLive(pageLeaseID: pageLeaseID))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self,
                  self.windowLeases[catalogID]?.id == windowLeaseID,
                  self.pageLeases[catalogID]?.id == pageLeaseID
            else { return }
            self.shellStates[catalogID]?.setOverlayState(.live)
        }
    }

    private func showPageError(
        _ error: Error,
        catalogID: CatalogID,
        windowLeaseID: WindowLeaseID,
        pageLeaseID: PageLeaseID,
        generation: Int
    ) {
        guard windowLeases[catalogID]?.id == windowLeaseID,
              windowLeases[catalogID]?.generation == generation,
              pageLeases[catalogID]?.id == pageLeaseID
        else { return }
        shellStates[catalogID]?.setOverlayState(.error(CatalogSurfaceError(
            message: error.localizedDescription,
            isRetryable: true
        )))
    }

    private func makeActions(catalogID: CatalogID) -> CatalogShellActions {
        CatalogShellActions(
            close: { [weak self] in
                Task { @MainActor in await self?.close(catalogID) }
            },
            reload: { [weak self] in self?.reload(catalogID) },
            focusLocation: { [weak self] in self?.focusLocation(catalogID) },
            toggleFullScreen: { [weak self] in self?.toggleFullScreen(catalogID) }
        )
    }

    private func isCurrent(_ lease: WindowLease, catalogID: CatalogID) -> Bool {
        windowLeases[catalogID]?.id == lease.id && windowLeases[catalogID]?.generation == lease.generation
    }

    private func normalizedFingerprint(_ fingerprint: String) -> String {
        guard fingerprint.isEmpty else { return fingerprint }
        return BrowserPageConfiguration.oraDefault(
            userScripts: [],
            privacySettings: SpacePrivacySettings()
        ).fingerprint
    }

    private func releaseReason(for reason: CloseReason) -> PageLeaseReleaseReason {
        reason == .terminate ? .terminate : .close
    }

    private func windowReleaseReason(for reason: CloseReason) -> WindowLeaseReleaseReason {
        switch reason {
        case .userInitiated: .userClose
        case .terminate: .terminate
        case .allWindows: .allWindows
        }
    }
}

extension CatalogWindowManager: CatalogWindowEventSink {
    func handle(_ event: CatalogWindowEvent) {
        switch event {
        case .didBecomeKey, .didResignKey:
            break
        case let .didMoveOrResize(id, generation, leaseID, frame, screenID):
            guard windowLeases[id]?.id == leaseID, windowLeases[id]?.generation == generation else { return }
            persistPlacement(id: id, generation: generation, frame: frame, screenID: screenID, isFullScreen: false)
        case let .didChangeFullScreen(id, generation, leaseID, isFullScreen):
            guard let lease = windowLeases[id], lease.id == leaseID, lease.generation == generation else { return }
            let frame = lease.controller?.window?.frame ?? .zero
            persistPlacement(id: id, generation: generation, frame: frame, screenID: nil, isFullScreen: isFullScreen)
        case let .didMiniaturize(id, generation, leaseID):
            guard windowLeases[id]?.id == leaseID else { return }
            do {
                try registry.markHidden(id, generation: generation)
            } catch {
                logger.error("Failed to persist hidden catalog: \(String(describing: error), privacy: .public)")
            }
        case let .closeRequested(id, generation, leaseID):
            guard windowLeases[id]?.id == leaseID, windowLeases[id]?.generation == generation else { return }
            Task { @MainActor [weak self] in await self?.close(id) }
        case let .didClose(id, generation, leaseID):
            guard windowLeases[id]?.id == leaseID, windowLeases[id]?.generation == generation else { return }
            Task { @MainActor [weak self] in await self?.close(id) }
        }
    }

    private func persistPlacement(
        id: CatalogID,
        generation: Int,
        frame: CGRect,
        screenID: String?,
        isFullScreen: Bool
    ) {
        do {
            try registry.updateLayout(CatalogLayoutUpdate(
                catalogID: id,
                placement: CatalogWindowPlacement(
                    frameX: frame.origin.x,
                    frameY: frame.origin.y,
                    frameWidth: frame.width,
                    frameHeight: frame.height,
                    screenID: screenID,
                    isFullScreen: isFullScreen
                ),
                generation: generation
            ))
        } catch {
            logger.error("Failed to persist catalog placement: \(String(describing: error), privacy: .public)")
        }
    }
}
