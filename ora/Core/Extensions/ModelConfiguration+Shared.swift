import Foundation
import SwiftData

extension ModelConfiguration {
    /// Shared model configuration for the main Ora database
    static func oraDatabase(isPrivate: Bool = false, disableCloudKit: Bool = false) -> ModelConfiguration {
        if isPrivate {
            return ModelConfiguration(
                "OraDataPrivate",
                schema: Schema([TabContainer.self, History.self, Download.self, CatalogRecord.self]),
                url: URL.applicationSupportDirectory.appending(path: "Ora/OraDataPrivate.sqlite"),
                cloudKitDatabase: .none
            )
        } else {
            let hasICloudContainer = FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
            let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = disableCloudKit
                ? .none
                : (UserDefaults.standard.bool(forKey: "settings.icloudSyncEnabled") && hasICloudContainer
                    ? .private("iCloud.com.capybara.moon.browser")
                    : .none)
            return ModelConfiguration(
                "OraData",
                schema: Schema([TabContainer.self, History.self, Download.self, CatalogRecord.self]),
                url: URL.applicationSupportDirectory.appending(path: "Ora/OraData.sqlite"),
                cloudKitDatabase: cloudKitDatabase
            )
        }
    }

    /// Creates a ModelContainer using the standard Ora database configuration
    static func createOraContainer(isPrivate: Bool = false, disableCloudKit: Bool = false) throws -> ModelContainer {
        return try ModelContainer(
            for: TabContainer.self, History.self, Download.self, CatalogRecord.self,
            configurations: oraDatabase(isPrivate: isPrivate, disableCloudKit: disableCloudKit)
        )
    }
}
