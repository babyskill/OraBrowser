import AppKit
import Foundation

// MARK: - Typed Identifiers

struct ShellID: Hashable, Sendable {
    let rawValue: UUID

    init() { self.rawValue = UUID() }
    init(rawValue: UUID) { self.rawValue = rawValue }
}

struct WindowLeaseID: Hashable, Sendable {
    let rawValue: UUID

    init() { self.rawValue = UUID() }
    init(rawValue: UUID) { self.rawValue = rawValue }
}

// MARK: - Shell Compatibility

struct ShellCompatibility: Hashable, Sendable {
    let shellVersion: Int
    let chromeVariant: String
    let appearanceClass: String
    let minimumOSMajor: Int

    static let current: ShellCompatibility = .init(
        shellVersion: 1,
        chromeVariant: "standard",
        appearanceClass: "system",
        minimumOSMajor: 15
    )
}

// MARK: - Lease State

enum WindowLeaseState: Sendable {
    case reserved
    case binding
    case visible
    case releasing
    case reset
    case pooled
    case destroying
    case destroyed
}

// MARK: - Release & Destroy Reasons

enum WindowLeaseReleaseReason: Sendable {
    case userClose
    case terminate
    case allWindows
    case reset
}

enum ShellDestroyReason: Sendable {
    case resetFailed(ShellResetReport)
    case ttlExpired
    case overflow
    case compatibilityInvalidated
    case terminate
}

// MARK: - Window Lease Errors

enum WindowLeaseError: Error {
    case incompatibleShell
    case staleGeneration
    case bindingFailed
    case duplicateLease(ShellID)
    case resetFailed(ShellResetReport)
}

// MARK: - Window Lease

@MainActor
final class WindowLease {
    let id: WindowLeaseID
    let shellID: ShellID
    let catalogID: CatalogID
    let generation: Int
    let compatibility: ShellCompatibility
    let shell: ReusableWindowShell

    private(set) var state: WindowLeaseState = .reserved

    private(set) var controller: CatalogWindowController?
    private var pageAttachmentID: PageLeaseID?

    var isActive: Bool {
        state == .binding || state == .visible
    }

    init(
        id: WindowLeaseID = WindowLeaseID(),
        shellID: ShellID = ShellID(),
        catalogID: CatalogID,
        generation: Int,
        compatibility: ShellCompatibility,
        shell: ReusableWindowShell
    ) {
        self.id = id
        self.shellID = shellID
        self.catalogID = catalogID
        self.generation = generation
        self.compatibility = compatibility
        self.shell = shell
    }

    func attach(controller: CatalogWindowController) {
        self.controller = controller
    }

    func setState(_ next: WindowLeaseState) {
        state = next
    }

    func orderFront() {
        guard state == .visible || state == .binding else { return }
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func attach(_ pageLease: PageLease) throws {
        guard state == .visible || state == .binding else {
            throw WindowLeaseError.staleGeneration
        }
        guard let controller else {
            throw WindowLeaseError.bindingFailed
        }
        let attachment = PageAttachment(
            windowLeaseID: id,
            pageLeaseID: pageLease.id,
            catalogID: catalogID,
            generation: generation,
            contentView: pageLease.contentView
        )

        let attachmentGuard = PageAttachmentGuard(
            expectedWindowLeaseID: id,
            expectedCatalogID: catalogID,
            expectedGeneration: generation
        )
        try PageAttachmentGuard.attach(
            attachment,
            to: controller.pageHostView,
            guard: attachmentGuard
        )
        pageAttachmentID = pageLease.id
    }

    func detachPage(expectedPageLeaseID: PageLeaseID?) {
        guard let currentID = pageAttachmentID else { return }
        if let expectedPageLeaseID, expectedPageLeaseID != currentID {
            return
        }

        controller?.pageHostView.subviews.forEach { $0.removeFromSuperview() }
        pageAttachmentID = nil
    }

    func beginRelease() {
        guard state != .releasing, state != .destroying, state != .destroyed else { return }
        state = .releasing
    }

    func release(reason: WindowLeaseReleaseReason) async {
        guard state == .releasing else { return }

        detachPage(expectedPageLeaseID: nil)
        state = .pooled
    }

    func destroy(reason: ShellDestroyReason) {
        guard state != .destroying, state != .destroyed else { return }
        state = .destroying
        detachPage(expectedPageLeaseID: nil)
        controller?.destroy()
        controller = nil
        state = .destroyed
    }

    func clearBinding() {
        pageAttachmentID = nil
        controller?.clearForReuse()
    }
}
