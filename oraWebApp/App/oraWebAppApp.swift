import Foundation
import SwiftUI

@main
struct OraWebAppApp: App {
    @StateObject private var state = WebAppState()

    var body: some Scene {
        WindowGroup {
            MainWebviewContainer(state: state)
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1024, height: 768)
        .windowResizability(.contentSize)
    }
}

final class WebAppState: ObservableObject {
    @Published private(set) var config: WebAppConfig

    static var dynamicConfigURL: URL {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.orabrowser.app"
        let bundleSupportDirectory = applicationSupport.appendingPathComponent(bundleIdentifier)

        do {
            try fileManager.createDirectory(
                at: bundleSupportDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            print("dynamicConfigURL: failed to create Application Support directory: \(error)")
        }

        return bundleSupportDirectory.appendingPathComponent("config.json")
    }

    init() {
        config = Self.loadConfig() ?? Self.mockConfig
    }

    func saveConfig() {
        do {
            let data = try JSONEncoder().encode(config)
            try data.write(to: Self.dynamicConfigURL, options: .atomic)
        } catch {
            print("saveConfig: failed to persist config to \(Self.dynamicConfigURL.path): \(error)")
        }
    }

    func updateURL(at index: Int, to url: URL) {
        if isSingleMode {
            config.url = url
        } else {
            guard var urls = config.urls else { return }

            guard urls.indices.contains(index) else {
                return
            }

            urls[index] = url
            config.urls = urls
        }

        saveConfig()
    }

    func addURL(_ url: URL) {
        if let currentSingleURL = config.url {
            config.urls = [currentSingleURL, url]
            config.url = nil
        } else if let currentURLs = config.urls, !currentURLs.isEmpty {
            config.urls = (config.urls ?? []) + [url]
        } else {
            config.url = url
        }

        saveConfig()
    }

    private var isSingleMode: Bool {
        guard let urls = config.urls else { return true }
        return urls.isEmpty
    }

    private static func loadConfig() -> WebAppConfig? {
        let dynamicURL = dynamicConfigURL
        let fallbackURL = Bundle.main.url(forResource: "webapp-config", withExtension: "json")

        if FileManager.default.fileExists(atPath: dynamicURL.path) {
            do {
                let data = try Data(contentsOf: dynamicURL)
                return try JSONDecoder().decode(WebAppConfig.self, from: data)
            } catch {
                print("loadConfig: failed to read dynamic config at \(dynamicURL.path): \(error)")
            }
        }

        guard let fallbackURL else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fallbackURL)
            let config = try JSONDecoder().decode(WebAppConfig.self, from: data)
            try data.write(to: dynamicURL, options: .atomic)
            return config
        } catch {
            print("loadConfig: failed to load fallback bundle config: \(error)")
            return nil
        }
    }

    private static var mockConfig: WebAppConfig {
        let fallbackURL = URL(string: "https://chatgpt.com")!
        return WebAppConfig(
            url: fallbackURL,
            urls: [
                fallbackURL,
                URL(string: "https://google.com")!
            ],
            title: "CapyWebApp",
            windowTitle: nil,
            profileID: UUID().uuidString,
            isPrivate: false,
            windowStyle: nil
        )
    }
}
