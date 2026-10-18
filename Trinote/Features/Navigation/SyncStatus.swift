import SwiftUI

struct SyncNowButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button(String(localized: "Sync now", comment: "Sync bar button")) {
            Task { await SyncStatusSummary.syncNow(appState: appState) }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.tint)
        .buttonStyle(.borderless)
        .disabled(!SyncStatusSummary(appState: appState).canSyncNow)
    }
}

/// Sync state as the tree sync button and its details show it. ETAPI-free: this reads the app's own sync.
@MainActor
struct SyncStatusSummary {
    let appState: AppState

    private var sync: SyncManager { appState.syncManager }

    var lastSyncDate: Date? {
        [sync.lastIncrementalSyncDate, sync.lastFullSyncDate].compactMap { $0 }.max()
    }

    /// Syncing can be retried after a failure even while the manager still reports its last state.
    var canSyncNow: Bool {
        guard appState.isOnline else { return false }
        return !sync.isSyncing || sync.syncError != nil || appState.connectionError != nil
    }

    var dotColor: Color {
        if !appState.isOnline { return .trinoteTextTertiary }
        if sync.syncError != nil || appState.connectionError != nil { return .trinoteDestructive }
        if sync.isSyncing { return .orange }
        return .trinoteSyncOK
    }

    var summary: String {
        if !appState.isOnline {
            return String(localized: "Offline", comment: "Sync bar: no network")
        }
        if sync.syncError != nil || appState.connectionError != nil {
            return String(localized: "Sync failed", comment: "Sync bar: last sync failed")
        }
        if sync.isSyncing {
            return String(localized: "Syncing…", comment: "Sync bar: sync in progress")
        }
        guard let lastSyncDate else {
            return String(localized: "Not synced yet", comment: "Sync bar: never synced")
        }
        // The sync time can be a moment ahead of this clock; under a minute reads as "just now".
        guard Date.now.timeIntervalSince(lastSyncDate) >= 60 else {
            return String(localized: "Synced · just now", comment: "Sync bar: synced less than a minute ago")
        }
        let ago = lastSyncDate.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        return String(localized: "Synced · \(ago)", comment: "Sync bar: last successful sync; argument is a relative time like '2 min ago'")
    }

    /// Same as pull-to-refresh on the tree: sync, then let the tree reload from the server.
    static func syncNow(appState: AppState) async {
        await appState.refreshSessionThenIncrementalSync(maxWaitSeconds: 120, downloadChangedBodies: false)
        NotificationCenter.default.post(
            name: .trinoteTreeShouldRefresh,
            object: nil,
            userInfo: [Notification.Name.trinoteTreeReloadFromServerUserInfoKey: true]
        )
    }
}

/// Sync details: when the last syncs ran, what is happening now, and any error.
struct SyncDetailsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let status = SyncStatusSummary(appState: appState)
        let sync = appState.syncManager
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Circle().fill(status.dotColor).frame(width: 10, height: 10)
                        Text(status.summary).font(.headline)
                    }
                    if sync.isSyncing, sync.totalNoteCount > 0 {
                        ProgressView(value: sync.syncProgress) {
                            Text(String(localized: "\(sync.syncedNoteCount) of \(sync.totalNoteCount) notes", comment: "Sync details: progress"))
                                .font(.footnote)
                        }
                    }
                }
                Section {
                    LabeledContent(String(localized: "Server", comment: "Sync details row")) {
                        Text(appState.activeProfile.flatMap { URL(string: $0.baseURL)?.host() } ?? "–")
                    }
                    LabeledContent(String(localized: "Last sync", comment: "Sync details row")) {
                        dateText(sync.lastIncrementalSyncDate)
                    }
                    LabeledContent(String(localized: "Last full sync", comment: "Sync details row")) {
                        dateText(sync.lastFullSyncDate)
                    }
                    LabeledContent(String(localized: "Network", comment: "Sync details row")) {
                        Text(appState.isOnline
                             ? String(localized: "Online", comment: "Sync details: network state")
                             : String(localized: "Offline", comment: "Sync bar: no network"))
                    }
                }
                if let error = sync.syncError ?? appState.connectionError {
                    Section(String(localized: "Error", comment: "Sync details section")) {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(Color.trinoteDestructive)
                            .textSelection(.enabled)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.trinoteGround)
            .navigationTitle(String(localized: "Sync", comment: "Sync details title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Dismiss sheet")) { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    SyncNowButton()
                }
            }
        }
    }

    @ViewBuilder
    private func dateText(_ date: Date?) -> some View {
        if let date {
            Text(date, format: .dateTime.day().month().hour().minute())
        } else {
            Text(verbatim: "–")
        }
    }
}
