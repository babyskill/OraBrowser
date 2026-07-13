import AppKit
import Foundation
import SwiftData
import SwiftUI

@MainActor
final class ApplicationGraph {
    static let shared = ApplicationGraph()

    let layoutManager = WindowLayoutManager()
    let resetContract: ShellResetContract = DefaultShellResetContract()
    private(set) lazy var pressureMonitor = PressureMonitor()
    private(set) lazy var snapshotStore = SnapshotStore()
    private(set) lazy var resourceManager = ResourceManager(
        pressureMonitor: pressureMonitor,
        snapshotStore: snapshotStore,
        deepHibernationEnabled: deepHibernationEnabled,
        aiActivityLeaseEnabled: aiActivityLeaseEnabled
    )

    private(set) lazy var systemNotificationMonitor: SystemNotificationMonitor = {
        let monitor = SystemNotificationMonitor()
        monitor.onSleep = { [weak self] in self?.windowManager.handleSystemSleep() }
        monitor.onWake = { [weak self] in self?.windowManager.handleSystemWake() }
        monitor.onDisplayChange = { [weak self] in
            guard let self else { return }
            for window in NSApplication.shared.windows {
                window.layoutIfNeeded()
            }
        }
        return monitor
    }()

    private(set) lazy var windowPool = WindowPool(
        resetContract: resetContract,
        enabled: windowPoolEnabled
    )

    private(set) lazy var webRuntime = WebRuntime(
        warmPageEnabled: warmPageLeaseEnabled
    )

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
            deleteSwiftDataStore("Ora/OraDataPrivate.sqlite")
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
        rootFactory: { [weak self] state in
            self?.makeRootViewController(state: state)
                ?? NSViewController()
        },
        dependenciesFactory: { [weak self] context in
            guard let self else { preconditionFailure("ApplicationGraph was released") }
            return self.dependencies(for: context)
        },
        windowPool: windowPool,
        webRuntime: webRuntime,
        resetContract: resetContract,
        resourceManager: resourceManager,
        snapshotStore: snapshotStore,
        snapshotOverlayEnabled: snapshotOverlayEnabled
    )

    private(set) lazy var commandRouter = CatalogCommandRouter(windowManager: windowManager)

    private(set) lazy var coordinator = AppCoordinator(
        graph: self,
        registry: registry,
        windowManager: windowManager
    )

    var catalogRuntimeEnabled: Bool {
        featureFlag(named: "catalogRuntime", defaultValue: true)
    }

    var windowPoolEnabled: Bool {
        featureFlag(named: "windowPool", defaultValue: true)
    }

    var snapshotOverlayEnabled: Bool {
        featureFlag(named: "snapshotOverlay", defaultValue: true)
    }

    var warmPageLeaseEnabled: Bool {
        featureFlag(named: "warmPageLease", defaultValue: true)
    }

    var deepHibernationEnabled: Bool {
        featureFlag(named: "deepHibernation", defaultValue: true)
    }

    var aiActivityLeaseEnabled: Bool {
        featureFlag(named: "aiActivityLease", defaultValue: true)
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

    private init() {
        _ = systemNotificationMonitor
    }

    // MARK: - Root view controller factory

    private func makeRootViewController(state: CatalogShellState) -> NSViewController {
        let shellView = CatalogShellView(state: state)
        return NSHostingController(rootView: shellView)
    }

    private func featureFlag(named key: String, defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }
}
