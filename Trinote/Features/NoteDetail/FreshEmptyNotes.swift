import Foundation

/// Notes created empty only to be written in straight away: Quick capture's "Open in full
/// editor" with nothing typed, or "New note" in a list. Left with Don't Save, such a note is
/// deleted again instead of staying behind empty (TestFlight feedback). The mark is taken once,
/// by the editor it was created for, so a later edit of the same note never deletes it.
@MainActor
enum FreshEmptyNotes {
    private static var noteIds: Set<String> = []

    static func register(_ noteId: String) {
        noteIds.insert(noteId)
    }

    /// Whether `noteId` was created empty for this editor; clears the mark.
    static func take(_ noteId: String) -> Bool {
        noteIds.remove(noteId) != nil
    }
}
