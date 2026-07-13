import AppKit
@testable import Ora
import Testing

@MainActor
struct SystemNotificationTests {
    @Test func forwardsSleepWakeAndDisplayNotifications() async {
        let workspaceCenter = NotificationCenter()
        let applicationCenter = NotificationCenter()
        let monitor = SystemNotificationMonitor(
            workspaceNotificationCenter: workspaceCenter,
            applicationNotificationCenter: applicationCenter
        )
        var events: [String] = []
        monitor.onSleep = { events.append("sleep") }
        monitor.onWake = { events.append("wake") }
        monitor.onDisplayChange = { events.append("display") }

        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        applicationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        await Task.yield()
        #expect(events == ["sleep", "wake", "display"])
    }
}
