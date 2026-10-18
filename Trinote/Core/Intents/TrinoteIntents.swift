import AppIntents
import Foundation
import SwiftData

/// Requests from outside the window — App Intents (Siri, Shortcuts, the Action button, Control
/// Center), home-screen quick actions — waiting for `MainShellView` to carry them out.
@MainActor
@Observable
final class QuickActionRouter {
    enum Action: Equatable {
        case newNote
        case scanDocument
    }

    static let shared = QuickActionRouter()

    /// Each request is distinct, so asking twice in a row still triggers twice.
    struct Request: Equatable {
        let id = UUID()
        let action: Action
    }

    var pending: Request?
    /// A note picked in Shortcuts; delivered the same way as a `triquidnotes://` link.
    var pendingNote: NoteLink?

    func request(_ action: Action) {
        pending = Request(action: action)
    }
}

// MARK: - Intents

struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Opens Quick capture to write a new note.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.shared.request(.newNote)
        return .result()
    }
}

struct ScanDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan Document"
    static let description = IntentDescription("Scans pages into a new note with a searchable PDF and the recognized text.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.shared.request(.scanDocument)
        return .result()
    }
}

struct OpenNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Note"
    static let description = IntentDescription("Opens a note from the signed-in server.")
    static let openAppWhenRun = true

    @Parameter(title: "Note")
    var note: NoteEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let target = SpotlightIndexer.parse(identifier: note.id) else { return .result() }
        QuickActionRouter.shared.pendingNote = NoteLink(noteId: target.noteId)
        return .result()
    }
}

// MARK: - Note entity

/// A cached note, identified as `profileId/noteId` (the Spotlight identifier).
struct NoteEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Note"
    static let defaultQuery = NoteEntityQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct NoteEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [NoteEntity] {
        try await PersistenceManager.initializeShared()
        return identifiers.compactMap { identifier in
            guard let target = SpotlightIndexer.parse(identifier: identifier),
                  let note = try? PersistenceManager.shared.fetchCachedNote(id: target.noteId, serverProfileId: target.profileId)
            else { return nil }
            return NoteEntity(id: identifier, title: note.title)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [NoteEntity] {
        try await PersistenceManager.initializeShared()
        guard let profileId = Self.activeProfileId() else { return [] }
        let hits = try await OfflineSearchIndex.shared.search(LocalSearchQuery(string), profileId: profileId, limit: 30).hits
        return hits.filter { !$0.isProtected }.map {
            NoteEntity(id: SpotlightIndexer.identifier(profileId: profileId, noteId: $0.noteId), title: $0.title)
        }
    }

    /// Recently opened notes, for the picker before anything is typed.
    @MainActor
    func suggestedEntities() async throws -> [NoteEntity] {
        try await PersistenceManager.initializeShared()
        guard let profileId = Self.activeProfileId() else { return [] }
        var descriptor = FetchDescriptor<RecentNote>(
            predicate: #Predicate { $0.serverProfileId == profileId },
            sortBy: [SortDescriptor(\.accessedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 15
        let recents = (try? PersistenceManager.shared.context.fetch(descriptor)) ?? []
        return recents.map { NoteEntity(id: SpotlightIndexer.identifier(profileId: profileId, noteId: $0.noteId), title: $0.title) }
    }

    /// The signed-in server; intents can run before the window (and `AppState`) exists.
    @MainActor
    private static func activeProfileId() -> String? {
        (try? PersistenceManager.shared.fetchServerProfiles())?.first(where: \.isActive)?.id
    }
}

// MARK: - Shortcuts

struct TrinoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewNoteIntent(),
            phrases: ["New note in \(.applicationName)", "Write a note in \(.applicationName)"],
            shortTitle: "New Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: ScanDocumentIntent(),
            phrases: ["Scan a document with \(.applicationName)", "Scan into \(.applicationName)"],
            shortTitle: "Scan Document",
            systemImageName: "doc.viewfinder"
        )
        AppShortcut(
            intent: OpenNoteIntent(),
            phrases: ["Open \(\.$note) in \(.applicationName)", "Open a note in \(.applicationName)"],
            shortTitle: "Open Note",
            systemImageName: "doc.text"
        )
    }
}
