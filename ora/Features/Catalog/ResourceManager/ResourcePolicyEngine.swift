import Foundation

// MARK: - RAM Budget Mode

enum RAMBudgetMode: String, Sendable, CaseIterable {
    case saver
    case balanced
    case performance

    static func detect(for physicalMemoryBytes: UInt64) -> RAMBudgetMode {
        let gb = Double(physicalMemoryBytes) / 1_073_741_824.0
        switch gb {
        case ..<12:
            return .saver
        case ..<28:
            return .balanced
        default:
            return .performance
        }
    }

    static var current: RAMBudgetMode {
        detect(for: ProcessInfo.processInfo.physicalMemory)
    }
}

// MARK: - Budget Config

struct BudgetConfig: Sendable {
    let mode: RAMBudgetMode
    let maxActiveWindows: Int
    let maxLivePages: Int
    let gracePeriodSeconds: TimeInterval
    let throttleAfterSeconds: TimeInterval
    let snapshotAfterSeconds: TimeInterval
    let deepHibernateAfterSeconds: TimeInterval
    let recycleAfterSeconds: TimeInterval
    let hysteresisWindowSeconds: TimeInterval

    static func config(for mode: RAMBudgetMode) -> BudgetConfig {
        switch mode {
        case .saver:
            return BudgetConfig(
                mode: .saver,
                maxActiveWindows: 4,
                maxLivePages: 3,
                gracePeriodSeconds: 20,
                throttleAfterSeconds: 30,
                snapshotAfterSeconds: 60,
                deepHibernateAfterSeconds: 180,
                recycleAfterSeconds: 300,
                hysteresisWindowSeconds: 15
            )
        case .balanced:
            return BudgetConfig(
                mode: .balanced,
                maxActiveWindows: 8,
                maxLivePages: 6,
                gracePeriodSeconds: 30,
                throttleAfterSeconds: 45,
                snapshotAfterSeconds: 90,
                deepHibernateAfterSeconds: 300,
                recycleAfterSeconds: 600,
                hysteresisWindowSeconds: 10
            )
        case .performance:
            return BudgetConfig(
                mode: .performance,
                maxActiveWindows: 16,
                maxLivePages: 12,
                gracePeriodSeconds: 60,
                throttleAfterSeconds: 90,
                snapshotAfterSeconds: 180,
                deepHibernateAfterSeconds: 600,
                recycleAfterSeconds: 1200,
                hysteresisWindowSeconds: 5
            )
        }
    }
}

// MARK: - Eviction Scoring Weights

struct EvictionWeights: Sendable {
    let age: Double
    let occlusion: Double
    let pinned: Double
}

// MARK: - Policy Engine

struct ResourcePolicyEngine: Sendable {
    // MARK: - Eviction Scoring

    func evictionScore(
        for state: CatalogResourceState,
        now: Date,
        poolPressure: Double = 0,
        pressureLevel: MemoryPressureLevel = .normal
    ) -> Double {
        let scale = pressureLevel.scaleFactor
        let weights = EvictionWeights(age: 0.4, occlusion: 0.3, pinned: 0.5)

        let age = max(0.0, now.timeIntervalSince(state.lastInteractionAt))
        let occlusionTime = state.isOccluded ? age : 0.0
        let pinnedPenalty = state.isPinned ? weights.pinned * state.estimatedCost : 0.0
        let activityProtection = state.hasActiveActivity ? state.estimatedCost * 0.5 : 0.0

        let rawScore = (weights.age * age)
            + (weights.occlusion * occlusionTime)
            + state.estimatedCost
            + poolPressure
            - pinnedPenalty
            - activityProtection

        return rawScore * scale
    }

    // MARK: - Level Transition

    func nextLevel(
        from current: HibernationLevel,
        state: CatalogResourceState,
        config: BudgetConfig,
        now: Date,
        pressureLevel: MemoryPressureLevel
    ) -> HibernationLevel {
        let elapsed = now.timeIntervalSince(state.lastInteractionAt)
        let scaledElapsed = elapsed / pressureLevel.scaleFactor

        switch current {
        case .l0Active:
            if !state.isKey, scaledElapsed > config.gracePeriodSeconds {
                return .l1Grace
            }
            return .l0Active

        case .l1Grace:
            if state.isKey {
                return .l0Active
            }
            if scaledElapsed > config.gracePeriodSeconds + config.throttleAfterSeconds {
                return .l2Throttled
            }
            return .l1Grace

        case .l2Throttled:
            if state.isKey {
                return .l0Active
            }
            if pressureLevel >= .critical || scaledElapsed > config.gracePeriodSeconds + config
                .throttleAfterSeconds + config.snapshotAfterSeconds
            {
                return .l3Snapshotted
            }
            return .l2Throttled

        case .l3Snapshotted:
            if state.isKey {
                return .l1Grace
            }
            if pressureLevel >= .critical || scaledElapsed > config.gracePeriodSeconds + config
                .throttleAfterSeconds + config.snapshotAfterSeconds + config.deepHibernateAfterSeconds
            {
                return .l4DeepHibernation
            }
            return .l3Snapshotted

        case .l4DeepHibernation:
            if state.isKey {
                return .l1Grace
            }
            if pressureLevel >= .critical || scaledElapsed > config.gracePeriodSeconds + config
                .throttleAfterSeconds + config.snapshotAfterSeconds + config.deepHibernateAfterSeconds + config
                .recycleAfterSeconds
            {
                return .l5Recycled
            }
            return .l4DeepHibernation

        case .l5Recycled:
            if state.isKey {
                return .l1Grace
            }
            return .l5Recycled
        }
    }

    // MARK: - Promote (Wake-up from hibernation)

    func promoteLevel(
        from current: HibernationLevel,
        state: CatalogResourceState
    ) -> HibernationLevel {
        switch current {
        case .l0Active, .l1Grace, .l2Throttled:
            return state.isKey ? .l0Active : current
        case .l3Snapshotted:
            return state.isKey ? .l1Grace : current
        case .l4DeepHibernation, .l5Recycled:
            return state.isKey ? .l1Grace : current
        }
    }

    // MARK: - Eviction Candidates

    func evictionCandidates(
        from states: [CatalogResourceState],
        count: Int,
        pressureLevel: MemoryPressureLevel,
        now: Date
    ) -> [CatalogID] {
        states
            .filter { $0.level < .l5Recycled && !$0.isPinned && !$0.hasActiveActivity }
            .sorted { lhs, rhs in
                evictionScore(for: lhs, now: now, pressureLevel: pressureLevel)
                    > evictionScore(for: rhs, now: now, pressureLevel: pressureLevel)
            }
            .prefix(count)
            .map(\.catalogID)
    }
}
