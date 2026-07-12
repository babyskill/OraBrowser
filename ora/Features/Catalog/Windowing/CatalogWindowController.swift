import AppKit
import SwiftUI

typealias CatalogRootFactory = (CatalogWindowContext, CatalogShellActions) -> NSViewController

@MainActor
final class CatalogWindowController: NSWindowController, NSWindowDelegate {
    let catalogID: CatalogID
    let generation: Int
    private(set) weak var eventSink: CatalogWindowEventSink?

    private let layoutManager: WindowLayoutManager
    private var didRestoreFullScreen = false
    private var lastPersistedFrame: CGRect = .zero
    private var moveResizeWorkItem: DispatchWorkItem?

    init(
        catalog: CatalogSnapshot,
        rootFactory: CatalogRootFactory,
        layoutManager: WindowLayoutManager,
        eventSink: CatalogWindowEventSink
    ) {
        self.catalogID = catalog.id
        self.generation = catalog.generation
        self.layoutManager = layoutManager
        self.eventSink = eventSink

        let placement = layoutManager.initialPlacement(
            saved: catalog.placement,
            screens: layoutManager.currentScreens(),
            existingFrames: [],
            preferredScreenID: catalog.placement.screenID
        )

        let window = NSWindow(
            contentRect: placement.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 360)
        window.collectionBehavior = [.fullScreenPrimary]

        super.init(window: window)

        window.delegate = self

        let actions = CatalogShellActions(
            close: { [weak self] in
                self?.window?.performClose(nil)
            },
            reload: { [weak self] in
                self?.eventSink?.handle(.closeRequested(catalog.id, generation: catalog.generation))
            },
            focusLocation: {
                // Phase 2 stub — will be wired in Phase 3
            },
            toggleFullScreen: { [weak self] in
                self?.window?.toggleFullScreen(nil)
            }
        )

        let context = CatalogWindowContext(
            catalogID: catalog.id,
            profileID: catalog.profileID,
            generation: catalog.generation
        )

        let rootVC = rootFactory(context, actions)
        window.contentViewController = rootVC

        lastPersistedFrame = placement.frame

        if placement.isFullScreen, !didRestoreFullScreen {
            didRestoreFullScreen = true
            DispatchQueue.main.async { [weak self] in
                self?.window?.toggleFullScreen(nil)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        eventSink?.handle(.didBecomeKey(catalogID, generation: generation, at: Date()))
    }

    func windowDidResignKey(_ notification: Notification) {
        eventSink?.handle(.didResignKey(catalogID, generation: generation))
    }

    func windowDidResize(_ notification: Notification) {
        coalesceLayoutEvent()
    }

    func windowDidMove(_ notification: Notification) {
        coalesceLayoutEvent()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        flushLayout()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        eventSink?.handle(.didChangeFullScreen(catalogID, generation: generation, isFullScreen: true))
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        eventSink?.handle(.didChangeFullScreen(catalogID, generation: generation, isFullScreen: false))
        flushLayout()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        eventSink?.handle(.didMiniaturize(catalogID, generation: generation))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        eventSink?.handle(.closeRequested(catalogID, generation: generation))
        return true
    }

    func windowWillClose(_ notification: Notification) {
        flushLayout()
        eventSink?.handle(.didClose(catalogID, generation: generation))
    }

    // MARK: - Layout coalescing

    private func coalesceLayoutEvent() {
        moveResizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushLayout()
        }
        moveResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    func flushLayout() {
        moveResizeWorkItem?.cancel()
        moveResizeWorkItem = nil
        guard let window else { return }
        let frame = window.frame
        guard frame != lastPersistedFrame else { return }
        lastPersistedFrame = frame
        let screenID = layoutManager.displayID(for: window)
        eventSink?.handle(.didMoveOrResize(
            catalogID, generation: generation, frame: frame, screenID: screenID
        ))
    }
}
