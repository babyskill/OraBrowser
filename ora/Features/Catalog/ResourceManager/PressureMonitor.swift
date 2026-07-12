import Foundation
import OSLog

// MARK: - Memory Pressure Level

enum MemoryPressureLevel: Int, Sendable, Comparable {
    case normal = 0
    case warning = 1
    case critical = 2

    static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var scaleFactor: Double {
        switch self {
        case .normal: 1.0
        case .warning: 0.5
        case .critical: 0.25
        }
    }
}

// MARK: - Pressure Monitor

@MainActor
final class PressureMonitor {
    private let logger = Logger(subsystem: "com.orabrowser.app", category: "PressureMonitor")

    private var source: DispatchSourceMemoryPressure?
    private(set) var currentLevel: MemoryPressureLevel = .normal

    var onPressureChange: ((MemoryPressureLevel) -> Void)?

    init() {
        startMonitoring()
    }

    deinit {
        source?.cancel()
    }

    // MARK: - Start / Stop

    func startMonitoring() {
        guard source == nil else { return }

        let dispatchSource = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: .main)
        dispatchSource.setEventHandler { [weak self] in
            guard let self else { return }
            let event = dispatchSource.data
            let level = Self.mapEvent(event)
            self.handlePressureChange(level)
        }
        dispatchSource.resume()
        source = dispatchSource
        logger.debug("Memory pressure monitoring started")
    }

    func stopMonitoring() {
        source?.cancel()
        source = nil
        logger.debug("Memory pressure monitoring stopped")
    }

    /// Deterministic injection point used by tests and diagnostics.
    func simulatePressure(_ level: MemoryPressureLevel) {
        handlePressureChange(level)
    }

    // MARK: - Private

    private func handlePressureChange(_ level: MemoryPressureLevel) {
        guard level != currentLevel else { return }
        currentLevel = level
        logger.warning("Memory pressure changed to: \(String(describing: level), privacy: .public)")
        onPressureChange?(level)
    }

    private static func mapEvent(_ event: DispatchSource.MemoryPressureEvent) -> MemoryPressureLevel {
        if event.contains(.critical) {
            return .critical
        }
        if event.contains(.warning) {
            return .warning
        }
        return .normal
    }
}
