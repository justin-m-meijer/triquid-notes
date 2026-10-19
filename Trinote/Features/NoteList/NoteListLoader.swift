import Foundation
import SwiftData

/// What a note list shows: one notebook's notes or one of the sidebar's smart folders.
enum NoteListSource: Hashable, Sendable {
    case notebook(noteId: String, title: String)
    case allNotes
    case inbox
    case today
    case todo
    case favorites
    case recents

    var title: String {
        switch self {
        case .notebook(_, let title): title
        case .allNotes: String(localized: "All notes", comment: "Sidebar smart folder")
        case .inbox: String(localized: "Inbox", comment: "Sidebar smart folder")
        case .today: String(localized: "Today", comment: "Sidebar smart folder: notes edited today")
        case .todo: String(localized: "Todo", comment: "Sidebar smart folder: notes with open to-dos")
        case .favorites: String(localized: "Favorites", comment: "Main tab")
        case .recents: String(localized: "Recents", comment: "Main tab")
        }
    }

    /// Notebooks keep Trilium's own order available; smart folders are always by date.
    var supportsManualOrder: Bool {
        if case .notebook = self { return true }
        return false
    }
}

/// How a note list is ordered (the list's ⋯ menu).
enum NoteListOrder: String, CaseIterable, Identifiable, Sendable {
    case edited, title, manual

    static let storageKey = "noteListOrder"
    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .edited: String(localized: "Edited", comment: "Note list order: most recently edited first")
        case .title: String(localized: "Title", comment: "Note list order: alphabetical")
        case .manual: String(localized: "Tree order", comment: "Note list order: as in Trilium's tree")
        }
    }
}

/// One row of a note list, built off the main actor from the cache.
struct NoteListRowData: Identifiable, Hashable, Sendable {
    let noteId: String
    let title: String
    let noteType: String
    let mime: String
    let iconClass: String?
    /// Trilium's `#color` label, raw.
    let color: String?
    let isProtected: Bool
    /// The first lines of the body, as plain text.
    let preview: String
    /// The first cached image in the body.
    let thumbnail: Data?
    /// A file note's kind ("PDF"), shown as a small tile.
    let fileBadge: String?
    let modified: Date?
    let position: Int
    var id: String { noteId }
}

/// A sub-folder of a notebook, shown as a chip above its notes.
struct NoteListFolder: Identifiable, Hashable, Sendable {
    let noteId: String
    let title: String
    let iconClass: String?
    let color: String?
    let noteType: String
    let childCount: Int
    var id: String { noteId }
}

struct NoteListContent: Sendable, Equatable {
    var folders: [NoteListFolder] = []
    var rows: [NoteListRowData] = []
    /// Set when a smart folder has nothing to point at (no `#inbox` note).
    var missingSourceHint: String?
    /// The Inbox smart folder has no inbox note to show; the empty state offers to create one.
    var missingInbox = false
}

/// Counts next to the sidebar's smart folders.
struct SidebarCounts: Sendable, Equatable {
    var allNotes = 0
    var inbox = 0
    var todo = 0
    var favorites = 0
}

/// Reads note lists from the local cache on its own context, so lists work offline and long
/// notebooks do not block the main thread while previews and thumbnails are prepared.
@ModelActor
actor NoteListLoader {
    /// A loader that does its work off the main thread. A `@ModelActor` made on the main actor runs
    /// its context there, which froze the UI for seconds while the sidebar counted every note.
    static func background(_ container: ModelContainer) async -> NoteListLoader {
        await Task.detached(priority: .userInitiated) { NoteListLoader(modelContainer: container) }.value
    }

    private static let previewCharacters = 220
    private static let smartFolderLimit = 300
    private static let checkboxPattern = try! NSRegularExpression(pattern: #"<input\b[^>]*type=["']checkbox["'][^>]*>"#, options: [.caseInsensitive])

    /// A checkbox that is not ticked (Trilium writes `checked="checked"` on done items).
    nonisolated static func hasOpenCheckbox(_ html: String) -> Bool {
        let ns = html as NSString
        return checkboxPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).contains { match in
            !ns.substring(with: match.range).lowercased().contains("checked")
        }
    }

    func load(_ source: NoteListSource, profileId: String, order: NoteListOrder, inboxNoteId: String?, favoriteIds: [String], recentIds: [String]) throws -> NoteListContent {
        var content = NoteListContent()
        let notes: [CachedNote]
        switch source {
        case .notebook(let noteId, _):
            let children = try children(of: noteId, profileId: profileId)
            let iconClasses = try labelValues("iconClass", noteIds: Set(children.map(\.note.noteId)), profileId: profileId)
            let colors = try labelValues("color", noteIds: Set(children.map(\.note.noteId)), profileId: profileId)
            content.folders = children.filter { !$0.note.childBranchIds.isEmpty }.map { child in
                NoteListFolder(
                    noteId: child.note.noteId,
                    title: child.note.title,
                    iconClass: iconClasses[child.note.noteId],
                    color: colors[child.note.noteId],
                    noteType: child.note.noteType,
                    childCount: child.note.childBranchIds.count
                )
            }
            let leaves = children.filter { $0.note.childBranchIds.isEmpty }
            content.rows = try rows(for: leaves.map(\.note), positions: Dictionary(leaves.map { ($0.note.noteId, $0.position) }, uniquingKeysWith: { a, _ in a }), profileId: profileId)
            content.rows = Self.sorted(content.rows, by: order)
            return content
        case .allNotes:
            notes = try allNotes(profileId: profileId)
        case .today:
            let startOfDay = Calendar.current.startOfDay(for: .now)
            notes = try allNotes(profileId: profileId).filter { (Self.date($0.utcDateModified) ?? .distantPast) >= startOfDay }
        case .todo:
            notes = try todoNotes(profileId: profileId)
        case .inbox:
            guard let inboxNoteId else {
                content.missingSourceHint = String(localized: "Quick notes and things you share to the app collect in an inbox. Create one, or label a note #inbox in Trilium.", comment: "Inbox smart folder without an inbox note")
                content.missingInbox = true
                return content
            }
            notes = try children(of: inboxNoteId, profileId: profileId).map(\.note)
        case .favorites:
            notes = try fetchNotes(ids: favoriteIds, profileId: profileId)
        case .recents:
            notes = try fetchNotes(ids: recentIds, profileId: profileId)
        }
        let limited = Array(notes.prefix(Self.smartFolderLimit))
        content.rows = try rows(for: limited, positions: [:], profileId: profileId)
        // Recents keep the order they were opened in.
        content.rows = source == .recents ? content.rows : Self.sorted(content.rows, by: order == .manual ? .edited : order)
        return content
    }

    func counts(profileId: String, inboxNoteId: String?, favoriteCount: Int) throws -> SidebarCounts {
        var counts = SidebarCounts()
        counts.allNotes = try allNotes(profileId: profileId).count
        if let inboxNoteId {
            counts.inbox = try children(of: inboxNoteId, profileId: profileId).count
        }
        counts.todo = try todoNotes(profileId: profileId).count
        counts.favorites = favoriteCount
        return counts
    }

    /// The notebooks (top-level notes) and all their sub-notes, for the sidebar tree: every item is a
    /// note that opens in the editor, as in Trilium. One pass over the cached branches, notes and
    /// icons; the tree is built in memory.
    func notebookTree(profileId: String, rootNoteId: String = "root") throws -> [SidebarNotebook] {
        let branches = try modelContext.fetch(FetchDescriptor<CachedBranch>(
            predicate: #Predicate { $0.serverProfileId == profileId },
            sortBy: [SortDescriptor(\.notePosition)]
        ))
        let childrenByParent = Dictionary(grouping: branches, by: \.parentNoteId)
        let notes = try notesById(Set(branches.map(\.noteId)), profileId: profileId)
        let icons = try labelValues("iconClass", noteIds: Set(notes.keys), profileId: profileId)
        let colors = try labelValues("color", noteIds: Set(notes.keys), profileId: profileId)

        func folders(of noteId: String, depth: Int, visited: Set<String>) -> [SidebarNotebook] {
            guard depth < 16 else { return [] }
            return (childrenByParent[noteId] ?? []).compactMap { branch -> SidebarNotebook? in
                guard let note = notes[branch.noteId], !visited.contains(note.noteId) else { return nil }
                return node(note, depth: depth, visited: visited)
            }
        }
        func node(_ note: CachedNote, depth: Int, visited: Set<String>) -> SidebarNotebook {
            SidebarNotebook(
                noteId: note.noteId,
                title: note.title,
                iconClass: icons[note.noteId],
                color: colors[note.noteId],
                noteType: note.noteType,
                childCount: (childrenByParent[note.noteId] ?? []).count,
                folders: folders(of: note.noteId, depth: depth + 1, visited: visited.union([note.noteId]))
            )
        }
        return (childrenByParent[rootNoteId] ?? []).compactMap { branch in
            guard let note = notes[branch.noteId], !note.noteId.hasPrefix("_") else { return nil }
            return node(note, depth: 0, visited: [rootNoteId])
        }
    }

    // MARK: - Queries

    private struct Child {
        let note: CachedNote
        let position: Int
    }

    private func children(of parentId: String, profileId: String) throws -> [Child] {
        let branches = try modelContext.fetch(FetchDescriptor<CachedBranch>(
            predicate: #Predicate { $0.parentNoteId == parentId && $0.serverProfileId == profileId },
            sortBy: [SortDescriptor(\.notePosition)]
        ))
        let byId = try notesById(Set(branches.map(\.noteId)), profileId: profileId)
        return branches.compactMap { branch in
            byId[branch.noteId].map { Child(note: $0, position: branch.notePosition) }
        }
    }

    private func notesById(_ ids: Set<String>, profileId: String) throws -> [String: CachedNote] {
        guard !ids.isEmpty else { return [:] }
        let notes = try modelContext.fetch(FetchDescriptor<CachedNote>(
            predicate: #Predicate { $0.serverProfileId == profileId && ids.contains($0.noteId) }
        ))
        return Dictionary(notes.map { ($0.noteId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func fetchNotes(ids: [String], profileId: String) throws -> [CachedNote] {
        let byId = try notesById(Set(ids), profileId: profileId)
        return ids.compactMap { byId[$0] }
    }

    /// Every note a person wrote: Trilium's own (`_…`) and the root are left out.
    private func allNotes(profileId: String) throws -> [CachedNote] {
        try modelContext.fetch(FetchDescriptor<CachedNote>(predicate: #Predicate { $0.serverProfileId == profileId }))
            .filter { !$0.noteId.hasPrefix("_") && $0.noteId != "root" }
            .sorted { (Self.date($0.utcDateModified) ?? .distantPast) > (Self.date($1.utcDateModified) ?? .distantPast) }
    }

    /// `#todo`, or a text note with a checkbox still open. Protected bodies are not looked into.
    private func todoNotes(profileId: String) throws -> [CachedNote] {
        let labelled = Set(try modelContext.fetch(FetchDescriptor<CachedAttribute>(
            predicate: #Predicate { $0.serverProfileId == profileId && $0.type == "label" && $0.name == "todo" }
        )).map(\.noteId))
        return try allNotes(profileId: profileId).filter { note in
            if labelled.contains(note.noteId) { return true }
            guard note.noteType == "text", !note.isProtected, let data = note.content,
                  let html = String(data: data, encoding: .utf8), html.contains("checkbox")
            else { return false }
            return Self.hasOpenCheckbox(html)
        }
    }

    private func labelValues(_ name: String, noteIds: Set<String>, profileId: String) throws -> [String: String] {
        guard !noteIds.isEmpty else { return [:] }
        let attributes = try modelContext.fetch(FetchDescriptor<CachedAttribute>(
            predicate: #Predicate { $0.serverProfileId == profileId && $0.type == "label" && $0.name == name }
        ))
        var result: [String: String] = [:]
        for attribute in attributes where noteIds.contains(attribute.noteId) {
            result[attribute.noteId] = attribute.value
        }
        return result
    }

    // MARK: - Rows

    private func rows(for notes: [CachedNote], positions: [String: Int], profileId: String) throws -> [NoteListRowData] {
        let iconClasses = try labelValues("iconClass", noteIds: Set(notes.map(\.noteId)), profileId: profileId)
        let colors = try labelValues("color", noteIds: Set(notes.map(\.noteId)), profileId: profileId)
        return notes.map { note in
            let html = note.content.flatMap { String(data: $0, encoding: .utf8) }
            return NoteListRowData(
                noteId: note.noteId,
                title: note.title,
                noteType: note.noteType,
                mime: note.mime,
                iconClass: iconClasses[note.noteId],
                color: colors[note.noteId],
                isProtected: note.isProtected,
                preview: note.isProtected ? "" : Self.preview(noteType: note.noteType, body: html),
                thumbnail: note.isProtected ? nil : html.flatMap { thumbnail(in: $0, profileId: profileId) },
                fileBadge: Self.fileBadge(noteType: note.noteType, mime: note.mime),
                modified: Self.date(note.utcDateModified),
                position: positions[note.noteId] ?? 0
            )
        }
    }

    private func thumbnail(in html: String, profileId: String) -> Data? {
        guard html.contains("api/images/") || html.contains("api/attachments/") else { return nil }
        for reference in Self.imageReferences(in: html) {
            let id = "\(profileId):\(reference.route):\(reference.entityId)"
            var descriptor = FetchDescriptor<CachedImageData>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let image = try? modelContext.fetch(descriptor).first, image.mime.hasPrefix("image/") {
                return image.data
            }
        }
        return nil
    }

    private static let imagePattern = try! NSRegularExpression(pattern: #"api/(attachments|images)/([a-zA-Z0-9_-]+)"#)

    nonisolated static func imageReferences(in html: String) -> [(route: String, entityId: String)] {
        let ns = html as NSString
        return imagePattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(4).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    nonisolated static func preview(noteType: String, body: String?) -> String {
        guard let body, !body.isEmpty else { return "" }
        let text: String
        switch noteType {
        case "text": text = NotePlainText.fromHTML(body)
        case "code", "markdown": text = body
        default: return ""
        }
        let collapsed = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return String(collapsed.prefix(previewCharacters))
    }

    nonisolated static func fileBadge(noteType: String, mime: String) -> String? {
        guard noteType == "file" else { return nil }
        if mime == "application/pdf" { return "PDF" }
        return mime.split(separator: "/").last.map { String($0.prefix(4)).uppercased() }
    }

    nonisolated static func sorted(_ rows: [NoteListRowData], by order: NoteListOrder) -> [NoteListRowData] {
        switch order {
        case .edited: rows.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case .title: rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .manual: rows.sorted { $0.position < $1.position }
        }
    }

    nonisolated static func date(_ value: String?) -> Date? {
        value.flatMap(SpotlightIndexer.parseTriliumDate)
    }
}

/// A notebook in the sidebar tree, with its sub-folders.
struct SidebarNotebook: Identifiable, Hashable, Sendable {
    let noteId: String
    let title: String
    let iconClass: String?
    let color: String?
    let noteType: String
    let childCount: Int
    let folders: [SidebarNotebook]
    var id: String { noteId }
}

/// "Just now", "14:05", "Yesterday", "Sep 30" or "Sep 30, 2025", as Notes shows dates in a list.
enum NoteListDate {
    static func string(for date: Date?, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        if now.timeIntervalSince(date) < 120 {
            return String(localized: "Just now", comment: "Note list date: edited in the last two minutes")
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday", comment: "Note list date")
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
