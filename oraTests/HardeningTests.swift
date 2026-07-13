import Foundation
@testable import Ora
import Testing

@MainActor
struct HardeningTests {
    private let immediateConfig = BudgetConfig(
        mode: .saver,
        maxActiveWindows: 4,
        maxLivePages: 4,
        gracePeriodSeconds: 0,
        throttleAfterSeconds: 0,
        snapshotAfterSeconds: 0,
        deepHibernateAfterSeconds: 0,
        recycleAfterSeconds: 0,
        hysteresisWindowSeconds: 0
    )

    @Test func stressCyclesStayAtL3WhenDeepHibernationIsDisabled() async throws {
        var released: [CatalogID] = []
        let manager = ResourceManager(
            budgetConfig: immediateConfig,
            callbacks: ResourceManagerCallbacks(releasePage: { released.append($0) }),
            evaluationInterval: 0.001,
            deepHibernationEnabled: false
        )
        let id = CatalogID()
        manager.register(catalogID: id)
        manager.start()
        defer { manager.stop() }

        for _ in 0 ..< 100 {
            manager.handleFocusLost(catalogID: id)
            try await waitUntil { manager.currentLevel(for: id) == .l3Snapshotted }
            manager.handleFocusGained(catalogID: id)
            #expect(manager.currentLevel(for: id) == .l1Grace)
        }

        manager.handleFocusLost(catalogID: id)
        try await waitUntil { manager.currentLevel(for: id) == .l3Snapshotted }
        #expect(released.isEmpty)
    }

    @Test func activityLeaseFlagControlsTransitionProtection() async throws {
        let protectedManager = ResourceManager(
            budgetConfig: immediateConfig,
            evaluationInterval: 0.001,
            aiActivityLeaseEnabled: true
        )
        let protectedID = CatalogID()
        protectedManager.register(catalogID: protectedID)
        protectedManager.handleFocusLost(catalogID: protectedID)
        protectedManager.acquireLease(for: protectedID, type: .aiGeneration, duration: 60)
        protectedManager.start()
        try await Task.sleep(for: .milliseconds(20))
        #expect(protectedManager.currentLevel(for: protectedID) == .l0Active)
        protectedManager.stop()

        let unprotectedManager = ResourceManager(
            budgetConfig: immediateConfig,
            evaluationInterval: 0.001,
            aiActivityLeaseEnabled: false
        )
        let unprotectedID = CatalogID()
        unprotectedManager.register(catalogID: unprotectedID)
        unprotectedManager.handleFocusLost(catalogID: unprotectedID)
        unprotectedManager.acquireLease(for: unprotectedID, type: .aiGeneration, duration: 60)
        unprotectedManager.start()
        defer { unprotectedManager.stop() }

        try await waitUntil {
            (unprotectedManager.currentLevel(for: unprotectedID) ?? .l0Active) >= .l4DeepHibernation
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        try await confirmation("condition becomes true", expectedCount: 1) { confirm in
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if condition() {
                    confirm()
                    return
                }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }
}
