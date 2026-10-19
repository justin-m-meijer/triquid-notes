import Foundation

/// The one rule for "which note is the inbox", shared by the sidebar's Inbox, sharing, Quick capture and
/// Favorites, so a captured note always lands where the Inbox shows it:
///
/// 1. the note labeled `#inbox` (Trilium's own inbox, and what Trilium on the desktop uses);
/// 2. else a top-level note named like "Inbox", such as "Inbox" or "00-Inbox", which many people keep without the label.
///
/// When neither exists there is no inbox note; capture then falls back to today's journal note or the top of the
/// tree (`InboxDestination`), and the app offers to create one (`create`).
@MainActor
enum InboxNote {
    /// The inbox note from the synced notes, or nil.
    static func find(profileId: String, persistence: PersistenceManager = .shared) -> NoteIdTitle? {
        for id in persistence.cachedNoteIds(withLabel: "inbox", serverProfileId: profileId) {
            if let note = try? persistence.fetchCachedNote(id: id, serverProfileId: profileId) {
                return NoteIdTitle(noteId: note.noteId, title: note.title, isProtected: note.isProtected)
            }
        }
        let topLevel = (try? persistence.fetchCachedChildren(parentNoteId: TriliumTreeConstants.rootNoteId, serverProfileId: profileId)) ?? []
        let named = topLevel.map(\.1).filter { $0.title.localizedCaseInsensitiveContains("inbox") }
        guard let best = named.first(where: { $0.title.caseInsensitiveCompare("inbox") == .orderedSame }) ?? named.first else {
            return nil
        }
        return NoteIdTitle(noteId: best.noteId, title: best.title, isProtected: best.isProtected)
    }

    /// The title a new inbox note gets.
    static var defaultTitle: String { String(localized: "Inbox", comment: "Title of the inbox note the app creates") }

    /// Makes an "Inbox" note at the top of the tree, labeled `#inbox` so Trilium on the desktop uses it too.
    /// Works offline and in a notebook on this device; it uploads with the next sync. Returns the existing inbox
    /// instead when there already is one.
    @discardableResult
    static func create(appState: AppState, persistence: PersistenceManager = .shared) throws -> NoteIdTitle {
        guard let profileId = appState.activeProfile?.id else { throw InboxNoteError.noProfile }
        if let existing = find(profileId: profileId, persistence: persistence) { return existing }
        let created = try persistence.createOfflineChildNote(
            parentNoteId: TriliumTreeConstants.rootNoteId,
            title: defaultTitle,
            noteType: NoteType.text.triliumStorageType,
            mime: NoteType.text.creationMime,
            initialContent: "",
            serverProfileId: profileId,
            initialAttributes: [NoteCreationAttribute(type: "label", name: "inbox", value: "")]
        )
        appState.backgroundSyncPendingChanges()
        NotificationCenter.default.post(name: .trinoteTreeShouldRefresh, object: nil)
        return NoteIdTitle(noteId: created.noteId, title: defaultTitle, isProtected: false)
    }
}

enum InboxNoteError: LocalizedError {
    case noProfile
    var errorDescription: String? {
        String(localized: "Connect a server or start a notebook on this device first.", comment: "Creating the inbox without a notebook")
    }
}
