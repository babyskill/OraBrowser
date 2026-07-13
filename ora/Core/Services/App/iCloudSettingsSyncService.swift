import Foundation

final class ICloudSettingsSyncService: NSObject {
    static let shared = ICloudSettingsSyncService()

    private enum SyncedValue: Equatable {
        case bool(Bool)
        case timeInterval(TimeInterval)
        case int(Int)
        case string(String)

        var raw: Any {
            switch self {
            case let .bool(value):
                return value
            case let .timeInterval(value):
                return value
            case let .int(value):
                return value
            case let .string(value):
                return value
            }
        }

        init?(from value: Any?, kind: SyncedValueKind) {
            switch kind {
            case .bool:
                if let boolValue = value as? Bool {
                    self = .bool(boolValue)
                    return
                }
                if let numberValue = value as? NSNumber {
                    self = .bool(numberValue.boolValue)
                    return
                }
                return nil
            case .timeInterval:
                if let doubleValue = value as? TimeInterval {
                    self = .timeInterval(doubleValue)
                    return
                }
                if let numberValue = value as? NSNumber {
                    self = .timeInterval(numberValue.doubleValue)
                    return
                }
                return nil
            case .int:
                if let intValue = value as? Int {
                    self = .int(intValue)
                    return
                }
                if let numberValue = value as? NSNumber {
                    self = .int(numberValue.intValue)
                    return
                }
                return nil
            case .string:
                if let stringValue = value as? String {
                    self = .string(stringValue)
                    return
                }
                return nil
            }
        }
    }

    private enum SyncedValueKind {
        case bool
        case timeInterval
        case int
        case string
    }

    private struct SyncedSetting {
        let key: String
        let kind: SyncedValueKind
        let fallback: SyncedValue
    }

    private let settingsStore = UserDefaults.standard
    private let iCloudStore = NSUbiquitousKeyValueStore.default
    private let syncedSettings: [SyncedSetting]

    private var isStarted = false
    private var isApplyingRemoteUpdate = false
    private var localCache: [String: SyncedValue] = [:]
    private var defaultsObserver: NSObjectProtocol?
    private var cloudObserver: NSObjectProtocol?

    override init() {
        syncedSettings = [
            SyncedSetting(
                key: "settings.autoUpdateEnabled",
                kind: .bool,
                fallback: .bool(false)
            ),
            SyncedSetting(
                key: "settings.tracking.blockThirdParty",
                kind: .bool,
                fallback: .bool(false)
            ),
            SyncedSetting(
                key: "settings.tracking.blockFingerprinting",
                kind: .bool,
                fallback: .bool(true)
            ),
            SyncedSetting(
                key: "settings.tracking.adBlocking",
                kind: .bool,
                fallback: .bool(false)
            ),
            SyncedSetting(
                key: "settings.cookies.policy",
                kind: .string,
                fallback: .string(CookiesPolicy.allowAll.rawValue)
            ),
            SyncedSetting(
                key: "settings.tabAliveTimeout",
                kind: .timeInterval,
                fallback: .timeInterval(60 * 60)
            ),
            SyncedSetting(
                key: "settings.tabRemovalTimeout",
                kind: .timeInterval,
                fallback: .timeInterval(24 * 60 * 60)
            ),
            SyncedSetting(
                key: "settings.maxRecentTabs",
                kind: .int,
                fallback: .int(5)
            ),
            SyncedSetting(
                key: "settings.autoPiPEnabled",
                kind: .bool,
                fallback: .bool(true)
            ),
            SyncedSetting(
                key: "settings.passwords.enabled",
                kind: .bool,
                fallback: .bool(true)
            ),
            SyncedSetting(
                key: "settings.passwords.autofillEnabled",
                kind: .bool,
                fallback: .bool(true)
            ),
            SyncedSetting(
                key: "settings.passwords.autofillSubmitEnabled",
                kind: .bool,
                fallback: .bool(true)
            ),
            SyncedSetting(
                key: "settings.passwords.savePromptsEnabled",
                kind: .bool,
                fallback: .bool(true)
            )
        ]
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            self?.syncLocalChangesToCloud()
        }

        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: iCloudStore,
            queue: .main
        ) { [weak self] note in
            self?.handleCloudStoreChange(note)
        }

        iCloudStore.synchronize()
        syncInitialState()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
        if let observer = cloudObserver {
            NotificationCenter.default.removeObserver(observer)
            cloudObserver = nil
        }

        localCache.removeAll(keepingCapacity: true)
    }

    private func syncInitialState() {
        var cache: [String: SyncedValue] = [:]

        for setting in syncedSettings {
            let localValue = readLocalValue(for: setting)
            if let remoteValue = readRemoteValue(for: setting) {
                if localValue != remoteValue {
                    applyLocal(remoteValue, for: setting)
                    cache[setting.key] = remoteValue
                } else {
                    cache[setting.key] = localValue
                }
            } else {
                writeRemoteValue(localValue, for: setting)
                cache[setting.key] = localValue
            }
        }

        localCache = cache
        iCloudStore.synchronize()
    }

    private func syncLocalChangesToCloud() {
        guard isStarted, !isApplyingRemoteUpdate else { return }

        var hasChanges = false
        for setting in syncedSettings {
            let localValue = readLocalValue(for: setting)
            if localCache[setting.key] != localValue {
                writeRemoteValue(localValue, for: setting)
                localCache[setting.key] = localValue
                hasChanges = true
            }
        }

        if hasChanges {
            iCloudStore.synchronize()
        }
    }

    private func handleCloudStoreChange(_ note: Notification) {
        guard isStarted else { return }

        guard let changedKeys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
            return
        }

        let affected = changedKeys.filter { key in
            syncedSettings.contains(where: { $0.key == key })
        }
        guard !affected.isEmpty else { return }

        isApplyingRemoteUpdate = true
        var cacheChanges: [String: SyncedValue] = [:]
        for key in affected {
            guard let setting = syncedSettings.first(where: { $0.key == key }) else { continue }

            if let remoteValue = readRemoteValue(for: setting) {
                cacheChanges[key] = remoteValue
                if readLocalValue(for: setting) != remoteValue {
                    applyLocal(remoteValue, for: setting)
                }
            }
        }

        for (key, value) in cacheChanges {
            localCache[key] = value
        }
        isApplyingRemoteUpdate = false
    }

    private func readLocalValue(for setting: SyncedSetting) -> SyncedValue {
        let value = settingsStore.object(forKey: setting.key)
        return SyncedValue(from: value, kind: setting.kind) ?? setting.fallback
    }

    private func applyLocal(_ value: SyncedValue, for setting: SyncedSetting) {
        switch value {
        case let .bool(value):
            settingsStore.set(value, forKey: setting.key)
        case let .timeInterval(value):
            settingsStore.set(value, forKey: setting.key)
        case let .int(value):
            settingsStore.set(value, forKey: setting.key)
        case let .string(value):
            settingsStore.set(value, forKey: setting.key)
        }
    }

    private func readRemoteValue(for setting: SyncedSetting) -> SyncedValue? {
        let value = iCloudStore.object(forKey: setting.key)
        return SyncedValue(from: value, kind: setting.kind)
    }

    private func writeRemoteValue(_ value: SyncedValue, for setting: SyncedSetting) {
        iCloudStore.set(value.raw, forKey: setting.key)
    }
}
