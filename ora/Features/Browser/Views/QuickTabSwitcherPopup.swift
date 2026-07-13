import SwiftUI

struct QuickTabSwitcherPopup: View {
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var privacyMode: PrivacyMode
    @EnvironmentObject var historyManager: HistoryManager
    @EnvironmentObject var downloadManager: DownloadManager

    @AppStorage("ui.toolbar.quickTabSwitcherStyle") private var style: QuickTabSwitcherStyle = .horizontal

    var body: some View {
        if let container = tabManager.activeContainer, !container.tabs.isEmpty {
            let sortedTabs = container.tabs.sorted(by: { $0.order < $1.order })
            Group {
                if style == .horizontal {
                    HStack(spacing: 8) {
                        content(for: sortedTabs)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                } else {
                    VStack(spacing: 8) {
                        content(for: sortedTabs)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                }
            }
            .background(
                Capsule()
                    .fill(Material.thin)
                    .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
            )
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func content(for sortedTabs: [Tab]) -> some View {
        ForEach(sortedTabs) { tab in
            let isSelected = tabManager.isActive(tab)
            Button {
                tabManager.activeTab = tab
                if !tab.isWebViewReady {
                    tab.restoreTransientState(
                        historyManager: historyManager,
                        downloadManager: downloadManager,
                        tabManager: tabManager,
                        isPrivate: privacyMode.isPrivate
                    )
                }
            } label: {
                FavIcon(
                    isWebViewReady: tab.isWebViewReady,
                    favicon: tab.favicon,
                    faviconLocalFile: tab.faviconLocalFile,
                    textColor: isSelected ? .white : .primary.opacity(0.8),
                    isPlayingMedia: tab.isPlayingMedia
                )
                .padding(6)
                .background(
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .help(tab.title)
        }
    }
}
