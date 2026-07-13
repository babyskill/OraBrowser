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
    @State private var isHovering = false

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
    private func tabButton(for tab: Tab, isActiveTab: Bool) -> some View {
        let isSelected = tabManager.isActive(tab)
        let showItem = isHovering || isActiveTab

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
            .scaleEffect(tab.isPlayingMedia ? 0.8 : 1.0)
            .padding(6)
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .frame(
            width: style == .horizontal ? (showItem ? 32 : 0) : 32,
            height: style == .vertical ? (showItem ? 32 : 0) : 32
        )
        .opacity(showItem ? 1.0 : 0.0)
        .clipped()
    }

    @ViewBuilder
    private func capsuleView(for sortedTabs: [Tab]) -> some View {
        let itemWidth: CGFloat = 32
        let spacing: CGFloat = 8
        let maxVisibleItems = 5
        let currentSpacing = isHovering ? spacing : 0
        let limitWidth = CGFloat(maxVisibleItems) * itemWidth + CGFloat(maxVisibleItems - 1) * spacing

        let activeTab = sortedTabs.first(where: { tabManager.isActive($0) }) ?? sortedTabs.first

        Group {
            if style == .horizontal {
                Group {
                    if sortedTabs.count <= maxVisibleItems {
                        HStack(spacing: currentSpacing) {
                            ForEach(sortedTabs) { tab in
                                tabButton(for: tab, isActiveTab: tab == activeTab)
                            }
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: currentSpacing) {
                                ForEach(sortedTabs) { tab in
                                    tabButton(for: tab, isActiveTab: tab == activeTab)
                                }
                            }
                        }
                        .frame(width: isHovering ? limitWidth : itemWidth)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            } else {
                Group {
                    if sortedTabs.count <= maxVisibleItems {
                        VStack(spacing: currentSpacing) {
                            ForEach(sortedTabs) { tab in
                                tabButton(for: tab, isActiveTab: tab == activeTab)
                            }
                        }
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: currentSpacing) {
                                ForEach(sortedTabs) { tab in
                                    tabButton(for: tab, isActiveTab: tab == activeTab)
                                }
                            }
                        }
                        .frame(height: isHovering ? limitWidth : itemWidth)
                    }
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
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isHovering = hovering
            }
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
}
