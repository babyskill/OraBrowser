import AppKit
import SwiftUI

struct QuickTabSwitcherPopup: View {
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var privacyMode: PrivacyMode
    @EnvironmentObject var historyManager: HistoryManager
    @EnvironmentObject var downloadManager: DownloadManager

    @AppStorage("ui.toolbar.quickTabSwitcherStyle") private var style: QuickTabSwitcherStyle = .horizontal
    @AppStorage("ui.toolbar.quickTabSwitcherPosition") private var position: QuickTabSwitcherPosition = .bottomLeft

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        if let container = tabManager.activeContainer, !container.tabs.isEmpty {
            let sortedTabs = container.tabs.sorted(by: { $0.order < $1.order })

            GeometryReader { geometry in
                let windowWidth = geometry.size.width

                capsuleView(for: sortedTabs)
                    .offset(x: dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                isDragging = true
                                dragOffset = value.translation.width
                                NSCursor.closedHand.set()
                            }
                            .onEnded { value in
                                isDragging = false
                                let dragX = value.translation.width
                                let velocityX = value.predictedEndTranslation.width

                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    if position == .bottomLeft {
                                        if dragX > windowWidth * 0.25 || velocityX > windowWidth * 0.35 {
                                            position = .bottomRight
                                        }
                                    } else {
                                        if dragX < -windowWidth * 0.25 || velocityX < -windowWidth * 0.35 {
                                            position = .bottomLeft
                                        }
                                    }
                                    dragOffset = 0
                                }
                                NSCursor.arrow.set()
                            }
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: position == .bottomLeft ? .bottomLeading : .bottomTrailing
                    )
            }
        }
    }

    @ViewBuilder
    private func capsuleView(for sortedTabs: [Tab]) -> some View {
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
        )
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .scaleEffect(isDragging ? 0.96 : 1.0)
        .shadow(
            color: Color.black.opacity(isDragging ? 0.25 : 0.15),
            radius: isDragging ? 12 : 6,
            x: 0,
            y: isDragging ? 6 : 3
        )
        .onHover { hovering in
            if hovering {
                if !isDragging {
                    NSCursor.openHand.set()
                }
            } else {
                NSCursor.arrow.set()
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragging)
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
        }
    }
}
