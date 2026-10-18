import Foundation

/// A request to open one note, from a `triquidnotes://note/<noteId>` URL, a Spotlight result or an
/// App Intent. Each request is distinct, so opening the same note twice opens it twice.
struct NoteLink: Equatable, Sendable {
    static let scheme = "triquidnotes"

    let id = UUID()
    let noteId: String
    var startInEditMode = false

    init(noteId: String, startInEditMode: Bool = false) {
        self.noteId = noteId
        self.startInEditMode = startInEditMode
    }

    /// `triquidnotes://note/<noteId>`, optionally with `?edit=1`.
    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host() == "note" else { return nil }
        let noteId = url.pathComponents.dropFirst().first ?? ""
        guard !noteId.isEmpty, noteId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        let edit = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "edit" }?.value == "1"
        self.init(noteId: noteId, startInEditMode: edit)
    }

    static func url(for noteId: String) -> URL? {
        URL(string: "\(scheme)://note/\(noteId)")
    }
}
