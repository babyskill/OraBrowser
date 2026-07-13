import Foundation
import SwiftData

// MARK: - Protocol

@MainActor
protocol CatalogRegistryProtocol: AnyObject {
    func create(_ request: CreateCatalogRequest) throws -> CatalogSnapshot
    func snapshot(for id: CatalogID) throws -> CatalogSnapshot
    func restorableCatalogs() throws -> [CatalogSnapshot]
    func updateNavigation(_ update: CatalogNavigationUpdate) throws
    func updateLayout(_ update: CatalogLayoutUpdate) throws
    func markVisible(_ id: CatalogID, generation: Int) throws
    func markHidden(_ id: CatalogID, generation: Int) throws
    func markCrashed(_ id: CatalogID, generation: Int) throws
    func markClosed(_ id: CatalogID, generation: Int) throws
    func delete(_ id: CatalogID) throws
    func flush() throws
}

// MARK: - Implementation

@MainActor
final class CatalogRegistry: CatalogRegistryProtocol {
    private let normalContext: ModelContext
    private let privateContext: ModelContext

    private let urlAllowList: Set<String> = ["http", "https", "ora", "file"]

    init(normalContainer: ModelContainer, privateContainer: ModelContainer) {
        self.normalContext = ModelContext(normalContainer)
        self.privateContext = ModelContext(privateContainer)
    }

    // MARK: - Context selection

    private func context(for isPrivate: Bool) -> ModelContext {
        isPrivate ? privateContext : normalContext
    }

    // MARK: - URL validation

    private func validateURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(),
              urlAllowList.contains(scheme)
        else {
            throw CatalogRegistryError.invalidURL(url)
        }
    }

    private func validateGeometry(width: Double, height: Double) throws {
        guard width.isFinite, height.isFinite,
              width >= 500, height >= 360
        else {
            throw CatalogRegistryError.invalidLayout
        }
    }

    // MARK: - Create

    func create(_ request: CreateCatalogRequest) throws -> CatalogSnapshot {
        try validateURL(request.startURL)
        if let placement = request.placement {
            try validateGeometry(width: placement.frameWidth, height: placement.frameHeight)
        }

        let context = context(for: request.isPrivate)

        let record = CatalogRecord(
            startURL: request.startURL,
            currentURL: request.startURL,
            profileID: request.profileID.rawValue,
            isPrivate: request.isPrivate,
            configurationFingerprint: request.configurationFingerprint,
            frameX: request.placement?.frameX ?? 0,
            frameY: request.placement?.frameY ?? 0,
            frameWidth: request.placement?.frameWidth ?? 1440,
            frameHeight: request.placement?.frameHeight ?? 900,
            screenID: request.placement?.screenID,
            lifecycleStateRaw: CatalogLifecycleState.opening.rawValue
        )

        if let wsID = request.workspaceID {
            record.workspaceID = wsID.rawValue
        }

        context.insert(record)
        try context.save()

        let wsID: WorkspaceID? = record.workspaceID.map { WorkspaceID(rawValue: $0) }
        return record.snapshot(workspaceID: wsID)
    }

    // MARK: - Snapshot

    func snapshot(for id: CatalogID) throws -> CatalogSnapshot {
        let normalRecord = try fetch(id: id, in: normalContext)
        if let record = normalRecord {
            return record.snapshot(workspaceID: record.workspaceID.map { WorkspaceID(rawValue: $0) })
        }
        if let privateRecord = try fetch(id: id, in: privateContext) {
            return privateRecord.snapshot(workspaceID: privateRecord.workspaceID.map { WorkspaceID(rawValue: $0) })
        }
        throw CatalogRegistryError.notFound(id)
    }

    // MARK: - Restorable

    func restorableCatalogs() throws -> [CatalogSnapshot] {
        let visibleRaw = CatalogRestoreDisposition.visible.rawValue
        let closedRaw = CatalogLifecycleState.closed.rawValue

        let descriptor = FetchDescriptor<CatalogRecord>(
            predicate: #Predicate {
                $0.restoreDispositionRaw == visibleRaw
                    && $0.isPrivate == false
                    && $0.lifecycleStateRaw != closedRaw
            },
            sortBy: [SortDescriptor(\.lastActiveAt, order: .forward)]
        )
        let records = try normalContext.fetch(descriptor)
        return records.map { $0.snapshot(workspaceID: $0.workspaceID.map { WorkspaceID(rawValue: $0) }) }
    }

    // MARK: - Updates

    func updateNavigation(_ update: CatalogNavigationUpdate) throws {
        guard let record = try fetchMutable(id: update.catalogID) else {
            throw CatalogRegistryError.notFound(update.catalogID)
        }
        guard record.generation == update.generation else {
            throw CatalogRegistryError.staleGeneration(
                expected: record.generation, received: update.generation
            )
        }
        try validateURL(update.currentURL)
        record.currentURL = update.currentURL
        record.title = update.title
        record.updatedAt = Date()
        record.lastActiveAt = Date()
        try record.modelContext?.save()
    }

    func updateLayout(_ update: CatalogLayoutUpdate) throws {
        guard let record = try fetchMutable(id: update.catalogID) else {
            throw CatalogRegistryError.notFound(update.catalogID)
        }
        try validateGeometry(
            width: update.placement.frameWidth,
            height: update.placement.frameHeight
        )
        record.applyPlacement(update.placement)
        record.updatedAt = Date()
        try record.modelContext?.save()
    }

    func markVisible(_ id: CatalogID, generation: Int) throws {
        guard let record = try fetchMutable(id: id) else {
            throw CatalogRegistryError.notFound(id)
        }
        guard record.generation == generation else {
            throw CatalogRegistryError.staleGeneration(
                expected: record.generation, received: generation
            )
        }
        record.lifecycleState = .visible
        record.lastActiveAt = Date()
        record.updatedAt = Date()
        try record.modelContext?.save()
    }

    func markHidden(_ id: CatalogID, generation: Int) throws {
        guard let record = try fetchMutable(id: id) else {
            throw CatalogRegistryError.notFound(id)
        }
        guard record.generation == generation else {
            throw CatalogRegistryError.staleGeneration(
                expected: record.generation, received: generation
            )
        }
        record.lifecycleState = .hidden
        record.updatedAt = Date()
        try record.modelContext?.save()
    }

    func markCrashed(_ id: CatalogID, generation: Int) throws {
        guard let record = try fetchMutable(id: id) else {
            throw CatalogRegistryError.notFound(id)
        }
        guard record.generation == generation else {
            throw CatalogRegistryError.staleGeneration(expected: record.generation, received: generation)
        }
        record.lifecycleState = .crashed
        record.updatedAt = Date()
        try record.modelContext?.save()
    }

    func markClosed(_ id: CatalogID, generation: Int) throws {
        guard let record = try fetchMutable(id: id) else {
            throw CatalogRegistryError.notFound(id)
        }
        guard record.generation == generation else {
            throw CatalogRegistryError.staleGeneration(
                expected: record.generation, received: generation
            )
        }
        record.lifecycleState = .closed
        record.restoreDisposition = .closed
        record.generation += 1
        record.updatedAt = Date()
        try record.modelContext?.save()
    }

    func delete(_ id: CatalogID) throws {
        guard let record = try fetchMutable(id: id) else {
            throw CatalogRegistryError.notFound(id)
        }
        let context = record.modelContext!
        context.delete(record)
        try context.save()
    }

    func flush() throws {
        if normalContext.hasChanges {
            try normalContext.save()
        }
        if privateContext.hasChanges {
            try privateContext.save()
        }
    }

    // MARK: - Internal helpers

    private func fetch(id: CatalogID, in context: ModelContext) throws -> CatalogRecord? {
        let descriptor = FetchDescriptor<CatalogRecord>(
            predicate: #Predicate { $0.id == id.rawValue }
        )
        let results = try context.fetch(descriptor)
        return results.first
    }

    private func fetchMutable(id: CatalogID) throws -> CatalogRecord? {
        if let record = try fetch(id: id, in: normalContext) {
            return record
        }
        return try fetch(id: id, in: privateContext)
    }
}
