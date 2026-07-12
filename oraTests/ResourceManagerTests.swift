import Foundation
@testable import Ora
import Testing

@MainActor
struct ResourceManagerTests {
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

    @Test func transitionsThroughL0ToL5() {
        let id = CatalogID()
        var state = CatalogResourceState(
            catalogID: id,
            level: .l0Active,
            lastInteractionAt: Date(timeIntervalSinceNow: -1),
            isKey: false
        )
        let engine = ResourcePolicyEngine()
        let now = Date()

        for expected in [
            HibernationLevel.l1Grace,
            .l2Throttled,
            .l3Snapshotted,
            .l4DeepHibernation,
            .l5Recycled
        ] {
            let next = engine.nextLevel(
                from: state.level,
                state: state,
                config: immediateConfig,
                now: now,
                pressureLevel: .normal
            )
            #expect(next == expected)
            state.level = next
        }
    }

    @Test func evictionScorePrioritizesOldOccludedCatalogsAndProtectsPinnedActivity() {
        let engine = ResourcePolicyEngine()
        let now = Date()
        let oldOccluded = CatalogResourceState(
            catalogID: CatalogID(),
            lastInteractionAt: now.addingTimeInterval(-300),
            isOccluded: true,
            estimatedCost: 200
        )
        let protected = CatalogResourceState(
            catalogID: CatalogID(),
            lastInteractionAt: now.addingTimeInterval(-300),
            isOccluded: true,
            isPinned: true,
            hasActiveActivity: true,
            estimatedCost: 200
        )

        let oldScore = engine.evictionScore(for: oldOccluded, now: now)
        let protectedScore = engine.evictionScore(for: protected, now: now)
        #expect(oldScore > protectedScore)
        #expect(engine.evictionScore(for: oldOccluded, now: now, pressureLevel: .critical) < oldScore)
    }

    @Test func warningSnapshotsAndCriticalPressureEvicts() async {
        let monitor = PressureMonitor()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SnapshotStore(baseURL: directory)
        var captured: [CatalogID] = []
        var released: [CatalogID] = []
        let manager = ResourceManager(
            pressureMonitor: monitor,
            snapshotStore: store,
            budgetConfig: immediateConfig,
            callbacks: ResourceManagerCallbacks(
                releasePage: { released.append($0) },
                captureSnapshot: { captured.append($0) }
            ),
            evaluationInterval: 60
        )
        let first = CatalogID()
        let second = CatalogID()
        manager.register(catalogID: first)
        manager.register(catalogID: second)
        manager.handleFocusLost(catalogID: first)
        manager.handleFocusLost(catalogID: second)

        monitor.simulatePressure(.warning)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!captured.isEmpty)

        monitor.simulatePressure(.critical)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!released.isEmpty)
        #expect(released.allSatisfy { manager.currentLevel(for: $0) == .l4DeepHibernation })

        manager.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}
