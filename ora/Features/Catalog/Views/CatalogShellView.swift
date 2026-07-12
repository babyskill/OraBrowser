import SwiftUI

struct CatalogShellView: View {
    @ObservedObject var state: CatalogShellState

    var body: some View {
        ZStack {
            OraRoot(dependencies: state.dependencies)

            if state.overlayState != .live {
                SnapshotOverlay(
                    state: state.overlayState,
                    onRetry: state.actions.reload
                )
            }
        }
        .frame(minWidth: 500, minHeight: 360)
    }
}
