import AppKit
import Foundation

// MARK: - Shell Release Context

struct ShellReleaseContext: Sendable {
    let windowLeaseID: WindowLeaseID
    let catalogID: CatalogID
    let generation: Int
    let reason: WindowLeaseReleaseReason
}

// MARK: - Reset Report & Violations

struct ShellResetReport: Sendable {
    let shellID: ShellID
    let success: Bool
    let violations: [ShellCleanlinessViolation]
    let durationMs: Double

    var isClean: Bool { violations.isEmpty && success }
}

enum ShellCleanlinessViolation: Sendable {
    case lingeringCatalogIdentity(CatalogID)
    case lingeringPageContent
    case lingeringSnapshot
    case lingeringSheet
    case lingeringPopover
    case lingeringFirstResponder
    case lingeringTask
    case lingeringObserver
    case windowNotHidden
    case windowIsKey
    case rootViewNotNeutral
    case generic(String)
}

struct ShellCleanlinessReport: Sendable {
    let isClean: Bool
    let violations: [ShellCleanlinessViolation]
}

// MARK: - Shell Reset Contract Protocol

@MainActor
protocol ShellResetContract {
    func prepareForRelease(_ context: ShellReleaseContext)
    func reset(_ shell: ReusableWindowShell) async -> ShellResetReport
    func validateClean(_ shell: ReusableWindowShell) -> ShellCleanlinessReport
}

// MARK: - Default Implementation

@MainActor
final class DefaultShellResetContract: ShellResetContract {
    func prepareForRelease(_ context: ShellReleaseContext) {
        // Pre-release: disable command closures, invalidate lease identity
        // The controller handles this internally
    }

    func reset(_ shell: ReusableWindowShell) async -> ShellResetReport {
        let start = CFAbsoluteTimeGetCurrent()
        var violations: [ShellCleanlinessViolation] = []

        let window = shell.window

        // 1. Order out window
        window.orderOut(nil)

        // 2. Detach page content
        shell.pageHostView.subviews.forEach { $0.removeFromSuperview() }

        // 3. Resign first responder
        if let firstResponder = window.firstResponder {
            window.makeFirstResponder(nil)
            // Check if the first responder was content-sensitive
            if firstResponder is NSTextView || firstResponder is NSView {
                // Safe — generic NSResponder reset
            }
        }

        // 4. Remove sheets
        if let sheet = window.attachedSheet {
            window.endSheet(sheet)
            violations.append(.lingeringSheet)
        }

        // 5. Reset title and represented URL
        window.title = ""
        window.representedURL = nil

        // 6. Remove appearance override
        window.appearance = nil

        // 7. Dissolve full-screen pending state
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }

        // 8. Reset toolbar customization
        window.toolbar?.isVisible = false

        // 9. Validate no lingering catalog content
        if !shell.pageHostView.subviews.isEmpty {
            violations.append(.lingeringPageContent)
        }

        // 10. Validate root view is neutral (not catalog-specific)
        let cleanliness = validateClean(shell)
        violations.append(contentsOf: cleanliness.violations)

        let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return ShellResetReport(
            shellID: shell.shellID,
            success: violations.isEmpty,
            violations: violations,
            durationMs: durationMs
        )
    }

    func validateClean(_ shell: ReusableWindowShell) -> ShellCleanlinessReport {
        var violations: [ShellCleanlinessViolation] = []
        let window = shell.window

        // Window must be hidden
        if window.isVisible {
            violations.append(.windowNotHidden)
        }

        // Window must not be key
        if window.isKeyWindow {
            violations.append(.windowIsKey)
        }

        // No page content
        if !shell.pageHostView.subviews.isEmpty {
            violations.append(.lingeringPageContent)
        }

        // No attached sheets
        if window.attachedSheet != nil {
            violations.append(.lingeringSheet)
        }

        // No full-screen transition pending
        if window.styleMask.contains(.fullScreen) {
            violations.append(.windowNotHidden)
        }

        return ShellCleanlinessReport(
            isClean: violations.isEmpty,
            violations: violations
        )
    }
}
