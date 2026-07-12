import AppKit
import Foundation

// MARK: - Typed Identifiers

struct PageID: Hashable, Sendable {
    let rawValue: UUID

    init() { self.rawValue = UUID() }
    init(rawValue: UUID) { self.rawValue = rawValue }
}

struct PageLeaseID: Hashable, Sendable {
    let rawValue: UUID

    init() { self.rawValue = UUID() }
    init(rawValue: UUID) { self.rawValue = rawValue }
}

// MARK: - Compatibility & Fingerprint

struct PageCompatibility: Hashable, Sendable {
    let catalogID: CatalogID
    let profileID: ProfileID
    let isPrivate: Bool
    let configurationFingerprint: String
}

// MARK: - Lease State

enum PageLeaseState: Sendable {
    case reserved
    case active
    case releasing
    case released
}

// MARK: - Lease Reason Enums

enum PageLeaseReleaseReason: Sendable {
    case close
    case recycle
    case fingerprintChanged
    case crash
    case terminate
}

enum PageRecycleReason: Sendable {
    case fingerprintChanged
    case privacyModeSwitch
    case navigationError
    case reload
}

// MARK: - Lease Errors

enum PageLeaseError: Error {
    case incompatibleProfile
    case fingerprintMismatch
    case staleGeneration
    case duplicateLease(PageID)
    case pageCreationFailed(underlying: Error)
}

// MARK: - Page Lease

@MainActor
final class PageLease: NSObject {
    let id: PageLeaseID
    let pageID: PageID
    let catalogID: CatalogID
    let generation: Int
    let compatibility: PageCompatibility

    private(set) var state: PageLeaseState = .reserved

    let browserPage: BrowserPage
    private(set) var isReady = false
    private(set) var isDetached = false

    var onReady: ((PageLeaseID) -> Void)?
    var onNavigation: ((BrowserNavigationEvent) -> Void)?
    var onLoadError: ((PageLeaseID, Error, URL?) -> Void)?
    var onCrash: ((PageLeaseID, Error?) -> Void)?

    init(
        id: PageLeaseID = PageLeaseID(),
        pageID: PageID = PageID(),
        catalogID: CatalogID,
        generation: Int,
        compatibility: PageCompatibility,
        page: BrowserPage
    ) {
        self.id = id
        self.pageID = pageID
        self.catalogID = catalogID
        self.generation = generation
        self.compatibility = compatibility
        self.browserPage = page
        super.init()
        self.browserPage.delegate = self
    }

    var contentView: NSView {
        browserPage.contentView
    }

    func load(_ request: URLRequest) {
        guard state == .active else { return }
        browserPage.load(request)
    }

    func reload() {
        guard state == .active else { return }
        browserPage.reload()
    }

    func stopLoading() {
        browserPage.stopLoading()
    }

    func detachFromHost() {
        guard !isDetached else { return }
        isDetached = true
        contentView.removeFromSuperview()
    }

    func captureSnapshot(_ request: SnapshotRequest) async throws -> SnapshotArtifact {
        guard state != .released else {
            throw PageLeaseError.staleGeneration
        }
        return try await withCheckedThrowingContinuation { continuation in
            browserPage.takeSnapshot(configuration: request.snapshotConfig) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: SnapshotArtifact(
                        leaseID: self.id,
                        catalogID: self.catalogID,
                        generation: self.generation,
                        image: image
                    ))
                }
            }
        }
    }

    func release(reason: PageLeaseReleaseReason) {
        guard state != .released, state != .releasing else { return }
        state = .releasing
        detachFromHost()
        browserPage.teardown()
        browserPage.delegate = nil
        isDetached = true
        state = .released
    }

    func recycle(reason: PageRecycleReason) {
        _ = reason
        release(reason: .recycle)
    }

    func markActive() {
        state = .active
        isDetached = false
        isReady = false
    }

    func markStaleAndRelease() {
        release(reason: .recycle)
    }
}

// MARK: - BrowserPageDelegate bridge

@MainActor
extension PageLease: BrowserPageDelegate {
    func browserPage(
        _ page: BrowserPage,
        decidePolicyFor navigationAction: BrowserNavigationAction
    ) -> BrowserNavigationActionDisposition {
        .allow
    }

    func browserPage(_ page: BrowserPage, didUpdateNavigation event: BrowserNavigationEvent) {
        onNavigation?(event)
        if event.phase == .finished, !event.isLoading, !isReady {
            isReady = true
            onReady?(id)
        }
    }

    func browserPage(_ page: BrowserPage, didFailNavigationWith error: Error, failingURL: URL?) {
        onLoadError?(id, error, failingURL)
    }

    func browserPage(_ page: BrowserPage, didReceiveScriptMessage message: BrowserScriptMessage) {}

    func browserPage(
        _ page: BrowserPage,
        requestPermission permission: BrowserPermissionKind,
        origin: URL?,
        decisionHandler: @escaping (BrowserPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }

    func browserPage(
        _ page: BrowserPage,
        runOpenPanelWith options: BrowserOpenPanelOptions,
        completion: @escaping ([URL]?) -> Void
    ) {
        completion(nil)
    }

    func browserPage(_ page: BrowserPage, runJavaScriptAlert message: String) {}

    func browserPage(_ page: BrowserPage, runJavaScriptConfirm message: String, completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    func browserPage(
        _ page: BrowserPage,
        runJavaScriptPrompt message: String,
        defaultText: String?,
        completion: @escaping (String?) -> Void
    ) {
        completion(nil)
    }

    func browserPage(_ page: BrowserPage, didStartDownload download: BrowserDownloadTask) {}

    func browserPageWebProcessDidTerminate(_ page: BrowserPage) {
        isReady = false
        onCrash?(id, nil)
    }
}

// MARK: - Snapshot Types

struct SnapshotRequest: Sendable {
    let snapshotConfig: BrowserSnapshotConfiguration
    let viewportClass: String
}

struct SnapshotArtifact: Sendable {
    let leaseID: PageLeaseID
    let catalogID: CatalogID
    let generation: Int
    let image: NSImage?

    var isValid: Bool { image != nil }
}
