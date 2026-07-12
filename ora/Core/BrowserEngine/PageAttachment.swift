import AppKit
import Foundation

// MARK: - Page Attachment Token

struct PageAttachment {
    let windowLeaseID: WindowLeaseID
    let pageLeaseID: PageLeaseID
    let catalogID: CatalogID
    let generation: Int
    let contentView: NSView
}

// MARK: - Attachment Validation

enum PageAttachmentError: Error {
    case windowLeaseMismatch(expected: WindowLeaseID, received: WindowLeaseID)
    case pageLeaseMismatch(expected: PageLeaseID, received: PageLeaseID)
    case catalogMismatch(expected: CatalogID, received: CatalogID)
    case staleGeneration(expected: Int, received: Int)
    case alreadyAttached(PageLeaseID)
    case noViewToAttach
}

// MARK: - Attachment Guard

struct PageAttachmentGuard {
    let expectedWindowLeaseID: WindowLeaseID
    let expectedCatalogID: CatalogID
    let expectedGeneration: Int

    func validate(_ attachment: PageAttachment) throws {
        guard attachment.windowLeaseID == expectedWindowLeaseID else {
            throw PageAttachmentError.windowLeaseMismatch(
                expected: expectedWindowLeaseID,
                received: attachment.windowLeaseID
            )
        }
        guard attachment.catalogID == expectedCatalogID else {
            throw PageAttachmentError.catalogMismatch(
                expected: expectedCatalogID,
                received: attachment.catalogID
            )
        }
        guard attachment.generation == expectedGeneration else {
            throw PageAttachmentError.staleGeneration(
                expected: expectedGeneration,
                received: attachment.generation
            )
        }
    }

    static func attach(
        _ attachment: PageAttachment,
        to hostView: NSView,
        guard: PageAttachmentGuard
    ) throws {
        try `guard`.validate(attachment)
        let contentView = attachment.contentView
        contentView.frame = hostView.bounds
        contentView.autoresizingMask = [.width, .height]
        hostView.addSubview(contentView)
    }
}
