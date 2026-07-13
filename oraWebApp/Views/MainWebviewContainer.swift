import SwiftUI
import WebKit

extension Notification.Name {
    static let webAppReload = Notification.Name("webAppReload")
    static let webAppGoBack = Notification.Name("webAppGoBack")
    static let webAppGoForward = Notification.Name("webAppGoForward")
}

// MARK: - WebView Bridge

struct WebView: NSViewRepresentable {
    let url: URL
    let index: Int
    let profileID: String
    let isPrivate: Bool
    let onURLChange: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore()

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        view.load(URLRequest(url: url))
        context.coordinator.setupObservers(webView: view, index: index)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != url {
            nsView.load(URLRequest(url: url))
        }
    }

    private func dataStore() -> WKWebsiteDataStore {
        if isPrivate {
            return WKWebsiteDataStore.nonPersistent()
        }

        let identifier = UUID(uuidString: profileID) ?? UUID()
        return WKWebsiteDataStore(forIdentifier: identifier)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebView
        private var reloadObserver: NSObjectProtocol?
        private var goBackObserver: NSObjectProtocol?
        private var goForwardObserver: NSObjectProtocol?

        init(parent: WebView) {
            self.parent = parent
        }

        deinit {
            if let reloadObserver {
                NotificationCenter.default.removeObserver(reloadObserver)
            }

            if let goBackObserver {
                NotificationCenter.default.removeObserver(goBackObserver)
            }

            if let goForwardObserver {
                NotificationCenter.default.removeObserver(goForwardObserver)
            }
        }

        func setupObservers(webView: WKWebView, index: Int) {
            reloadObserver = NotificationCenter.default.addObserver(
                forName: .webAppReload,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleNavigationNotification(
                    for: webView,
                    notification: notification,
                    index: index
                ) { $0.reload() }
            }

            goBackObserver = NotificationCenter.default.addObserver(
                forName: .webAppGoBack,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleNavigationNotification(
                    for: webView,
                    notification: notification,
                    index: index
                ) { webView in
                    if webView.canGoBack {
                        webView.goBack()
                    }
                }
            }

            goForwardObserver = NotificationCenter.default.addObserver(
                forName: .webAppGoForward,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleNavigationNotification(
                    for: webView,
                    notification: notification,
                    index: index
                ) { webView in
                    if webView.canGoForward {
                        webView.goForward()
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let currentURL = webView.url else { return }
            parent.onURLChange?(currentURL)
        }

        private func handleNavigationNotification(
            for webView: WKWebView,
            notification: Notification,
            index: Int,
            action: (WKWebView) -> Void
        ) {
            guard
                let payloadIndex = notification.userInfo?["index"] as? Int,
                payloadIndex == index
            else {
                return
            }

            action(webView)
        }
    }
}

// MARK: - Visual Effects Bridge

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.material = .sidebar
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        return effectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
        nsView.blendingMode = .withinWindow
        nsView.state = .active
    }
}

// MARK: - Add Tab Sheet

struct AddTabSheet: View {
    @Binding var isPresented: Bool
    let onAdd: (URL) -> Void

    @State private var inputURL = ""
    @State private var errorMessage = ""

    private var normalizedURL: URL? {
        let trimmed = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    private var canAddURL: Bool {
        normalizedURL != nil
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Add New Tab")
                .font(.headline)

            TextField("Enter website URL", text: $inputURL)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addURL)
                .onChange(of: inputURL) { _, _ in
                    if errorMessage != "", canAddURL {
                        errorMessage = ""
                    }
                }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }

                Spacer()

                Button("Add") {
                    addURL()
                }
                .disabled(!canAddURL)
            }
        }
        .padding(20)
        .frame(minWidth: 340)
    }

    private func addURL() {
        guard let normalizedURL else {
            errorMessage = "Invalid URL. Example: openai.com or https://openai.com"
            return
        }
        errorMessage = ""
        onAdd(normalizedURL)
        inputURL = ""
    }
}

// MARK: - Main Container

struct MainWebviewContainer: View {
    @ObservedObject var state: WebAppState
    @State private var selectedIndex = 0
    @State private var isAddingTab = false
    @State private var isHoveringAdd = false
    @State private var isSidebarCollapsed = false
    @State private var floatingPosition = CGPoint(x: 40, y: 80)
    @GestureState private var dragOffset = CGSize.zero

    private var urls: [URL] {
        if let configURLs = state.config.urls, !configURLs.isEmpty {
            return configURLs
        }

        if let url = state.config.url {
            return [url]
        }

        return []
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                if urls.count > 1 {
                    if isSidebarCollapsed {
                        ZStack {
                            webViewStack
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            floatingTabBar(in: geometry.size)
                                .position(
                                    x: floatingPosition.x + dragOffset.width,
                                    y: floatingPosition.y + dragOffset.height
                                )
                        }
                    } else {
                        tabLayout
                    }
                } else if let singleURL = urls.first {
                    WebView(
                        url: singleURL,
                        index: 0,
                        profileID: state.config.profileID,
                        isPrivate: state.config.isPrivate,
                        onURLChange: { newURL in
                            state.updateURL(at: 0, to: newURL)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    hoverAddButton
                        .padding(12)
                } else {
                    Text("No URL")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                navigationButtons
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $isAddingTab) {
            AddTabSheet(isPresented: $isAddingTab) { newURL in
                state.addURL(newURL)
                selectedIndex = urls.count
            }
        }
        .navigationTitle(state.config.windowTitle ?? state.config.title)
    }

    private var tabLayout: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()

            webViewStack
                .animation(.easeInOut(duration: 0.18), value: selectedIndex)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var webViewStack: some View {
        ZStack {
            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                WebView(
                    url: url,
                    index: index,
                    profileID: state.config.profileID,
                    isPrivate: state.config.isPrivate,
                    onURLChange: { newURL in
                        state.updateURL(at: index, to: newURL)
                    }
                )
                .opacity(selectedIndex == index ? 1 : 0)
                .disabled(selectedIndex != index)
                .allowsHitTesting(selectedIndex == index)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    isSidebarCollapsed = true
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.top, 10)
            .padding(.horizontal, 10)

            Spacer().frame(height: 12)

            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                Button {
                    selectedIndex = index
                } label: {
                    sidebarItem(for: url, index: index)
                }
                .buttonStyle(.plain)
            }

            Divider()
                .frame(height: 1)
                .padding(.horizontal, 12)

            Button {
                isAddingTab = true
            } label: {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.08))
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(width: 64)
        .background {
            VisualEffectView()
        }
    }

    private func sidebarItem(for url: URL, index: Int) -> some View {
        let selected = selectedIndex == index

        return AsyncImage(url: faviconURL(for: url)) { phase in
            Group {
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                case .failure, .empty:
                    fallbackInitial(for: url)
                @unknown default:
                    fallbackInitial(for: url)
                }
            }
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? .blue.opacity(0.2) : .white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .scaleEffect(selected ? 1.08 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: selected)
        }
    }

    private func isVerticalFloatingBar(in size: CGSize) -> Bool {
        let currentY = floatingPosition.y + dragOffset.height
        return currentY < (size.height / 2)
    }

    private func floatingTabBar(in size: CGSize) -> some View {
        let isVertical = isVerticalFloatingBar(in: size)

        return Group {
            if isVertical {
                VStack(spacing: 10) {
                    Button {
                        isSidebarCollapsed = false
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                    }
                    .buttonStyle(.plain)

                    ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                        Button {
                            selectedIndex = index
                        } label: {
                            floatingTabIcon(for: url, index: index)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        isSidebarCollapsed = false
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                    }
                    .buttonStyle(.plain)

                    ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                        Button {
                            selectedIndex = index
                        } label: {
                            floatingTabIcon(for: url, index: index)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.65))
                VisualEffectView()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 6)
        .gesture(
            DragGesture()
                .updating($dragOffset) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    let dropPoint = CGPoint(
                        x: floatingPosition.x + value.translation.width,
                        y: floatingPosition.y + value.translation.height
                    )

                    let snappedPoint = snappedToNearestCorner(
                        from: dropPoint,
                        in: size
                    )

                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        floatingPosition = snappedPoint
                    }
                }
        )
    }

    private func floatingTabIcon(for url: URL, index: Int) -> some View {
        let selected = selectedIndex == index

        return AsyncImage(url: faviconURL(for: url)) { phase in
            Group {
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                case .failure, .empty:
                    fallbackInitial(for: url)
                @unknown default:
                    fallbackInitial(for: url)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2.5)
            )
        }
    }

    private func snappedToNearestCorner(
        from point: CGPoint,
        in size: CGSize
    ) -> CGPoint {
        // Góc trên: dạng dọc, Y cách biên trên 90px để tránh che khuất bộ 3 nút đóng/thu nhỏ (traffic lights) của macOS
        let topLeading = CGPoint(x: 40, y: 90)
        let topTrailing = CGPoint(x: max(size.width - 40, 40), y: 80)

        // Góc dưới: dạng ngang, X cách biên trái/phải 80px để chừa không gian hiển thị cho chiều rộng HStack
        let bottomLeading = CGPoint(x: 80, y: max(size.height - 40, 40))
        let bottomTrailing = CGPoint(x: max(size.width - 80, 80), y: max(size.height - 40, 40))

        let candidates = [topLeading, topTrailing, bottomLeading, bottomTrailing]

        return candidates.min(by: { lhs, rhs in
            let lhsDistance = pow(lhs.x - point.x, 2) + pow(lhs.y - point.y, 2)
            let rhsDistance = pow(rhs.x - point.x, 2) + pow(rhs.y - point.y, 2)
            return lhsDistance < rhsDistance
        }) ?? topLeading
    }

    private func fallbackInitial(for url: URL) -> some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.35))
            Text(hostInitial(for: url))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private func faviconURL(for url: URL) -> URL? {
        guard let host = url.host else {
            return nil
        }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
    }

    private func hostInitial(for url: URL) -> String {
        guard let host = url.host, let first = host.first else { return "?" }
        return String(first).uppercased()
    }

    private var hoverAddButton: some View {
        Button {
            isAddingTab = true
        } label: {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(isHoveringAdd ? 0.9 : 0.08))
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 34, height: 34)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHoveringAdd = hovering
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var navigationButtons: some View {
        HStack {
            Button {
                postWebAppNavigation(.webAppReload)
            } label: {
                Text("")
            }
            .keyboardShortcut("r", modifiers: .command)

            Button {
                postWebAppNavigation(.webAppGoBack)
            } label: {
                Text("")
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Button {
                postWebAppNavigation(.webAppGoForward)
            } label: {
                Text("")
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)

            Button {
                isSidebarCollapsed.toggle()
            } label: {
                Text("")
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    private func postWebAppNavigation(_ name: Notification.Name) {
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: ["index": selectedIndex]
        )
    }
}
