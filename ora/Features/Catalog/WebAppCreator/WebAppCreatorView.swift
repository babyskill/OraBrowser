import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension WebAppCreatorService {
    static let shared = WebAppCreatorService()
}

struct WebAppCreatorView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case single = "Single"
        case group = "Group"

        var id: String { rawValue }
    }

    enum PrivacyMode: String, CaseIterable, Identifiable {
        case privateMode = "Private"
        case incognito = "Incognito"

        var id: String { rawValue }
    }

    enum IconSource: String, CaseIterable, Identifiable {
        case auto = "Auto Favicon"
        case custom = "Custom File"

        var id: String { rawValue }
    }

    @State private var appName: String = ""
    @State private var mode: Mode = .single
    @State private var singleURL: String = ""
    @State private var groupURLs: [String] = [""]
    @State private var windowTitle: String = ""
    @State private var iconSource: IconSource = .auto
    @State private var privacyMode: PrivacyMode = .privateMode
    @State private var iconData: Data?
    @State private var iconFileName: String = ""
    @State private var creationState: CreationState = .idle

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("App Name")
                    .font(.headline)
                TextField("Enter app name", text: $appName)
            }

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if mode == .single {
                VStack(alignment: .leading, spacing: 8) {
                    Text("URL")
                        .font(.headline)
                    TextField("https://example.com", text: $singleURL)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("URLs")
                        .font(.headline)

                    ForEach(groupURLs.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            TextField("https://example.com", text: $groupURLs[index])
                            Button("−") {
                                if groupURLs.count > 1 {
                                    groupURLs.remove(at: index)
                                }
                            }
                            .disabled(groupURLs.count == 1)
                        }
                    }

                    Button("Add URL") {
                        groupURLs.append("")
                    }
                }
            }

            Picker("Privacy", selection: $privacyMode) {
                Text("Private").tag(PrivacyMode.privateMode)
                Text("Incognito").tag(PrivacyMode.incognito)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                Text("Window Title")
                    .font(.headline)
                TextField(
                    "Enter window title (optional, defaults to app name)",
                    text: $windowTitle
                )
            }

            Picker("Icon Source", selection: $iconSource) {
                ForEach(IconSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: iconSource) { _, newValue in
                if newValue == .auto {
                    iconData = nil
                    iconFileName = ""
                }
            }

            if iconSource == .custom {
                HStack {
                    Button("Select Icon") {
                        selectIcon()
                    }

                    if let fileName = iconFileName.isEmpty ? nil : iconFileName {
                        Text(fileName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let data = iconData, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Spacer()
                }
            }

            Divider()

            Button {
                Task { await createWebApp() }
            } label: {
                HStack(spacing: 8) {
                    if case .loading = creationState {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Create & Save .app")
                }
            }
            .disabled(creationState == .loading)

            resultSection
        }
        .padding()
        .frame(minWidth: 520, minHeight: 460)
    }

    @ViewBuilder
    private var resultSection: some View {
        switch creationState {
        case .idle:
            EmptyView()
        case .loading:
            Text("Creating web app...")
                .foregroundStyle(.secondary)
        case let .success(path):
            Text("Created successfully: \(path)")
                .foregroundStyle(.green)
                .font(.caption)
        case let .failure(message):
            Text(message)
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func selectIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.png]

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                guard NSImage(data: data) != nil else {
                    creationState = .failure("Invalid PNG file.")
                    return
                }

                iconData = data
                iconFileName = url.lastPathComponent
                creationState = .idle
            } catch {
                creationState = .failure(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func createWebApp() async {
        creationState = .loading

        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            creationState = .failure("App Name is required.")
            return
        }

        let selectedURL: URL? = mode == .single ? normalizedURL(from: singleURL) : nil
        let selectedURLs: [URL]? = mode == .group ? normalizedURLs(from: groupURLs) : nil

        if mode == .single, selectedURL == nil {
            creationState = .failure("Single URL is invalid.")
            return
        }

        if mode == .group, selectedURLs == nil || selectedURLs?.isEmpty == true {
            creationState = .failure("At least one valid URL is required.")
            return
        }

        guard let saveURL = selectSaveLocation(for: trimmedName) else {
            creationState = .idle
            return
        }

        let profileID = UUID().uuidString
        let isPrivate = privacyMode == .incognito

        let destinationFolder = saveURL.deletingLastPathComponent()
        let normalizedWindowTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalWindowTitle = normalizedWindowTitle.isEmpty ? nil : normalizedWindowTitle
        let iconPayload = iconSource == .custom ? iconData : nil

        do {
            let created = try await WebAppCreatorService.shared.createWebApp(
                name: trimmedName,
                url: selectedURL,
                urls: selectedURLs,
                profileID: profileID,
                isPrivate: isPrivate,
                iconPNGData: iconPayload,
                windowTitle: finalWindowTitle,
                destinationFolder: destinationFolder
            )
            creationState = .success(created.path)
        } catch {
            creationState = .failure("Create failed: \(error.localizedDescription)")
        }
    }

    private func selectSaveLocation(for appName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Create WebApp"
        panel.message = "Choose save location for .app"
        panel.nameFieldStringValue = "\(appName).app"
        panel.canCreateDirectories = true
        panel.allowedFileTypes = ["app"]

        if panel.runModal() == .OK, let url = panel.url {
            return url
        }
        return nil
    }

    private func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = URL(string: trimmed), direct.scheme != nil {
            return direct
        }

        return URL(string: "https://\(trimmed)")
    }

    private func normalizedURLs(from values: [String]) -> [URL] {
        values
            .map(normalizedURL(from:))
            .compactMap { $0 }
    }

    enum CreationState: Equatable {
        case idle
        case loading
        case success(String)
        case failure(String)
    }
}
