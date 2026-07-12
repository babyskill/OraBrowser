import AppKit
import Foundation

@MainActor
final class CatalogCommandRouter {
    private let windowManager: CatalogWindowManager

    init(windowManager: CatalogWindowManager) {
        self.windowManager = windowManager
    }

    // MARK: - Commands

    func openCatalog(isPrivate: Bool = false) {
        let defaultURL = URL(string: "https://www.google.com")!
        Task {
            do {
                _ = try windowManager.open(OpenCatalogRequest(
                    startURL: defaultURL,
                    profileID: ProfileID(),
                    isPrivate: isPrivate,
                    configurationFingerprint: "",
                    preferredPlacement: nil
                ))
            } catch {
                // Log and surface error
            }
        }
    }

    func closeFocusedCatalog() {
        guard let keyWindow = NSApp.keyWindow,
              let catalogID = windowManager.catalogID(for: keyWindow)
        else { return }
        Task {
            await windowManager.close(catalogID)
        }
    }

    func closeAllCatalogs() {
        Task {
            await windowManager.closeAll(reason: .allWindows)
        }
    }

    func reloadFocusedCatalog() {
        // Phase 2 stub — will wire through WebRuntime in Phase 3
    }

    func focusLocationBar() {
        // Phase 2 stub — will wire through focused controller in Phase 3
    }

    func toggleFullScreenFocused() {
        guard let keyWindow = NSApp.keyWindow,
              windowManager.catalogID(for: keyWindow) != nil
        else { return }
        keyWindow.toggleFullScreen(nil)
    }

    // MARK: - Window identification

    func isFocusedWindowCatalog() -> Bool {
        guard let keyWindow = NSApp.keyWindow else { return false }
        return windowManager.catalogID(for: keyWindow) != nil
    }

    func isWindowCatalog(_ window: NSWindow) -> Bool {
        windowManager.catalogID(for: window) != nil
    }
}
