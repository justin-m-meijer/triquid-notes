import SwiftUI

/// A screen pushed onto a note-browsing stack (Notes, Favorites, Search, Recents, and the tree pickers).
enum NoteRoute: Hashable {
    /// A nested tree (drill-down past `TriliumTreeConstants.maxInlineDepth`); `level` is the nested tree's own level.
    case subtree(noteId: String, title: String, level: Int)
    case note(NoteDestination)

    var noteDestination: NoteDestination? {
        if case .note(let destination) = self { return destination }
        return nil
    }

    var isSubtree: Bool {
        if case .subtree = self { return true }
        return false
    }
}

/// Everything `NoteDetailView` needs to open a note from a list.
struct NoteDestination: Hashable {
    /// Identifies this push: opening the same note twice gives two routes.
    let routeId = UUID()
    let noteId: String
    let title: String
    /// When set, the detail is scoped to a specific `OpenNoteTab` row.
    var openTabId: String? = nil
    var startInEditMode: Bool = false
    var attachmentIdToInsert: String? = nil
    var attachmentTitleToInsert: String? = nil
    var findQuery: String? = nil
    var findMatchIndex1Based: Int? = nil
    /// Tree children known at push time, so the detail can render its child list before loading.
    /// Not part of the route's identity.
    var seedChildSummaries: [ChildNoteSummary]? = nil

    static func == (lhs: NoteDestination, rhs: NoteDestination) -> Bool {
        lhs.routeId == rhs.routeId
            && lhs.noteId == rhs.noteId
            && lhs.title == rhs.title
            && lhs.openTabId == rhs.openTabId
            && lhs.startInEditMode == rhs.startInEditMode
            && lhs.attachmentIdToInsert == rhs.attachmentIdToInsert
            && lhs.attachmentTitleToInsert == rhs.attachmentTitleToInsert
            && lhs.findQuery == rhs.findQuery
            && lhs.findMatchIndex1Based == rhs.findMatchIndex1Based
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(routeId)
        hasher.combine(noteId)
        hasher.combine(title)
        hasher.combine(openTabId)
        hasher.combine(startInEditMode)
        hasher.combine(attachmentIdToInsert)
        hasher.combine(attachmentTitleToInsert)
        hasher.combine(findQuery)
        hasher.combine(findMatchIndex1Based)
    }

    /// Keyed by `routeId`: when a stack replaces its top route in one update (a link opened over
    /// the restored note), SwiftUI would otherwise keep the old view and its state, and the new
    /// note would never load.
    @MainActor
    func makeDetailView() -> some View {
        NoteDetailView(
            noteId: noteId,
            title: title,
            routeId: routeId,
            seedChildSummaries: seedChildSummaries,
            startInEditMode: startInEditMode,
            pendingFindQuery: findQuery,
            pendingFindMatchIndex: findMatchIndex1Based,
            openTabId: openTabId,
            attachmentIdToInsert: attachmentIdToInsert,
            attachmentTitleToInsert: attachmentTitleToInsert
        )
        .id(routeId)
    }
}

/// The navigation path of one note-browsing stack. Views push by editing `path` instead of holding
/// their own `navigationDestination(item:)` state, so the stack's contents live outside any one view.
@MainActor
@Observable
final class NoteStack {
    var path: [NoteRoute] = [] {
        didSet {
            let live = Set(path.compactMap { $0.noteDestination?.routeId })
            shownNotes = shownNotes.filter { live.contains($0.key) }
        }
    }

    /// The note a pushed `NoteDetailView` shows now, which differs from its route after it switches
    /// notes in place (open-tab bar, offline id replaced by the server id).
    struct ShownNote: Equatable {
        let noteId: String
        let openTabId: String?
    }

    /// Keyed by `NoteDestination.routeId`. Routes stay as pushed: rewriting a path element would
    /// make the stack replace the view.
    private(set) var shownNotes: [UUID: ShownNote] = [:]

    func recordShownNote(_ note: ShownNote, forRoute routeId: UUID) {
        guard path.contains(where: { $0.noteDestination?.routeId == routeId }) else { return }
        shownNotes[routeId] = note
    }

    /// What the top of this stack is showing, or `nil` when no note is pushed.
    var currentNote: ShownNote? {
        guard let top = path.last?.noteDestination else { return nil }
        return shownNotes[top.routeId] ?? ShownNote(noteId: top.noteId, openTabId: top.openTabId)
    }

    /// Replaces whatever `level` has pushed with `route`. A tree view at `level` owns `path[level]`.
    /// Drilling into a subtree keeps the open note: in a split layout it stays beside the tree.
    /// (In a single stack no note is open while its tree is visible, so nothing is kept there.)
    func push(_ route: NoteRoute, fromLevel level: Int = 0) {
        let openNote = route.isSubtree ? Array(path.drop(while: \.isSubtree)) : []
        // A note opened from a list (Recents, Favorites) keeps the folders the sidebar tree is in.
        let base = !route.isSubtree && level == 0 ? Array(path.prefix(while: \.isSubtree)) : Array(path.prefix(level))
        path = base + [route] + openNote
        if let note = route.noteDestination { lastOpenedNoteId = note.noteId }
    }

    /// The most recently opened note, kept after it is closed so a tree level can mark the folder it is in.
    private(set) var lastOpenedNoteId: String?

    /// Pops everything `level` (and anything above it) has pushed.
    func popToLevel(_ level: Int) {
        guard path.count > level else { return }
        path = Array(path.prefix(level))
    }

    /// Closes the open note and keeps the folders drilled into, so the tree stays where it was.
    func closeNote() {
        path = Array(path.prefix(while: \.isSubtree))
    }

    func hasDestination(aboveLevel level: Int) -> Bool {
        path.count > level
    }

    // MARK: Split layout

    /// The note a detail column shows: the pushed note at the end of the path, if any.
    var topNoteDestination: NoteDestination? {
        path.last?.noteDestination
    }

    /// The drill-down part of the path, which a sidebar column shows as its own stack.
    var subtreePath: [NoteRoute] {
        get { Array(path.prefix(while: \.isSubtree)) }
        set { path = newValue + path.drop(while: \.isSubtree) }
    }
}

extension EnvironmentValues {
    /// `true` inside a split layout, where the tree is a sidebar next to the open note rather than
    /// a screen the note is pushed over.
    @Entry var isSplitNoteLayout = false
}

/// A `NavigationStack` driven by a `NoteStack`, which it also provides to its content.
struct NoteStackHost<Content: View>: View {
    @Bindable var stack: NoteStack
    /// Recents, Favorites and Search show the list beside the note when there is room; pickers do not.
    var splitsOnWideScreens = false
    /// Wide: the note tree fills the sidebar and this view (Recents, Favorites) the main area.
    var sidebarShowsTree = false
    @ViewBuilder var content: () -> Content
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        if splitsOnWideScreens, horizontalSizeClass == .regular {
            // Wide (iPad, Mac): the list stays beside the open note, as in the Notes tab.
            NavigationSplitView(columnVisibility: $columnVisibility) {
                Group {
                    if sidebarShowsTree {
                        NavigationStack(path: $stack.subtreePath) {
                            TreeView()
                        }
                    } else {
                        NavigationStack {
                            content()
                        }
                    }
                }
                .hingeAlignedSidebarWidth()
            } detail: {
                NavigationStack {
                    if let note = stack.topNoteDestination {
                        note.makeDetailView()
                            .id(note.routeId)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button {
                                        stack.closeNote()
                                    } label: {
                                        Label(String(localized: "Close Note", comment: "Split layout: close the open note"), systemImage: "xmark")
                                    }
                                    .keyboardShortcut("w", modifiers: .command)
                                }
                            }
                    } else if sidebarShowsTree {
                        content()
                    } else {
                        ContentUnavailableView(
                            String(localized: "No Note Selected", comment: "Split layout: nothing open yet"),
                            systemImage: "doc.text",
                            description: Text(String(localized: "Choose a note from the list.", comment: "Split layout: empty detail hint"))
                        )
                        .background(Color.trinoteGround.ignoresSafeArea())
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
            .background(Color.trinoteGround.ignoresSafeArea())
            .environment(stack)
            .environment(\.isSplitNoteLayout, true)
        } else {
            NavigationStack(path: $stack.path) {
                content()
            }
            .environment(stack)
        }
    }
}
