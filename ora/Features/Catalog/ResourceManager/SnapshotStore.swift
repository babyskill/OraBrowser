import AppKit
import Foundation
import OSLog

// MARK: - Snapshot Store

@MainActor
final class SnapshotStore {
    private let fileManager = FileManager.default
    private let baseURL: URL
    private let logger = Logger(subsystem: "com.orabrowser.app", category: "SnapshotStore")

    init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseURL = baseURL
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseURL = appSupport.appendingPathComponent("CatalogWorkspace/snapshots", isDirectory: true)
        }
        ensureDirectory()
    }

    // MARK: - Save

    func save(_ image: NSImage, for key: SnapshotKey, ttl: TimeInterval = 600) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            logger.error("Failed to encode PNG for snapshot: \(key.catalogID.rawValue, privacy: .public)")
            return
        }

        let fileURL = url(for: key)
        let tempURL = fileURL.appendingPathExtension("tmp")

        do {
            try pngData.write(to: tempURL, options: .atomic)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            try fileManager.moveItem(at: tempURL, to: fileURL)
            logger.debug("Snapshot saved: \(fileURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Failed to save snapshot: \(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: tempURL)
        }

        scheduleCleanup(for: key, after: ttl)
    }

    // MARK: - Load

    func load(for key: SnapshotKey) -> NSImage? {
        let fileURL = url(for: key)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        guard let image = NSImage(contentsOf: fileURL) else {
            logger.warning("Snapshot file corrupted, removing: \(fileURL.lastPathComponent, privacy: .public)")
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        return image
    }

    // MARK: - Delete

    func delete(for key: SnapshotKey) {
        let fileURL = url(for: key)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.removeItem(at: fileURL)
            logger.debug("Snapshot deleted: \(fileURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Failed to delete snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteAll(for catalogID: CatalogID) {
        let prefix = snapshotFilenamePrefix(catalogID: catalogID)
        guard let entries = try? fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: entry)
        }
    }

    // MARK: - Private

    private func url(for key: SnapshotKey) -> URL {
        let filename = "\(snapshotFilenamePrefix(catalogID: key.catalogID))_gen\(key.generation)_\(key.viewportClass).png"
        return baseURL.appendingPathComponent(filename)
    }

    private func snapshotFilenamePrefix(catalogID: CatalogID) -> String {
        catalogID.rawValue.uuidString
    }

    private func ensureDirectory() {
        guard !fileManager.fileExists(atPath: baseURL.path) else { return }
        do {
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create snapshot directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleCleanup(for key: SnapshotKey, after ttl: TimeInterval) {
        let fileURL = url(for: key)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ttl))
            guard let self else { return }
            guard self.fileManager.fileExists(atPath: fileURL.path) else { return }
            try? self.fileManager.removeItem(at: fileURL)
        }
    }
}
