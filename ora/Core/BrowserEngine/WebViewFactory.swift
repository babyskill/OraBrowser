import Foundation

final class WebViewFactory {
    static let shared = WebViewFactory()

    func makePage(
        profile: BrowserEngineProfile,
        configuration: BrowserPageConfiguration,
        delegate: BrowserPageDelegate?
    ) -> BrowserPage {
        return BrowserPage(profile: profile, configuration: configuration, delegate: delegate)
    }
}
