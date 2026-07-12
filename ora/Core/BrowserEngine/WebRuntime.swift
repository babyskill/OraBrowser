import Foundation

// MARK: - Acquire request

struct PageAcquireRequest: Sendable {
    let catalogID: CatalogID
    let generation: Int
    let profileID: ProfileID
    let isPrivate: Bool
    let configurationFingerprint: String
    let userAgent: String?

    init(
        catalogID: CatalogID,
        generation: Int,
        profileID: ProfileID,
        isPrivate: Bool,
        configurationFingerprint: String,
        userAgent: String? = nil
    ) {
        self.catalogID = catalogID
        self.generation = generation
        self.profileID = profileID
        self.isPrivate = isPrivate
        self.configurationFingerprint = configurationFingerprint
        self.userAgent = userAgent
    }
}

@MainActor
final class WebRuntime {
    static let shared = WebRuntime()

    struct WarmEntry {
        let page: BrowserPage
        let compatibility: PageCompatibility
        let fingerprint: String
    }

    private let warmPageCapacity: Int
    private let warmPageEnabled: Bool
    private(set) var warmPool: [PageCompatibility: [WarmEntry]] = [:]

    private var activeLeasesByCatalog: [CatalogID: PageLease] = [:]
    private var activeLeasesByID: [PageLeaseID: PageLease] = [:]

    init(warmPageCapacity: Int = 4, warmPageEnabled: Bool = true) {
        self.warmPageCapacity = warmPageCapacity
        self.warmPageEnabled = warmPageEnabled
    }

    // MARK: - Acquire

    func acquirePage(for request: PageAcquireRequest) throws -> PageLease {
        let compatibility = PageCompatibility(
            catalogID: request.catalogID,
            profileID: request.profileID,
            isPrivate: request.isPrivate,
            configurationFingerprint: request.configurationFingerprint
        )

        if let active = activeLeasesByCatalog[request.catalogID], active.state != .released {
            if active.generation != request.generation {
                active.release(reason: .recycle)
            } else {
                throw PageLeaseError.duplicateLease(active.pageID)
            }
        }

        if let entry = claimWarmPage(matching: compatibility, fingerprint: request.configurationFingerprint) {
            let lease = PageLease(
                catalogID: request.catalogID,
                generation: request.generation,
                compatibility: compatibility,
                page: entry
            )
            lease.markActive()
            activeLeasesByCatalog[request.catalogID] = lease
            activeLeasesByID[lease.id] = lease
            return lease
        }

        let profile = WebProfileRegistry.shared.profile(
            for: request.profileID.rawValue,
            isPrivate: request.isPrivate
        )
        let config = BrowserPageConfiguration.oraDefault(
            userScripts: [],
            privacySettings: SpacePrivacySettings()
        )
        let configured = BrowserPageConfiguration(
            userAgent: request.userAgent ?? config.userAgent,
            allowsPictureInPicture: config.allowsPictureInPicture,
            allowsJavaScript: config.allowsJavaScript,
            allowsJavaScriptWindowsAutomatically: config.allowsJavaScriptWindowsAutomatically,
            allowsAirPlayForMediaPlayback: config.allowsAirPlayForMediaPlayback,
            allowsInspectableDebugging: config.allowsInspectableDebugging,
            allowsBackForwardNavigationGestures: config.allowsBackForwardNavigationGestures,
            mediaPlaybackRequiresUserAction: config.mediaPlaybackRequiresUserAction,
            scriptMessageNames: config.scriptMessageNames,
            userScripts: config.userScripts,
            privacySettings: config.privacySettings
        )

        let page = WebViewFactory.shared.makePage(profile: profile, configuration: configured, delegate: nil)
        let lease = PageLease(
            catalogID: request.catalogID,
            generation: request.generation,
            compatibility: compatibility,
            page: page
        )
        lease.markActive()

        activeLeasesByCatalog[request.catalogID] = lease
        activeLeasesByID[lease.id] = lease

        guard configured.fingerprint == request.configurationFingerprint else {
            lease.recycle(reason: .reload)
            throw PageLeaseError.fingerprintMismatch
        }

        return lease
    }

    // MARK: - Release

    func releasePage(_ lease: PageLease, reason: PageLeaseReleaseReason) {
        guard let tracked = activeLeasesByCatalog[lease.catalogID], tracked.id == lease.id else {
            return
        }

        activeLeasesByCatalog.removeValue(forKey: lease.catalogID)
        activeLeasesByID.removeValue(forKey: lease.id)

        switch reason {
        case .close where !lease.compatibility.isPrivate && warmPageEnabled:
            releaseToWarmCache(lease)
        default:
            lease.release(reason: reason)
        }
    }

    func recyclePage(_ lease: PageLease, reason: PageRecycleReason) {
        guard activeLeasesByCatalog[lease.catalogID]?.id == lease.id else { return }
        activeLeasesByCatalog.removeValue(forKey: lease.catalogID)
        activeLeasesByID.removeValue(forKey: lease.id)
        lease.recycle(reason: reason)
    }

    // MARK: - Helpers

    private func claimWarmPage(matching compatibility: PageCompatibility, fingerprint: String) -> BrowserPage? {
        guard let entries = warmPool[compatibility], !entries.isEmpty else { return nil }
        guard let entry = warmPool[compatibility]?.popLast(), entry.fingerprint == fingerprint else {
            return nil
        }
        warmPool[compatibility]?.removeAll { $0.fingerprint != fingerprint }
        if warmPool[compatibility]?.isEmpty == true {
            warmPool[compatibility] = nil
        }
        return entry.page
    }

    private func releaseToWarmCache(_ lease: PageLease) {
        lease.detachFromHost()
        lease.browserPage.stopLoading()

        let entry = WarmEntry(
            page: lease.browserPage,
            compatibility: lease.compatibility,
            fingerprint: lease.compatibility.configurationFingerprint
        )

        var list = warmPool[lease.compatibility] ?? []
        list.append(entry)
        if list.count > warmPageCapacity {
            _ = list.removeFirst()
        }
        warmPool[lease.compatibility] = list

        lease.markStaleAndRelease()
    }

    // MARK: - Diagnostics

    func activeLeaseCount() -> Int {
        activeLeasesByID.count
    }

    func warmPageCount() -> Int {
        warmPool.values.reduce(0) { $0 + $1.count }
    }

    func drain() {
        for lease in activeLeasesByID.values {
            lease.release(reason: .terminate)
        }
        activeLeasesByID.removeAll()
        activeLeasesByCatalog.removeAll()

        for bucket in warmPool.values {
            bucket.forEach { $0.page.teardown() }
        }
        warmPool.removeAll()
    }
}
