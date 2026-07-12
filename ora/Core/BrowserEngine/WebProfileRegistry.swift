import Foundation
import WebKit

final class WebProfileRegistry {
    static let shared = WebProfileRegistry()

    private struct ProfileKey: Hashable {
        let identifier: UUID
        let isPrivate: Bool
    }

    private let lock = NSLock()
    private var profiles: [ProfileKey: BrowserEngineProfile] = [:]
    private var processPools: [ProfileKey: WKProcessPool] = [:]

    func profile(for identifier: UUID, isPrivate: Bool) -> BrowserEngineProfile {
        if isPrivate {
            let key = ProfileKey(identifier: identifier, isPrivate: true)
            lock.lock()
            defer { lock.unlock() }
            if let existing = profiles[key] {
                return existing
            }
            let profile = BrowserEngineProfile(identifier: identifier, isPrivate: true)
            profiles[key] = profile
            return profile
        }

        let key = ProfileKey(identifier: identifier, isPrivate: false)
        lock.lock()
        defer { lock.unlock() }

        if let existing = profiles[key] {
            return existing
        }

        let profile = BrowserEngineProfile(identifier: identifier, isPrivate: false)
        profiles[key] = profile
        return profile
    }

    func processPool(for identifier: UUID, isPrivate: Bool) -> WKProcessPool {
        let key = ProfileKey(identifier: identifier, isPrivate: isPrivate)
        lock.lock()
        defer { lock.unlock() }

        if let existingPool = processPools[key] {
            return existingPool
        }

        let pool = WKProcessPool()
        processPools[key] = pool
        return pool
    }

    func clearRegistry() {
        lock.lock()
        defer { lock.unlock() }
        profiles.removeAll()
        processPools.removeAll()
    }
}
