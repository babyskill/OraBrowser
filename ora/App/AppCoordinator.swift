import AppKit
import Foundation

@MainActor
final class AppCoordinator {
    private let graph: ApplicationGraph
    private let registry: CatalogRegistryProtocol
    private let windowManager: CatalogWindowManager

    private let maxConcurrentRestores = 2

    init(
        graph: ApplicationGraph,
        registry: CatalogRegistryProtocol,
        windowManager: CatalogWindowManager
    ) {
        self.graph = graph
        self.registry = registry
        self.windowManager = windowManager
    }

    // MARK: - Lifecycle

    func start() {
        guard graph.catalogRuntimeEnabled else { return }
        Task {
            await restoreCatalogs()
        }
    }

    func handleReopen() {
        guard graph.catalogRuntimeEnabled else { return }
        Task { @MainActor in
            if let keyWindow = NSApp.keyWindow,
               let catalogID = windowManager.catalogID(for: keyWindow)
            {
                try? windowManager.focus(catalogID)
                return
            }
            try? openDefaultCatalog()
        }
    }

    func handleExternalURL(_ url: URL) {
        guard graph.catalogRuntimeEnabled else { return }
        Task { @MainActor in
            guard let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme)
            else { return }

            if let keyWindow = NSApp.keyWindow,
               let catalogID = windowManager.catalogID(for: keyWindow)
            {
                let snapshot = try? registry.snapshot(for: catalogID)
                if let snapshot, !snapshot.isPrivate {
                    // Navigate existing catalog
                    try? registry.updateNavigation(CatalogNavigationUpdate(
                        catalogID: catalogID,
                        currentURL: url,
                        title: nil,
                        generation: snapshot.generation
                    ))
                    return
                }
            }

            // Create new catalog for external URL
            _ = try? windowManager.open(OpenCatalogRequest(
                startURL: url,
                profileID: ProfileID(),
                isPrivate: false,
                configurationFingerprint: "",
                preferredPlacement: nil
            ))
        }
    }

    func handleTerminate() {
        guard graph.catalogRuntimeEnabled else { return }
        Task {
            try? registry.flush()
            await windowManager.closeAll(reason: .terminate)
            await MainActor.run {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
    }

    // MARK: - Private

    private func restoreCatalogs() async {
        let snapshots = (try? registry.restorableCatalogs()) ?? []

        let toRestore: [CatalogSnapshot] = if snapshots.isEmpty {
            []
        } else {
            Array(snapshots.suffix(maxConcurrentRestores))
        }

        for snapshot in toRestore {
            try? windowManager.restore(snapshot)
        }

        if toRestore.isEmpty {
            try? openDefaultCatalog()
        }
    }

    private func openDefaultCatalog() throws {
        let defaultURL = URL(string: "https://www.google.com")!
        _ = try windowManager.open(OpenCatalogRequest(
            startURL: defaultURL,
            profileID: ProfileID(),
            isPrivate: false,
            configurationFingerprint: "",
            preferredPlacement: nil
        ))
    }
}
