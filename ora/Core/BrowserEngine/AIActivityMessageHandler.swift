import Foundation
@preconcurrency import WebKit

protocol AIActivityDelegate: AnyObject {
    func didReceiveActivityUpdate(catalogID: CatalogID, type: LeaseType, isStarting: Bool)
}

final class AIActivityMessageHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    weak var delegate: AIActivityDelegate?

    private let catalogID: CatalogID

    init(catalogID: CatalogID, delegate: AIActivityDelegate? = nil) {
        self.catalogID = catalogID
        self.delegate = delegate
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "oraAIActivity",
              let body = message.body as? [String: Any],
              let status = body["status"] as? String,
              let rawType = body["type"] as? String,
              let type = LeaseType(rawValue: rawType),
              status == "started" || status == "stopped"
        else { return }

        delegate?.didReceiveActivityUpdate(
            catalogID: catalogID,
            type: type,
            isStarting: status == "started"
        )
    }
}
