import AppKit
import SwiftUI

@MainActor
final class CatalogWindowController: NSWindowController, NSWindowDelegate {
    private(set) var windowLeaseID: WindowLeaseID?
    private(set) var catalogID: CatalogID?
    private(set) var generation: Int = 0

    private(set) var reusableShell: ReusableWindowShell

    var pageHostView: NSView {
        reusableShell.pageHostView
    }

    private weak var eventSink: CatalogWindowEventSink?
    private var layoutManager: WindowLayoutManager?

    private var didRestoreFullScreen = false
    private var lastPersistedFrame: CGRect = .zero
    private var moveResizeWorkItem: DispatchWorkItem?
    private var isBound = false
    private var shellState: CatalogShellState?
    private var occlusionObserver: NSObjectProtocol?

    // MARK: - Init (creates new ReusableWindowShell)

    init(shell: ReusableWindowShell, layoutManager: WindowLayoutManager) {
        self.reusableShell = shell
        super.init(window: shell.window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Bind catalog identity

    func bind(
        catalogID: CatalogID,
        generation: Int,
        windowLeaseID: WindowLeaseID,
        placement: CatalogWindowPlacement?,
        eventSink: CatalogWindowEventSink,
        rootFactory: CatalogRootFactory,
        state: CatalogShellState,
        layoutManager: WindowLayoutManager
    ) {
        self.catalogID = catalogID
        self.generation = generation
        self.windowLeaseID = windowLeaseID
        self.eventSink = eventSink
        self.layoutManager = layoutManager
        shellState = state

        let window = reusableShell.window

        window.delegate = self

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let catalogID = self.catalogID,
                  let windowLeaseID = self.windowLeaseID,
                  let window = notification.object as? NSWindow else { return }
            let isOccluded = !window.occlusionState.contains(.visible)
            self.eventSink?.handle(.didChangeOcclusion(
                catalogID, generation: self.generation, windowLeaseID: windowLeaseID, isOccluded: isOccluded
            ))
        }

        // Apply placement
        if let placement {
            let screens = layoutManager.currentScreens()
            let resolved = layoutManager.initialPlacement(
                saved: placement,
                screens: screens,
                existingFrames: [],
                preferredScreenID: placement.screenID
            )
            window.setFrame(resolved.frame, display: false)
            lastPersistedFrame = resolved.frame

            if placement.isFullScreen, !didRestoreFullScreen {
                didRestoreFullScreen = true
                DispatchQueue.main.async { [weak self] in
                    self?.window?.toggleFullScreen(nil)
                }
            }
        }

        // Create and set the root view controller
        let rootVC = rootFactory(state)
        reusableShell.setHostingController(rootVC)

        isBound = true
    }

    // MARK: - Page host

    func attachPageView(_ view: NSView) {
        view.frame = pageHostView.bounds
        view.autoresizingMask = [.width, .height]
        pageHostView.addSubview(view)
    }

    func detachPageView() {
        pageHostView.subviews.forEach { $0.removeFromSuperview() }
    }

    // MARK: - Unbind & Release

    func prepareForRelease() {
        isBound = false
        moveResizeWorkItem?.cancel()
        moveResizeWorkItem = nil
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        window?.delegate = nil
        eventSink = nil
        shellState?.setOverlayState(.blank)
        shellState = nil
        catalogID = nil
        generation = 0
        windowLeaseID = nil
    }

    func destroy() {
        prepareForRelease()
        reusableShell.destroy()
    }

    func clearForReuse() {
        prepareForRelease()
        didRestoreFullScreen = false
        lastPersistedFrame = .zero
        reusableShell.makeNeutralContent()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard let catalogID, let windowLeaseID else { return }
        eventSink?.handle(.didBecomeKey(catalogID, generation: generation, windowLeaseID: windowLeaseID, at: Date()))
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let catalogID, let windowLeaseID else { return }
        eventSink?.handle(.didResignKey(catalogID, generation: generation, windowLeaseID: windowLeaseID))
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
        guard let catalogID, let windowLeaseID else { return }
        eventSink?.handle(.didChangeFullScreen(
            catalogID,
            generation: generation,
            windowLeaseID: windowLeaseID,
            isFullScreen: true
        ))
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let catalogID, let windowLeaseID else { return }
        eventSink?.handle(.didChangeFullScreen(
            catalogID,
            generation: generation,
            windowLeaseID: windowLeaseID,
            isFullScreen: false
        ))
        flushLayout()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let catalogID, let windowLeaseID else { return }
        eventSink?.handle(.didMiniaturize(catalogID, generation: generation, windowLeaseID: windowLeaseID))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let catalogID, let windowLeaseID else { return true }
        eventSink?.handle(.closeRequested(catalogID, generation: generation, windowLeaseID: windowLeaseID))
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let catalogID, let windowLeaseID else { return }
        flushLayout()
        eventSink?.handle(.didClose(catalogID, generation: generation, windowLeaseID: windowLeaseID))
    }

    // MARK: - Layout coalescing

    private func coalesceLayoutEvent() {
        guard isBound else { return }
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
        guard let catalogID, let windowLeaseID, let window else { return }
        let frame = window.frame
        guard frame != lastPersistedFrame else { return }
        lastPersistedFrame = frame
        let screenID = layoutManager?.displayID(for: window)
        eventSink?.handle(.didMoveOrResize(
            catalogID, generation: generation, windowLeaseID: windowLeaseID, frame: frame, screenID: screenID
        ))
    }
}
