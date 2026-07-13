import Foundation

struct WebAppConfig: Codable {
    var url: URL?
    var urls: [URL]?
    var title: String
    var windowTitle: String?
    var profileID: String
    var isPrivate: Bool
    var windowStyle: String?
}
