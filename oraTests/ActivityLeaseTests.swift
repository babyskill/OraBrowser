import Foundation
@testable import Ora
import Testing

@MainActor
struct ActivityLeaseTests {
    private let constrainedConfig = BudgetConfig(
        mode: .saver,
        maxActiveWindows: 1,
        maxLivePages: 1,
        gracePeriodSeconds: 0,
        throttleAfterSeconds: 0,
        snapshotAfterSeconds: 0,
        deepHibernateAfterSeconds: 0,
        recycleAfterSeconds: 0,
        hysteresisWindowSeconds: 0
    )

    @Test func acquiringAndReleasingLeaseUpdatesActivityState() {
        let manager = ResourceManager(budgetConfig: constrainedConfig, evaluationInterval: 60)
        let id = CatalogID()
        manager.register(catalogID: id)

        manager.acquireLease(for: id, type: .aiGeneration, duration: 60)
        #expect(manager.hasActiveLeases(for: id))
        #expect(manager.state(for: id)?.hasActiveActivity == true)

        manager.releaseLease(for: id, type: .aiGeneration)
        #expect(!manager.hasActiveLeases(for: id))
        #expect(manager.state(for: id)?.hasActiveActivity == false)
    }

    @Test func activeLeaseProtectsCatalogFromL4Eviction() async {
        var released: [CatalogID] = []
        let monitor = PressureMonitor()
        let manager = ResourceManager(
            pressureMonitor: monitor,
            budgetConfig: constrainedConfig,
            callbacks: ResourceManagerCallbacks(releasePage: { released.append($0) }),
            evaluationInterval: 60
        )
        let protected = CatalogID()
        let evictable = CatalogID()
        manager.register(catalogID: protected)
        manager.register(catalogID: evictable)
        manager.handleFocusLost(catalogID: protected)
        manager.handleFocusLost(catalogID: evictable)
        manager.acquireLease(for: protected, type: .mediaPlayback, duration: 60)

        monitor.simulatePressure(.critical)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(manager.currentLevel(for: protected) == .l0Active)
        #expect(!released.contains(protected))
        #expect(released.contains(evictable))
        manager.stop()
    }
}
