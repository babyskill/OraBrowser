import Foundation
import SwiftUI

enum UserAgentMode: String, CaseIterable, Identifiable {
    case tablet
    case desktop
    case mobile

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tablet: return "Tablet"
        case .desktop: return "Desktop"
        case .mobile: return "Mobile"
        }
    }

    var userAgentString: String {
        switch self {
        case .tablet:
            return "Mozilla/5.0 (iPad; CPU OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/605.1.15"
        case .desktop:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        case .mobile:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/605.1.15"
        }
    }
}

class ToolbarManager: ObservableObject {
    @AppStorage("ui.toolbar.hidden") var isToolbarHidden: Bool = false
    @AppStorage("ui.toolbar.showfullurl") var showFullURL: Bool = true
    @AppStorage("ui.toolbar.showNavigationButtons") var showNavigationButtons: Bool = false
    @AppStorage("ui.toolbar.showQuickTabSwitcher") var showQuickTabSwitcher: Bool = true
    @AppStorage("ui.userAgentMode") var userAgentMode: UserAgentMode = .tablet
}
