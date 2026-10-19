import SwiftUI

/// Shown once per server after its first sync when it has no inbox yet: says what the inbox is for and
/// offers to create one, so quick notes and shared things land in one place the sidebar shows.
struct InboxSetupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.tint)
                Text(String(localized: "Where quick notes go", comment: "Inbox setup sheet title"))
                    .font(.title2.bold())
                Text(String(
                    localized: "Quick notes, scans and things you share to Triquid Notes collect in an inbox, so you can sort them later. Inbox in the menu shows what is in it.",
                    comment: "Inbox setup sheet: what the inbox is"
                ))
                Text(String(
                    localized: "This server has no inbox yet. Create one and it appears at the top of your notes as Inbox, labeled #inbox, so Trilium on your computer uses it too.",
                    comment: "Inbox setup sheet: what creating does"
                ))
                .foregroundStyle(.secondary)
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
                Spacer(minLength: 0)
                Button {
                    do {
                        try InboxNote.create(appState: appState)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                } label: {
                    Text(String(localized: "Create an Inbox", comment: "Empty Inbox: makes an Inbox note labeled #inbox"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    dismiss()
                } label: {
                    Text(String(localized: "Not Now", comment: "Inbox setup sheet: skip"))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(24)
        }
        .presentationDetents([.medium, .large])
    }

    /// Whether to offer the sheet now: once per server, after its first full sync, and only without an inbox.
    @MainActor
    static func shouldOffer(appState: AppState) -> Bool {
        guard let profile = appState.activeProfile, !profile.isLocal,
              appState.syncManager.hasCompletedFullSync,
              appState.syncManager.pendingFirstSync == nil else { return false }
        let key = "inboxSetupOffered." + profile.id
        guard !UserDefaults.standard.bool(forKey: key) else { return false }
        UserDefaults.standard.set(true, forKey: key)
        return InboxNote.find(profileId: profile.id) == nil
    }
}
