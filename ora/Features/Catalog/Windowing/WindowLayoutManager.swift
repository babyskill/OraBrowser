import AppKit
import Foundation

struct WindowLayoutManager {
    private let cascadeOffsetX: CGFloat = 28
    private let cascadeOffsetY: CGFloat = -28
    private let minWidth: CGFloat = 500
    private let minHeight: CGFloat = 360
    private let minVisibleContent: CGFloat = 80
    private let maxScreenRatio: CGFloat = 0.9

    // MARK: - Screen adapter

    func currentScreens() -> [ScreenDescriptor] {
        NSScreen.screens.map { screen in
            let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID
            let idString = displayID.map { String($0) } ?? "unknown"
            return ScreenDescriptor(
                displayID: idString,
                visibleFrame: screen.visibleFrame,
                fullFrame: screen.frame
            )
        }
    }

    func displayID(for window: NSWindow) -> String? {
        guard let screen = window.screen else { return nil }
        let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID
        return displayID.map { String($0) }
    }

    // MARK: - Placement resolution

    func initialPlacement(
        saved: CatalogWindowPlacement?,
        screens: [ScreenDescriptor],
        existingFrames: [CGRect],
        preferredScreenID: String?
    ) -> ResolvedWindowPlacement {
        guard !screens.isEmpty else {
            return ResolvedWindowPlacement(
                frame: CGRect(x: 100, y: 100, width: minWidth, height: minHeight),
                screenID: nil,
                isFullScreen: false
            )
        }

        if let saved, let screen = findScreen(for: saved.screenID, screens: screens) {
            let clamped = clamp(CGRect(
                x: saved.frameX,
                y: saved.frameY,
                width: saved.frameWidth,
                height: saved.frameHeight
            ), to: screen)
            let rehomed = ensureOnScreen(clamped, screen: screen, screens: screens)
            return ResolvedWindowPlacement(
                frame: rehomed,
                screenID: screen.displayID,
                isFullScreen: saved.isFullScreen
            )
        }

        if let saved {
            let rehomed = rehome(
                CGRect(
                    x: saved.frameX, y: saved.frameY,
                    width: saved.frameWidth, height: saved.frameHeight
                ),
                fromMissingScreenID: saved.screenID,
                screens: screens
            )
            return ResolvedWindowPlacement(
                frame: rehomed,
                screenID: preferredScreenID,
                isFullScreen: saved.isFullScreen
            )
        }

        let cascade = cascadeFrame(from: existingFrames, screens: screens)
        return ResolvedWindowPlacement(
            frame: cascade,
            screenID: preferredScreenID,
            isFullScreen: false
        )
    }

    func persistablePlacement(window: NSWindow) -> CatalogWindowPlacement? {
        guard let screen = window.screen else { return nil }
        guard !window.isMiniaturized else { return nil }
        let frame = window.frame
        guard frame.width.isFinite, frame.height.isFinite,
              frame.width >= minWidth, frame.height >= minHeight
        else {
            return nil
        }
        let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID
        return CatalogWindowPlacement(
            frameX: frame.origin.x,
            frameY: frame.origin.y,
            frameWidth: frame.width,
            frameHeight: frame.height,
            screenID: displayID.map { String($0) },
            isFullScreen: window.styleMask.contains(.fullScreen)
        )
    }

    func rehome(
        _ frame: CGRect,
        fromMissingScreenID: String?,
        screens: [ScreenDescriptor]
    ) -> CGRect {
        guard !screens.isEmpty else {
            return CGRect(x: 100, y: 100, width: max(frame.width, minWidth), height: max(frame.height, minHeight))
        }
        var bestScreen = screens[0]
        var bestIntersection: CGFloat = 0
        for screen in screens {
            let intersection = frame.intersection(screen.visibleFrame)
            let area = intersection.width * intersection.height
            if area > bestIntersection {
                bestIntersection = area
                bestScreen = screen
            }
        }
        if bestIntersection > 0 {
            return clamp(frame, to: bestScreen)
        }
        let screen = screens.first { $0.displayID == fromMissingScreenID } ?? screens[0]
        return clamp(frame, to: screen)
    }

    // MARK: - Private helpers

    private func findScreen(for screenID: String?, screens: [ScreenDescriptor]) -> ScreenDescriptor? {
        guard let screenID else {
            guard !screens.isEmpty else { return nil }
            return screens[0]
        }
        return screens.first { $0.displayID == screenID }
    }

    private func clamp(_ frame: CGRect, to screen: ScreenDescriptor) -> CGRect {
        let visible = screen.visibleFrame
        let maxW = visible.width * maxScreenRatio
        let maxH = visible.height * maxScreenRatio
        let clampedW = min(max(frame.width, minWidth), maxW)
        let clampedH = min(max(frame.height, minHeight), maxH)
        let clampedX = max(visible.minX, min(frame.origin.x, visible.maxX - minVisibleContent))
        let clampedY = max(visible.minY, min(frame.origin.y, visible.maxY - minVisibleContent))
        return CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)
    }

    private func ensureOnScreen(
        _ frame: CGRect,
        screen: ScreenDescriptor,
        screens: [ScreenDescriptor]
    ) -> CGRect {
        let visible = screen.visibleFrame
        let contentVisible = frame.intersection(visible)
        let hasEnoughContent = contentVisible.width >= minVisibleContent
            && contentVisible.height >= minVisibleContent
        if hasEnoughContent {
            var result = frame
            if result.minX < visible.minX { result.origin.x = visible.minX }
            if result.minY < visible.minY { result.origin.y = visible.minY }
            if result.maxX > visible.maxX { result.origin.x = visible.maxX - result.width }
            if result.maxY > visible.maxY { result.origin.y = visible.maxY - result.height }
            return result
        }
        return rehome(frame, fromMissingScreenID: screen.displayID, screens: screens)
    }

    private func cascadeFrame(
        from existingFrames: [CGRect],
        screens: [ScreenDescriptor]
    ) -> CGRect {
        guard !screens.isEmpty else {
            return CGRect(x: 100, y: 100, width: 1440, height: 900)
        }
        let screen = screens[0]
        let visible = screen.visibleFrame
        let defaultOrigin = CGPoint(
            x: visible.minX + 60,
            y: visible.maxY - 900 - 60
        )
        let defaultSize = CGSize(width: 1440, height: 900)
        let clampedSize = CGSize(
            width: min(defaultSize.width, visible.width * maxScreenRatio),
            height: min(defaultSize.height, visible.height * maxScreenRatio)
        )

        guard let lastFrame = existingFrames.last else {
            return CGRect(origin: defaultOrigin, size: clampedSize)
        }

        var newOrigin = CGPoint(
            x: lastFrame.origin.x + cascadeOffsetX,
            y: lastFrame.origin.y + cascadeOffsetY
        )

        if newOrigin.x + clampedSize.width > visible.maxX
            || newOrigin.y - clampedSize.height < visible.minY
        {
            newOrigin = CGPoint(
                x: visible.minX + 44,
                y: visible.maxY - clampedSize.height - 44
            )
        }
        if newOrigin.x + cascadeOffsetX + clampedSize.width > visible.maxX
            || newOrigin.y + cascadeOffsetY - clampedSize.height < visible.minY
        {
            newOrigin = CGPoint(x: visible.minX + 44, y: visible.maxY - clampedSize.height - 44)
        }

        return CGRect(origin: newOrigin, size: clampedSize)
    }
}
