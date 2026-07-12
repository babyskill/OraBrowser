import AppKit
import Foundation

@MainActor
final class CatalogWindowManager {
    private let registry: CatalogRegistryProtocol
    private let layoutManager: WindowLayoutManager
    private let rootFactory: CatalogRootFactory

    private var controllersByCatalog: [CatalogID: CatalogWindowController] = [:]
    private var catalogByWindow: [ObjectIdentifier: CatalogID] = [:]

    init(
        registry: CatalogRegistryProtocol,
        layoutManager: WindowLayoutManager,
        rootFactory: @escaping CatalogRootFactory
    ) {
        self.registry = registry
        self.layoutManager = layoutManager
        self.rootFactory = rootFactory
    }

    // MARK: - API

    func open(_ request: OpenCatalogRequest) throws -> CatalogID {
        let create = CreateCatalogRequest(
            startURL: request.startURL,
            profileID: request.profileID,
            isPrivate: request.isPrivate,
            configurationFingerprint: request.configurationFingerprint,
            placement: request.preferredPlacement,
            workspaceID: nil
        )
        let snapshot = try registry.create(create)
        try makeController(for: snapshot)
        try registry.markVisible(snapshot.id, generation: snapshot.generation)
        return snapshot.id
    }

    func restore(_ snapshot: CatalogSnapshot) throws {
        guard controllersByCatalog[snapshot.id] == nil else {
            try focus(snapshot.id)
            return
        }
        try makeController(for: snapshot)
        try registry.markVisible(snapshot.id, generation: snapshot.generation)
    }

    func focus(_ id: CatalogID) throws {
        guard let controller = controllersByCatalog[id] else {
            throw CatalogWindowError.catalogNotFound(id)
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(_ id: CatalogID) async {
        guard let controller = controllersByCatalog[id] else { return }
        await withCheckedContinuation { continuation in
            controller.window?.orderOut(nil)
            controller.window?.close()
            continuation.resume()
        }
    }

    func closeAll(reason: CloseReason) async {
        let ids = Array(controllersByCatalog.keys)
        for id in ids {
            await close(id)
        }
    }

    func catalogID(for window: NSWindow?) -> CatalogID? {
        guard let window else { return nil }
        return catalogByWindow[ObjectIdentifier(window)]
    }

    func handle(_ event: CatalogWindowEvent) {
        switch event {
        case .didBecomeKey:
            break

        case .didResignKey:
            break

        case let .didMoveOrResize(id, generation, frame, screenID):
            Task {
                try? registry.updateLayout(CatalogLayoutUpdate(
                    catalogID: id,
                    placement: CatalogWindowPlacement(
                        frameX: frame.origin.x,
                        frameY: frame.origin.y,
                        frameWidth: frame.width,
                        frameHeight: frame.height,
                        screenID: screenID,
                        isFullScreen: false
                    ),
                    generation: generation
                ))
            }

        case let .didChangeFullScreen(id, generation, isFullScreen):
            if let controller = controllersByCatalog[id],
               let window = controller.window
            {
                let placement = layoutManager.persistablePlacement(window: window)
                Task {
                    try? registry.updateLayout(CatalogLayoutUpdate(
                        catalogID: id,
                        placement: placement ?? CatalogWindowPlacement(
                            frameX: 0, frameY: 0,
                            frameWidth: 1440, frameHeight: 900,
                            screenID: nil,
                            isFullScreen: isFullScreen
                        ),
                        generation: generation
                    ))
                }
            }

        case let .didMiniaturize(id, _):
            Task {
                try? registry.markHidden(id, generation: controllersByCatalog[id]?.generation ?? 0)
            }

        case let .closeRequested(id, generation):
            Task { @MainActor in
                guard let controller = controllersByCatalog[id],
                      controller.generation == generation
                else { return }
                controller.flushLayout()
                do {
                    try registry.markClosed(id, generation: generation)
                } catch {
                    // Teardown even if persist fails; record is restore-safe
                }
            }

        case let .didClose(id, _):
            if let controller = controllersByCatalog[id] {
                if let window = controller.window {
                    catalogByWindow.removeValue(forKey: ObjectIdentifier(window))
                }
                controllersByCatalog.removeValue(forKey: id)
            }
        }
    }

    // MARK: - Private

    private func makeController(for snapshot: CatalogSnapshot) throws {
        guard controllersByCatalog[snapshot.id] == nil else {
            throw CatalogWindowError.duplicateCatalog(snapshot.id)
        }

        let controller = CatalogWindowController(
            catalog: snapshot,
            rootFactory: rootFactory,
            layoutManager: layoutManager,
            eventSink: self
        )

        controllersByCatalog[snapshot.id] = controller

        if let window = controller.window {
            catalogByWindow[ObjectIdentifier(window)] = snapshot.id
        }

        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - CatalogWindowEventSink

extension CatalogWindowManager: CatalogWindowEventSink {}
