import Foundation
import SwiftData

@Model
final class CatalogRecord {
    @Attribute(.unique) var id: UUID
    var workspaceID: UUID?

    var startURL: URL
    var currentURL: URL
    var title: String?

    var profileID: UUID
    var isPrivate: Bool
    var configurationFingerprint: String

    var frameX: Double
    var frameY: Double
    var frameWidth: Double
    var frameHeight: Double
    var screenID: String?
    var isFullScreen: Bool
    var restoreDispositionRaw: String

    var zoomLevel: Double
    var createdAt: Date
    var updatedAt: Date
    var lastActiveAt: Date

    var lifecycleStateRaw: String
    var generation: Int

    init(
        id: UUID = UUID(),
        workspaceID: UUID? = nil,
        startURL: URL,
        currentURL: URL,
        title: String? = nil,
        profileID: UUID,
        isPrivate: Bool,
        configurationFingerprint: String,
        frameX: Double = 0,
        frameY: Double = 0,
        frameWidth: Double = 1440,
        frameHeight: Double = 900,
        screenID: String? = nil,
        isFullScreen: Bool = false,
        restoreDispositionRaw: String = CatalogRestoreDisposition.visible.rawValue,
        zoomLevel: Double = 1.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastActiveAt: Date = Date(),
        lifecycleStateRaw: String = CatalogLifecycleState.closed.rawValue,
        generation: Int = 1
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.startURL = startURL
        self.currentURL = currentURL
        self.title = title
        self.profileID = profileID
        self.isPrivate = isPrivate
        self.configurationFingerprint = configurationFingerprint
        self.frameX = frameX
        self.frameY = frameY
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.screenID = screenID
        self.isFullScreen = isFullScreen
        self.restoreDispositionRaw = restoreDispositionRaw
        self.zoomLevel = zoomLevel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActiveAt = lastActiveAt
        self.lifecycleStateRaw = lifecycleStateRaw
        self.generation = generation
    }
}

// MARK: - Convenience accessors

extension CatalogRecord {
    var restoreDisposition: CatalogRestoreDisposition {
        get { CatalogRestoreDisposition(rawValue: restoreDispositionRaw) ?? .visible }
        set { restoreDispositionRaw = newValue.rawValue }
    }

    var lifecycleState: CatalogLifecycleState {
        get { CatalogLifecycleState(rawValue: lifecycleStateRaw) ?? .closed }
        set { lifecycleStateRaw = newValue.rawValue }
    }

    var placement: CatalogWindowPlacement {
        CatalogWindowPlacement(
            frameX: frameX,
            frameY: frameY,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            screenID: screenID,
            isFullScreen: isFullScreen
        )
    }

    func applyPlacement(_ placement: CatalogWindowPlacement) {
        frameX = placement.frameX
        frameY = placement.frameY
        frameWidth = placement.frameWidth
        frameHeight = placement.frameHeight
        screenID = placement.screenID
        isFullScreen = placement.isFullScreen
    }

    func snapshot(workspaceID: WorkspaceID? = nil) -> CatalogSnapshot {
        CatalogSnapshot(
            id: CatalogID(rawValue: id),
            workspaceID: workspaceID,
            startURL: startURL,
            currentURL: currentURL,
            title: title,
            profileID: ProfileID(rawValue: profileID),
            isPrivate: isPrivate,
            configurationFingerprint: configurationFingerprint,
            placement: placement,
            restoreDisposition: restoreDisposition,
            zoomLevel: zoomLevel,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastActiveAt: lastActiveAt,
            lifecycleState: lifecycleState,
            generation: generation
        )
    }
}
