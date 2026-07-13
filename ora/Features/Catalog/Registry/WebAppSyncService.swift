import Foundation

final class WebAppSyncService {
    static let shared = WebAppSyncService()
    private init() {}

    private let templateAppName = "CapyWebApp"
    private let templateAppExtension = "app"
    private let templateExecutableName = "CapyWebApp"
    private let binaryNameForQuarantine = "com.apple.quarantine"
    private let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    private var templateBundleURL: URL? {
        Bundle.main.url(forResource: templateAppName, withExtension: templateAppExtension)
    }

    private var templateExecutableURL: URL? {
        guard let appURL = templateBundleURL else {
            return nil
        }

        return appURL.appendingPathComponent("Contents/MacOS/\(templateExecutableName)", isDirectory: false)
    }

    func syncWebApps() async {
        guard let sourceBinaryURL = templateExecutableURL else {
            print("WebAppSyncService: Missing CapyWebApp template binary")
            return
        }

        let records = WebAppRegistry.shared.listApps()

        for record in records {
            let appURL = URL(fileURLWithPath: record.path)
            var isDirectory = ObjCBool(false)

            guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                WebAppRegistry.shared.unregisterApp(id: record.id)
                continue
            }

            #if DEBUG
                let needsSync = true
            #else
                let needsSync = record.version != currentVersion
            #endif

            guard needsSync else {
                continue
            }

            do {
                let executableName = sanitizeExecutableName(record.name)
                let destinationBinaryURL = appURL
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("MacOS", isDirectory: true)
                    .appendingPathComponent(executableName, isDirectory: false)

                if FileManager.default.fileExists(atPath: destinationBinaryURL.path) {
                    try FileManager.default.removeItem(at: destinationBinaryURL)
                }

                try FileManager.default.copyItem(at: sourceBinaryURL, to: destinationBinaryURL)

                try runProcess(path: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", appURL.path])
                try runProcess(path: "/usr/bin/xattr", arguments: ["-dr", binaryNameForQuarantine, appURL.path])

                let updatedRecord = WebAppRecord(
                    id: record.id,
                    name: record.name,
                    path: record.path,
                    startURL: record.startURL,
                    profileID: record.profileID,
                    createdDate: record.createdDate,
                    version: currentVersion
                )
                WebAppRegistry.shared.registerApp(updatedRecord)
            } catch {
                print("WebAppSyncService: Failed sync app \(record.name): \(error)")
            }
        }
    }

    private func runProcess(path: String, arguments: [String]) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw error
        }

        process.waitUntilExit()

        let output = String(decoding: (try? stderr.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "WebAppSyncService.ProcessError",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
    }

    private func sanitizeExecutableName(_ name: String) -> String {
        sanitizeDisplayName(name)
    }

    private func sanitizeDisplayName(_ name: String) -> String {
        let value = removeSpecialChars(name)
        return value.isEmpty ? "CapyWebApp" : value
    }

    private func removeSpecialChars(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " ._-"))
        return String(text.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
