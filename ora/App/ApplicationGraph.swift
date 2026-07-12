import AppKit
import Foundation
import SwiftData
import SwiftUI

@MainActor
final class ApplicationGraph {
    static let shared = ApplicationGraph()

    let layoutManager = WindowLayoutManager()

    private(set) lazy var normalModelContainer: ModelContainer = {
        do {
            return try ModelConfiguration.createOraContainer(isPrivate: false)
        } catch {
            deleteSwiftDataStore("Ora/OraData.sqlite")
            fatalError("Failed to create normal ModelContainer: \(error)")
        }
    }()

    private(set) lazy var privateModelContainer: ModelContainer = {
        do {
            return try ModelConfiguration.createOraContainer(isPrivate: true)
        } catch {
            fatalError("Failed to create private ModelContainer: \(error)")
        }
    }()

    private(set) lazy var registry: CatalogRegistry = .init(
        normalContainer: normalModelContainer,
        privateContainer: privateModelContainer
    )

    private(set) lazy var windowManager: CatalogWindowManager = .init(
        registry: registry,
        layoutManager: layoutManager,
        rootFactory: { [weak self] context, actions in
            self?.makeRootViewController(context: context, actions: actions)
                ?? NSViewController()
        }
    )

    private(set) lazy var commandRouter = CatalogCommandRouter(windowManager: windowManager)

    private(set) lazy var coordinator = AppCoordinator(
        graph: self,
        registry: registry,
        windowManager: windowManager
    )

    var catalogRuntimeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "catalogRuntime")
    }

    func dependencies(for context: CatalogWindowContext) -> CatalogRootDependencies {
        let isPrivate: Bool = if let snapshot = try? registry.snapshot(for: context.catalogID) {
            snapshot.isPrivate
        } else {
            false
        }

        let container = isPrivate ? privateModelContainer : normalModelContainer
        let modelContext = ModelContext(container)

        let mediaController = MediaController()
        let historyManager = HistoryManager(modelContainer: container, modelContext: modelContext)
        let tabManager = TabManager(
            modelContainer: container,
            modelContext: modelContext,
            mediaController: mediaController
        )
        let downloadManager = DownloadManager(modelContainer: container, modelContext: modelContext)
        let privacyMode = PrivacyMode(isPrivate: isPrivate)

        return CatalogRootDependencies(
            modelContainer: container,
            modelContext: modelContext,
            tabManager: tabManager,
            historyManager: historyManager,
            downloadManager: downloadManager,
            mediaController: mediaController,
            privacyMode: privacyMode
        )
    }

    private init() {}

    // MARK: - Root view controller factory

    private func makeRootViewController(
        context: CatalogWindowContext,
        actions: CatalogShellActions
    ) -> NSViewController {
        let shellView = CatalogShellView(context: context, actions: actions)
        return NSHostingController(rootView: shellView)
    }
}
