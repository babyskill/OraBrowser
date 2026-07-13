import Foundation
import SwiftUI

class ToolbarManager: ObservableObject {
    @AppStorage("ui.toolbar.hidden") var isToolbarHidden: Bool = false
    @AppStorage("ui.toolbar.showfullurl") var showFullURL: Bool = true
    @AppStorage("ui.toolbar.showNavigationButtons") var showNavigationButtons: Bool = false
    @AppStorage("ui.toolbar.showQuickTabSwitcher") var showQuickTabSwitcher: Bool = true
}
