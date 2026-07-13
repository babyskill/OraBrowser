import CloudKit
import SwiftUI

private let lastSyncDateKey = "settings.icloudSyncLastSyncedAt"

struct SyncSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    @State private var accountStatus: CKAccountStatus = .couldNotDetermine
    @State private var isCheckingAccount = false
    @State private var isSyncing = false
    @State private var syncErrorMessage: String?
    @State private var lastSyncDate: Date? = UserDefaults.standard.object(
        forKey: lastSyncDateKey
    ) as? Date

    var body: some View {
        SettingsSection {
            SettingsCard(header: "iCloud Sync") {
                Toggle("Sync with iCloud", isOn: $settings.iCloudSyncEnabled)
            }

            SettingsCard(header: "Synchronized Data") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("• Tabs")
                    Text("• Spaces / Containers")
                    Text("• Folders")
                    Text("• Settings")
                }
                .font(.body)
                .foregroundStyle(.primary)
            }

            SettingsCard(header: "Sync Status") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Connection")
                            .font(.headline)
                        Spacer()
                        HStack(spacing: 6) {
                            if isCheckingAccount {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            }

                            Text(connectionStatus)
                                .foregroundStyle(connectionStatusColor)
                        }
                        .font(.subheadline)
                    }

                    Text(lastSyncLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let syncErrorMessage {
                        Text(syncErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Spacer()
                        Button {
                            syncNow()
                        } label: {
                            HStack {
                                if isSyncing {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 12, height: 12)
                                }
                                Text("Sync Now")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSyncNow || isSyncing)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .task {
            await refreshAccountStatus()
        }
        .onAppear {
            refreshAccountDate()
        }
        .onChange(of: settings.iCloudSyncEnabled) { _, _ in
            Task {
                await refreshAccountStatus()
            }
        }
    }

    private var canSyncNow: Bool {
        settings.iCloudSyncEnabled && accountStatus == .available
    }

    private var connectionStatus: String {
        if !settings.iCloudSyncEnabled {
            return "iCloud sync is disabled"
        }

        switch accountStatus {
        case .available:
            return "Connected"
        case .noAccount:
            return "iCloud Account required"
        case .restricted:
            return "iCloud access restricted"
        case .temporarilyUnavailable:
            return "iCloud temporarily unavailable"
        case .couldNotDetermine:
            return "Checking account status"
        @unknown default:
            return "iCloud status unknown"
        }
    }

    private var connectionStatusColor: Color {
        if !settings.iCloudSyncEnabled {
            return .secondary
        }

        switch accountStatus {
        case .available:
            return .green
        case .couldNotDetermine:
            return .secondary
        default:
            return .orange
        }
    }

    private var lastSyncLabel: String {
        if let lastSyncDate {
            return "Last synced: \(lastSyncDate.formatted(date: .abbreviated, time: .shortened))"
        }

        return "Last synced: Never"
    }

    private func refreshAccountDate() {
        lastSyncDate = UserDefaults.standard.object(forKey: lastSyncDateKey) as? Date
    }

    private func syncNow() {
        guard canSyncNow else { return }

        isSyncing = true
        syncErrorMessage = nil

        ICloudSettingsSyncService.shared.start()
        NSUbiquitousKeyValueStore.default.synchronize()

        let now = Date()
        UserDefaults.standard.set(now, forKey: lastSyncDateKey)

        lastSyncDate = now
        isSyncing = false
    }

    private func refreshAccountStatus() async {
        isCheckingAccount = true
        syncErrorMessage = nil

        do {
            let status = try await CKContainer.default().accountStatus()
            accountStatus = status
        } catch {
            accountStatus = .couldNotDetermine
            syncErrorMessage = error.localizedDescription
        }

        isCheckingAccount = false
    }
}
