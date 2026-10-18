import SwiftUI

/// A note picked for moving from a long-press menu (sidebar, lists, sub-notes under a note).
struct NoteMoveRequest: Identifiable {
    let noteId: String
    let title: String
    var id: String { noteId }
}

extension View {
    /// The move flow the tree uses, for any long-press menu: pick the new parent, confirm, move.
    /// Works offline too (the move is queued). `onMoved` runs after a move so the caller can reload.
    func noteMoveFlow(_ request: Binding<NoteMoveRequest?>, onMoved: @escaping () -> Void = {}) -> some View {
        modifier(NoteMoveFlow(request: request, onMoved: onMoved))
    }
}

private struct NoteMoveFlow: ViewModifier {
    @Binding var request: NoteMoveRequest?
    let onMoved: () -> Void

    @Environment(AppState.self) private var appState
    @State private var pending: PendingMove?
    @State private var error: String?

    private struct PendingMove {
        let noteId: String
        let title: String
        let targetParentNoteId: String
        let targetTitle: String
        let targetParentBranchId: String
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $request) { move in
                ParentPickerSheet(
                    navigationTitle: String(localized: "Move to…", comment: "Sheet title: pick parent for move"),
                    instruction: String(
                        localized: "Choose where to move the note. Open folders, then tap a note to select it as the new parent.",
                        comment: "Instructions for move-note parent picker"
                    ),
                    topLevelButtonTitle: String(localized: "Top level (under Notes)", comment: "Move note under root"),
                    onPick: { parentNoteId, title, parentBranchId in
                        request = nil
                        guard parentNoteId != move.noteId else {
                            error = String(localized: "A note cannot be moved under itself.", comment: "Move validation")
                            return
                        }
                        pending = PendingMove(
                            noteId: move.noteId,
                            title: move.title,
                            targetParentNoteId: parentNoteId,
                            targetTitle: title,
                            targetParentBranchId: parentBranchId
                        )
                    }
                )
                .environment(appState)
            }
            .alert(
                String(localized: "Move", comment: "Confirm move note"),
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                presenting: pending
            ) { move in
                Button(String(localized: "Cancel", comment: "Cancel move"), role: .cancel) {}
                Button(String(localized: "Move", comment: "Confirm move note")) {
                    Task { await perform(move) }
                }
            } message: { move in
                Text(String(
                    localized: "Move “\(move.title)” under “\(move.targetTitle)”? The note will appear in the new location in the tree.",
                    comment: "Move confirmation: source and destination titles"
                ))
            }
            .alert(
                String(localized: "Error", comment: "Generic error title"),
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
                actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
                message: { Text(error ?? "") }
            )
    }

    private func perform(_ move: PendingMove) async {
        do {
            try await NoteMover.move(noteId: move.noteId, toParent: move.targetParentNoteId, parentBranchId: move.targetParentBranchId, appState: appState)
            onMoved()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Moves a note under another parent: online through the server, offline queued for the next sync
/// (as the tree does). Used by the move sheet and by dragging in the sidebar.
@MainActor
enum NoteMover {
    struct MoveError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Moves the note's branch under its current (first) parent.
    static func move(noteId: String, toParent targetParentNoteId: String, parentBranchId targetParentBranchId: String, appState: AppState) async throws {
        guard let profileId = appState.activeProfile?.id else { return }
        let persistence = PersistenceManager.shared
        guard noteId != TriliumTreeConstants.rootNoteId else {
            throw MoveError(message: String(localized: "The root notebook cannot be moved.", comment: "Move root note blocked"))
        }
        guard noteId != targetParentNoteId else {
            throw MoveError(message: String(localized: "A note cannot be moved under itself.", comment: "Move validation"))
        }
        let missing = String(localized: "Could not resolve the note’s branch in the local cache.", comment: "Move branch missing offline")
        guard let note = try? persistence.fetchCachedNote(id: noteId, serverProfileId: profileId) else {
            throw MoveError(message: missing)
        }
        let oldParentNoteId = note.parentNoteIds.first ?? TriliumTreeConstants.rootNoteId
        guard oldParentNoteId != targetParentNoteId else { return }
        guard let branch = try? persistence.fetchCachedBranch(noteId: noteId, parentNoteId: oldParentNoteId, serverProfileId: profileId) else {
            throw MoveError(message: missing)
        }
        do {
            if appState.isOnline, let client = appState.client {
                try await client.moveBranchToParent(branchId: branch.branchId, parentBranchId: targetParentBranchId)
            } else {
                try persistence.applyOptimisticBranchMove(
                    sourceBranchId: branch.branchId,
                    sourceNoteId: noteId,
                    targetParentNoteId: targetParentNoteId,
                    serverProfileId: profileId
                )
                try persistence.enqueuePendingBranchMove(
                    sourceBranchId: branch.branchId,
                    targetParentBranchId: targetParentBranchId,
                    sourceNoteId: noteId,
                    oldParentNoteId: oldParentNoteId,
                    targetParentNoteId: targetParentNoteId,
                    serverProfileId: profileId
                )
            }
        } catch {
            throw MoveError(message: APIError.from(error).localizedDescription)
        }
        NotificationCenter.default.post(name: .trinoteTreeShouldRefresh, object: nil, userInfo: ["noteId": noteId])
    }

    /// A branch of `noteId` to move notes under (Trilium moves to a parent *branch*).
    static func branchId(of noteId: String, appState: AppState) -> String? {
        guard let profileId = appState.activeProfile?.id else { return nil }
        if noteId == TriliumTreeConstants.rootNoteId { return TriliumTreeConstants.rootBranchId }
        let persistence = PersistenceManager.shared
        guard let note = try? persistence.fetchCachedNote(id: noteId, serverProfileId: profileId) else { return nil }
        let parent = note.parentNoteIds.first ?? TriliumTreeConstants.rootNoteId
        return (try? persistence.fetchCachedBranch(noteId: noteId, parentNoteId: parent, serverProfileId: profileId))?.branchId
    }
}
