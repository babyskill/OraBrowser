import AppKit
import SwiftUI

// MARK: - Overlay State

enum SnapshotOverlayState: Equatable {
    case blank
    case skeleton
    case loading(snapshotKey: String?)
    case snapshot(NSImage?)
    case error(CatalogSurfaceError)
    case fadingToLive(pageLeaseID: PageLeaseID)
    case live

    static func == (lhs: SnapshotOverlayState, rhs: SnapshotOverlayState) -> Bool {
        switch (lhs, rhs) {
        case (.blank, .blank): return true
        case (.skeleton, .skeleton): return true
        case let (.loading(lk), .loading(rk)): return lk == rk
        case let (.snapshot(li), .snapshot(ri)): return li === ri
        case let (.error(le), .error(re)): return le == re
        case let (.fadingToLive(ll), .fadingToLive(rl)): return ll == rl
        case (.live, .live): return true
        default: return false
        }
    }

    var isFadingToLive: Bool {
        if case .fadingToLive = self { return true }
        return false
    }
}

// MARK: - Surface Error

struct CatalogSurfaceError: Equatable {
    let message: String
    let isRetryable: Bool
}

// MARK: - Snapshot Key

struct SnapshotKey: Hashable, Sendable {
    let catalogID: CatalogID
    let generation: Int
    let viewportClass: String
}

// MARK: - Snapshot Presentation

struct SnapshotPresentation: Equatable {
    let image: NSImage
    let key: SnapshotKey

    static func == (lhs: SnapshotPresentation, rhs: SnapshotPresentation) -> Bool {
        lhs.key == rhs.key
    }
}

// MARK: - Snapshot Overlay View

struct SnapshotOverlay: View {
    let state: SnapshotOverlayState
    let onRetry: (() -> Void)?

    var body: some View {
        ZStack {
            switch state {
            case .blank:
                Color(.windowBackgroundColor)

            case .skeleton:
                skeletonView()

            case .loading:
                loadingView()

            case let .snapshot(image):
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    skeletonView()
                }

            case let .error(error):
                errorView(message: error.message, retryable: error.isRetryable)

            case .fadingToLive:
                EmptyView()

            case .live:
                EmptyView()
            }
        }
        .allowsHitTesting(state != .live)
        .accessibilityElement(children: state == .live ? .contain : .combine)
        .accessibilityLabel(accessibilityLabel)
        .opacity(state.isFadingToLive ? 0 : 1)
        .animation(state.isFadingToLive ? .easeInOut(duration: 0.1) : nil, value: state)
    }

    // MARK: - Subviews

    @ViewBuilder
    private func skeletonView() -> some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.6)
                        .opacity(0.5)
                    Text("Loading…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            )
    }

    @ViewBuilder
    private func loadingView() -> some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.6)
                        .opacity(0.5)
                    Text("Loading…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            )
    }

    @ViewBuilder
    private func errorView(message: String, retryable: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if retryable, let onRetry {
                Button("Retry") { onRetry() }
                    .keyboardShortcut(.return)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        switch state {
        case .blank:
            return "Blank surface"
        case .skeleton:
            return "Loading live content"
        case .loading:
            return "Loading live content"
        case .snapshot:
            return "Snapshot of last content"
        case let .error(err):
            return "Error: \(err.message)"
        case .fadingToLive:
            return "Loading complete"
        case .live:
            return ""
        }
    }
}
