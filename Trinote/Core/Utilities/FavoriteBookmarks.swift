import Foundation

/// Favorites are Trilium's `#bookmarked` label (redesign §3). Changing one writes the label on the
/// server; the local favorites list follows through `PersistenceManager`'s mirror.
@MainActor
enum FavoriteBookmarks {
    enum BookmarkError: LocalizedError {
        case offline

        var errorDescription: String? {
            String(localized: "Favorites are stored in Trilium. Connect to the server to change them.", comment: "Favorite toggle while offline")
        }
    }

    /// Adds or removes `#bookmarked` on the note, then updates the cache and the favorites list.
    static func setFavorite(
        _ isFavorite: Bool,
        noteId: String,
        title: String,
        noteType: String,
        appState: AppState
    ) async throws {
        guard appState.isOnline, let client = appState.client, let profileId = appState.activeProfile?.id else {
            throw BookmarkError.offline
        }
        let bookmarkName = PersistenceManager.bookmarkLabelName
        let current = try await client.getNote(noteId).attributes.filter { $0.type == "label" && $0.name == bookmarkName }

        var added: AttributeResponse?
        var removedIds: [String] = []
        if isFavorite {
            if let existing = current.first {
                added = existing
            } else {
                try await client.createAttribute(CreateAttributeRequest(
                    noteId: noteId, type: "label", name: bookmarkName, value: "", isInheritable: false, position: nil
                ))
                // The create response is not reliably decodable; read the new attribute back.
                added = try await client.getNote(noteId).attributes.first { $0.type == "label" && $0.name == bookmarkName }
            }
        } else {
            for attribute in current {
                try await client.deleteAttribute(noteId: noteId, attributeId: attribute.attributeId)
                removedIds.append(attribute.attributeId)
            }
        }

        try PersistenceManager.shared.applyBookmarkChange(
            added: added,
            removedAttributeIds: removedIds,
            noteId: noteId,
            title: title,
            noteType: noteType,
            serverProfileId: profileId
        )
        // The tree shows labels; let it pick up the change.
        NotificationCenter.default.post(name: .trinoteTreeShouldRefresh, object: nil, userInfo: ["noteId": noteId])
    }

    /// Once per profile: favorites made on this device before they became `#bookmarked` get the label,
    /// so they survive and show up everywhere. Retries on a later launch if it cannot finish.
    static func migrateLocalFavoritesIfNeeded(appState: AppState) async {
        guard appState.isOnline, let profileId = appState.activeProfile?.id else { return }
        let pm = PersistenceManager.shared
        guard !pm.favoritesAreMigratedToBookmarks(serverProfileId: profileId) else { return }
        guard let local = try? pm.fetchFavorites(serverProfileId: profileId) else { return }
        let bookmarked = (try? pm.bookmarkedNoteIds(serverProfileId: profileId)) ?? []
        let pending = local.filter { !bookmarked.contains($0.noteId) }.map { ($0.noteId, $0.title, $0.noteType) }
        for (noteId, title, noteType) in pending {
            do {
                try await setFavorite(true, noteId: noteId, title: title, noteType: noteType, appState: appState)
            } catch {
                Log.persistence.error("Favorite migration to #bookmarked failed for \(noteId, privacy: .public): \(error)")
                return
            }
        }
        pm.markFavoritesMigratedToBookmarks(serverProfileId: profileId)
    }
}
