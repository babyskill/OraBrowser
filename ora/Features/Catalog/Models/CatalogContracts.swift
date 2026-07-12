import Foundation
import SwiftUI

// MARK: - Typed Identifiers

struct CatalogID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init() {
        self.rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

struct WorkspaceID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init() {
        self.rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

struct ProfileID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init() {
        self.rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

// MARK: - Lifecycle & Restore Enums

enum CatalogLifecycleState: String, Codable, Sendable {
    case closed
    case opening
    case visible
    case hidden
    case crashed
    case throttled
    case hibernated
}

enum CatalogRestoreDisposition: String, Codable, Sendable {
    case visible
    case hidden
    case closed
}

// MARK: - Layout Value Types

struct CatalogWindowPlacement: Codable, Sendable {
    var frameX: Double
    var frameY: Double
    var frameWidth: Double
    var frameHeight: Double
    var screenID: String?
    var isFullScreen: Bool
}

struct ResolvedWindowPlacement: Sendable {
    let frame: CGRect
    let screenID: String?
    let isFullScreen: Bool
}

struct ScreenDescriptor: Equatable, Sendable {
    let displayID: String
    let visibleFrame: CGRect
    let fullFrame: CGRect
}

// MARK: - Catalog Snapshot

struct CatalogSnapshot: Sendable {
    let id: CatalogID
    let workspaceID: WorkspaceID?
    let startURL: URL
    let currentURL: URL
    let title: String?
    let profileID: ProfileID
    let isPrivate: Bool
    let configurationFingerprint: String
    let placement: CatalogWindowPlacement
    let restoreDisposition: CatalogRestoreDisposition
    let zoomLevel: Double
    let createdAt: Date
    let updatedAt: Date
    let lastActiveAt: Date
    let lifecycleState: CatalogLifecycleState
    let generation: Int
}

// MARK: - Requests

struct CreateCatalogRequest: Sendable {
    let startURL: URL
    let profileID: ProfileID
    let isPrivate: Bool
    let configurationFingerprint: String
    let placement: CatalogWindowPlacement?
    let workspaceID: WorkspaceID?
}

struct OpenCatalogRequest: Sendable {
    let startURL: URL
    let profileID: ProfileID
    let isPrivate: Bool
    let configurationFingerprint: String
    let preferredPlacement: CatalogWindowPlacement?
}

// MARK: - Windowing Request Models

struct WindowAcquireRequest: Sendable {
    let catalogID: CatalogID
    let generation: Int
    let shellCompatibility: ShellCompatibility
    let placement: CatalogWindowPlacement?
}

struct CatalogShellBinding: Sendable {
    let catalogID: CatalogID
    let generation: Int
    let profileID: ProfileID
    let title: String?
    let startURL: URL
    let isPrivate: Bool
    let configurationFingerprint: String
    let windowPlacement: CatalogWindowPlacement?
}

struct CatalogWindowContext: Sendable {
    let catalogID: CatalogID
    let profileID: ProfileID
    let generation: Int
}

// MARK: - Overlay and root view models

struct CatalogShellActions {
    let close: () -> Void
    let reload: () -> Void
    let focusLocation: () -> Void
    let toggleFullScreen: () -> Void
}

@MainActor
final class CatalogShellState: ObservableObject {
    let binding: CatalogShellBinding
    let context: CatalogWindowContext
    let actions: CatalogShellActions
    let dependencies: CatalogRootDependencies

    @Published private(set) var overlayState: SnapshotOverlayState = .blank

    init(
        binding: CatalogShellBinding,
        context: CatalogWindowContext,
        actions: CatalogShellActions,
        dependencies: CatalogRootDependencies
    ) {
        self.binding = binding
        self.context = context
        self.actions = actions
        self.dependencies = dependencies
    }

    func setOverlayState(_ newState: SnapshotOverlayState) {
        overlayState = newState
    }
}

typealias CatalogRootFactory = (_ state: CatalogShellState) -> NSViewController
typealias CatalogDependenciesFactory = (_ context: CatalogWindowContext) -> CatalogRootDependencies

// MARK: - Updates

struct CatalogNavigationUpdate: Sendable {
    let catalogID: CatalogID
    let currentURL: URL
    let title: String?
    let generation: Int
}

struct CatalogLayoutUpdate: Sendable {
    let catalogID: CatalogID
    let placement: CatalogWindowPlacement
    let generation: Int
}

// MARK: - Window Events

enum CatalogWindowEvent {
    case didBecomeKey(CatalogID, generation: Int, windowLeaseID: WindowLeaseID, at: Date)
    case didResignKey(CatalogID, generation: Int, windowLeaseID: WindowLeaseID)
    case didMoveOrResize(CatalogID, generation: Int, windowLeaseID: WindowLeaseID, frame: CGRect, screenID: String?)
    case didChangeFullScreen(CatalogID, generation: Int, windowLeaseID: WindowLeaseID, isFullScreen: Bool)
    case didMiniaturize(CatalogID, generation: Int, windowLeaseID: WindowLeaseID)
    case closeRequested(CatalogID, generation: Int, windowLeaseID: WindowLeaseID)
    case didClose(CatalogID, generation: Int, windowLeaseID: WindowLeaseID)
    case didChangeOcclusion(CatalogID, generation: Int, windowLeaseID: WindowLeaseID, isOccluded: Bool)
}

protocol CatalogWindowEventSink: AnyObject {
    func handle(_ event: CatalogWindowEvent)
}

// MARK: - Lease-aware Event Context

struct LeaseEventContext: Sendable {
    let windowLeaseID: WindowLeaseID
    let pageLeaseID: PageLeaseID?
    let catalogID: CatalogID
    let generation: Int
}

// MARK: - Close Reason

enum CloseReason: Sendable {
    case userInitiated
    case terminate
    case allWindows
}

// MARK: - Errors

enum CatalogRegistryError: Error {
    case invalidURL(URL)
    case invalidLayout
    case duplicateID(CatalogID)
    case notFound(CatalogID)
    case profileMismatch
    case staleGeneration(expected: Int, received: Int)
    case persistenceFailure(operation: String, underlying: Error)
}

enum CatalogWindowError: Error {
    case duplicateCatalog(CatalogID)
    case catalogNotFound(CatalogID)
    case invalidConfiguration
    case controllerDeallocated
}
