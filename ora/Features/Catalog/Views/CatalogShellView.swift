import SwiftUI

struct CatalogShellView: View {
    let context: CatalogWindowContext
    let actions: CatalogShellActions

    @State private var isLoading = true
    @State private var errorMessage: String?

    @State private var dependencies: CatalogRootDependencies?

    var body: some View {
        ZStack {
            if let errorMessage {
                errorSurface(message: errorMessage)
            } else if isLoading {
                loadingSurface()
            } else if let dependencies {
                OraRoot(dependencies: dependencies)
            }
        }
        .frame(minWidth: 500, minHeight: 360)
        .onAppear {
            do {
                let deps = ApplicationGraph.shared.dependencies(for: context)
                self.dependencies = deps
                isLoading = false
            } catch {
                errorMessage = "Failed to load dependencies: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    @ViewBuilder
    private func loadingSurface() -> some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .opacity(0.5)
            )
    }

    @ViewBuilder
    private func errorSurface(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Close") {
                actions.close()
            }
            .keyboardShortcut(.return)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Actions

struct CatalogShellActions {
    let close: () -> Void
    let reload: () -> Void
    let focusLocation: () -> Void
    let toggleFullScreen: () -> Void
}
