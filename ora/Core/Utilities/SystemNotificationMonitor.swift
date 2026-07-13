import AppKit
import Foundation

@MainActor
final class SystemNotificationMonitor {
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?
    var onDisplayChange: (() -> Void)?

    private let workspaceNotificationCenter: NotificationCenter
    private let applicationNotificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        applicationNotificationCenter: NotificationCenter = .default
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.applicationNotificationCenter = applicationNotificationCenter

        observers.append(workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSleep?() }
        })
        observers.append(workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWake?() }
        })
        observers.append(applicationNotificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDisplayChange?() }
        })
    }

    deinit {
        for observer in observers {
            workspaceNotificationCenter.removeObserver(observer)
            applicationNotificationCenter.removeObserver(observer)
        }
    }
}
