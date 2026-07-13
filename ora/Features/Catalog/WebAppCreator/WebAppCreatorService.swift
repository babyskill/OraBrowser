import AppKit
import Foundation

struct WebAppConfigMock: Codable {
    let url: URL?
    let urls: [URL]?
    let title: String
    let windowTitle: String?
    let profileID: String
    let isPrivate: Bool
    let windowStyle: String?
}

enum WebAppCreatorError: Error {
    case destinationNotFound
    case destinationNotDirectory
    case destinationAlreadyExists(String)
    case templateNotFound
    case copyFailed(Error)
    case configWriteFailed(Error)
    case infoPlistReadFailed(Error)
    case infoPlistWriteFailed(Error)
    case infoPlistFormatInvalid
    case executableRenameFailed(Error)
    case iconGenerationFailed(Error)
    case commandFailed(executable: String, code: Int32, message: String)
}

final class WebAppCreatorService {
    func createWebApp(
        name: String,
        url: URL?,
        urls: [URL]?,
        profileID: String,
        isPrivate: Bool,
        iconPNGData: Data?,
        windowTitle: String?,
        destinationFolder: URL
    ) async throws -> URL {
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: destinationFolder.path) {
            try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        } else {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: destinationFolder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw WebAppCreatorError.destinationNotDirectory
            }
        }

        guard let templateURL = Bundle.main.url(forResource: "CapyWebApp", withExtension: "app") else {
            throw WebAppCreatorError.templateNotFound
        }

        let appName = sanitizeDisplayName(name)
        let executableName = sanitizeExecutableName(name)
        let identifierSuffix = sanitizeBundleIdentifierSuffix(name)
        let destinationAppURL = destinationFolder.appendingPathComponent("\(appName).app", isDirectory: true)

        guard !fileManager.fileExists(atPath: destinationAppURL.path) else {
            throw WebAppCreatorError.destinationAlreadyExists(destinationAppURL.path)
        }

        do {
            try fileManager.copyItem(at: templateURL, to: destinationAppURL)
        } catch {
            throw WebAppCreatorError.copyFailed(error)
        }

        do {
            try writeWebAppConfig(
                url: url,
                urls: urls,
                title: appName,
                windowTitle: windowTitle,
                profileID: profileID,
                isPrivate: isPrivate,
                to: destinationAppURL
            )
            try updateInfoPlist(
                for: destinationAppURL,
                name: appName,
                executable: executableName,
                bundleSuffix: identifierSuffix
            )
            try renameExecutable(at: destinationAppURL, to: executableName)
        } catch {
            throw error
        }

        var iconToUse = iconPNGData
        if iconToUse == nil {
            iconToUse = await fetchFaviconPNGData(for: url ?? urls?.first)
        }

        if let iconPNGData = iconToUse {
            do {
                try createICNS(from: iconPNGData, destinationAppURL: destinationAppURL)
            } catch {
                // sandbox error should not block web-app creation
                if !isSandboxError(error) {
                    print("Icon generation warning: \(error)")
                }
            }
        }

        do {
            try runProcess(path: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", destinationAppURL.path])
            try runProcess(path: "/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", destinationAppURL.path])
            try runProcess(path: "/usr/bin/touch", arguments: [destinationAppURL.path])
            try runProcess(
                path: "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister",
                arguments: ["-f", destinationAppURL.path]
            )
        } catch {
            // sandbox error should not block web-app creation
            if !isSandboxError(error) {
                print("Post-process warning: \(error)")
            }
        }

        let registryRecord = WebAppRecord(
            id: "com.orabrowser.webapp.\(identifierSuffix)",
            name: appName,
            path: destinationAppURL.path,
            startURL: url?.absoluteString ?? urls?.first?.absoluteString ?? "",
            profileID: profileID,
            createdDate: Date(),
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        )
        WebAppRegistry.shared.registerApp(registryRecord)

        return destinationAppURL
    }

    private func writeWebAppConfig(
        url: URL?,
        urls: [URL]?,
        title: String,
        windowTitle: String?,
        profileID: String,
        isPrivate: Bool,
        to appURL: URL
    ) throws {
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try ensureDirectory(resourcesURL)

        let configURL = resourcesURL.appendingPathComponent("webapp-config.json", isDirectory: false)
        let config = WebAppConfigMock(
            url: url,
            urls: urls,
            title: title,
            windowTitle: windowTitle,
            profileID: profileID,
            isPrivate: isPrivate,
            windowStyle: nil
        )

        do {
            let data = try JSONEncoder().encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            throw WebAppCreatorError.configWriteFailed(error)
        }
    }

    private func updateInfoPlist(for appURL: URL, name: String, executable: String, bundleSuffix: String) throws {
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let data: Data

        do {
            data = try Data(contentsOf: infoPlistURL)
        } catch {
            throw WebAppCreatorError.infoPlistReadFailed(error)
        }

        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = try PropertyListSerialization
            .propertyList(from: data, options: [], format: &format) as? [String: Any]
        else {
            throw WebAppCreatorError.infoPlistFormatInvalid
        }

        plist["CFBundleName"] = name
        plist["CFBundleDisplayName"] = name
        plist["CFBundleIdentifier"] = "com.orabrowser.webapp.\(bundleSuffix)"
        plist["CFBundleExecutable"] = executable
        plist["CFBundleIconFile"] = "AppIcon"

        do {
            let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
            try updated.write(to: infoPlistURL, options: .atomic)
        } catch {
            throw WebAppCreatorError.infoPlistWriteFailed(error)
        }
    }

    private func renameExecutable(at appURL: URL, to executableName: String) throws {
        let fileManager = FileManager.default
        let oldPath = appURL.appendingPathComponent("Contents/MacOS/CapyWebApp", isDirectory: false)
        let newPath = appURL.appendingPathComponent("Contents/MacOS/\(executableName)", isDirectory: false)

        guard fileManager.fileExists(atPath: oldPath.path) else {
            return
        }

        do {
            if fileManager.fileExists(atPath: newPath.path) {
                try fileManager.removeItem(at: newPath)
            }
            try fileManager.moveItem(at: oldPath, to: newPath)
        } catch {
            throw WebAppCreatorError.executableRenameFailed(error)
        }
    }

    private func createICNS(from data: Data, destinationAppURL: URL) throws {
        guard NSImage(data: data) != nil else {
            throw WebAppCreatorError.iconGenerationFailed(
                NSError(
                    domain: "WebAppCreatorService.Icon",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid PNG icon data"]
                )
            )
        }

        let fileManager = FileManager.default
        let tempIconset = fileManager.temporaryDirectory.appendingPathComponent(
            "ora-webapp-\(UUID().uuidString).iconset",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: tempIconset) }

        try fileManager.createDirectory(at: tempIconset, withIntermediateDirectories: true)

        let sourcePNG = tempIconset.appendingPathComponent("source.png", isDirectory: false)
        try data.write(to: sourcePNG, options: .atomic)

        let iconEntries: [(size: Int, name: String)] = [
            (16, "icon_16x16"),
            (32, "icon_16x16@2x"),
            (32, "icon_32x32"),
            (64, "icon_32x32@2x"),
            (128, "icon_128x128"),
            (256, "icon_128x128@2x"),
            (256, "icon_256x256"),
            (512, "icon_256x256@2x"),
            (512, "icon_512x512"),
            (1024, "icon_512x512@2x")
        ]

        for item in iconEntries {
            let outputURL = tempIconset.appendingPathComponent("\(item.name).png", isDirectory: false)
            try runProcess(path: "/usr/bin/sips", arguments: [
                "-z",
                String(item.size),
                String(item.size),
                sourcePNG.path,
                "--out",
                outputURL.path
            ])
        }

        let targetICNS = destinationAppURL.appendingPathComponent("Contents/Resources/AppIcon.icns", isDirectory: false)
        if fileManager.fileExists(atPath: targetICNS.path) {
            try fileManager.removeItem(at: targetICNS)
        }

        try runProcess(path: "/usr/bin/iconutil", arguments: ["-c", "icns", tempIconset.path, "-o", targetICNS.path])
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
            throw WebAppCreatorError.commandFailed(executable: path, code: -1, message: error.localizedDescription)
        }

        process.waitUntilExit()
        let stderrMessage = String(decoding: (try? stderr.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            let msg = stderrMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WebAppCreatorError.commandFailed(
                executable: path,
                code: process.terminationStatus,
                message: msg.isEmpty ? "process returned code \(process.terminationStatus)" : msg
            )
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw WebAppCreatorError.destinationNotDirectory
            }
            return
        }

        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func sanitizeDisplayName(_ name: String) -> String {
        let value = removeSpecialChars(name)
        return value.isEmpty ? "CapyWebApp" : value
    }

    private func sanitizeExecutableName(_ name: String) -> String {
        sanitizeDisplayName(name)
    }

    private func sanitizeBundleIdentifierSuffix(_ name: String) -> String {
        var value = removeSpecialChars(name)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        while value.hasPrefix("-") || value.hasSuffix("-") {
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        let result = value.isEmpty ? "webapp" : value
        return result.replacingOccurrences(of: "--", with: "-")
    }

    private func removeSpecialChars(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " ._-"))
        return String(text.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchFaviconPNGData(for url: URL?) async -> Data? {
        guard let websiteURL = url, let domain = websiteURL.host else {
            return nil
        }

        guard let encodedDomain = domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let faviconURL = URL(string: "https://www.google.com/s2/favicons?sz=256&domain=\(encodedDomain)")
        else {
            return nil
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: faviconURL)
            return data.isEmpty ? nil : data
        } catch {
            print("Auto favicon fetch failed: \(error)")
            return nil
        }
    }

    private func isSandboxError(_ error: Error) -> Bool {
        guard let typed = error as? WebAppCreatorError else { return false }

        switch typed {
        case let .commandFailed(_, _, message):
            return message.localizedCaseInsensitiveContains("operation not permitted") ||
                message.localizedCaseInsensitiveContains("sandbox") ||
                message.localizedCaseInsensitiveContains("com.apple.quarantine")
        default:
            return false
        }
    }
}
