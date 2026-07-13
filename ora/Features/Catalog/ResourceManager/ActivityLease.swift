import Foundation

// MARK: - Lease Type

enum LeaseType: String, Hashable, Codable, Sendable, CaseIterable {
    case aiGeneration
    case fileTransfer
    case mediaPlayback
    case userInteraction
}

// MARK: - Activity Lease

struct ActivityLease: Identifiable, Hashable, Sendable {
    let id: UUID
    let catalogID: CatalogID
    let type: LeaseType
    let expiresAt: Date
    let metadata: [String: String]

    var isExpired: Bool {
        Date() >= expiresAt
    }

    init(
        id: UUID = UUID(),
        catalogID: CatalogID,
        type: LeaseType,
        expiresAt: Date,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.catalogID = catalogID
        self.type = type
        self.expiresAt = expiresAt
        self.metadata = metadata
    }
}
