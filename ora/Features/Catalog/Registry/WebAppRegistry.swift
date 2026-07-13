import Combine
import Foundation

struct WebAppRecord: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let startURL: String
    let profileID: String
    let createdDate: Date
    let version: String
}

final class WebAppRegistry: ObservableObject {
    static let shared = WebAppRegistry()

    private let fileName = "webapp-registry.json"
    private let fileManager = FileManager.default
    private var registryDirectory: URL {
        let base = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("com.orabrowser.app", isDirectory: true)
    }

    private var registryURL: URL {
        registryDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    func listApps() -> [WebAppRecord] {
        guard fileManager.fileExists(atPath: registryURL.path) else {
            return []
        }

        guard let data = try? Data(contentsOf: registryURL) else {
            return []
        }

        do {
            return try JSONDecoder().decode([WebAppRecord].self, from: data)
        } catch {
            return []
        }
    }

    func registerApp(_ record: WebAppRecord) {
        ensureRegistryDirectory()
        var apps = listApps()

        if let index = apps.firstIndex(where: { $0.id == record.id }) {
            apps[index] = record
        } else {
            apps.append(record)
        }

        saveApps(apps)
    }

    func unregisterApp(id: String) {
        ensureRegistryDirectory()
        let apps = listApps().filter { $0.id != id }
        saveApps(apps)
    }

    private func saveApps(_ apps: [WebAppRecord]) {
        do {
            let data = try JSONEncoder().encode(apps)
            try data.write(to: registryURL, options: .atomic)
        } catch {
            print("Failed to save web-app registry: \(error)")
        }
    }

    private func ensureRegistryDirectory() {
        do {
            try fileManager.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create web-app registry directory: \(error)")
        }
    }
}
