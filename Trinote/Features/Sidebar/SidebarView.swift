import SwiftUI
import UniformTypeIdentifiers

/// What the sidebar has chosen for the middle column.
enum SidebarItem: Hashable {
    case list(NoteListSource)
    case search
    case settings
}

/// The sidebar (v2 redesign, artboard 1): the app's name and server, search, the smart folders and
/// the notebook tree, with the sync state at the foot. Dark in both themes.
struct SidebarView: View {
    @Environment(\.appFont) private var appFont
    @Environment(\.sidebarActionsInHeader) private var actionsInHeader
    @Environment(\.sidebarHideAction) private var hideSidebar
    @Environment(\.sidebarHomeAction) private var goHome
    @Environment(AppState.self) private var appState
    @Binding var selection: SidebarItem?
    /// Choosing anything moves a collapsed (phone) layout on to the list.
    let onChoose: () -> Void
    let refreshToken: Int
    /// The round compose button: a new quick note.
    /// `nil` hides the button (a list column next to the sidebar has its own).
    var onQuickCapture: (() -> Void)? = nil
    /// Opens a notebook or sub-note in the editor.
    var onOpenNote: (_ noteId: String, _ title: String) -> Void = { _, _ in }

    @AppStorage(AppAccent.storageKey) private var appAccent: String = ""
    @AppStorage("colorTheme") private var colorTheme: String = ColorTheme.default.rawValue
    @State private var notebooks: [SidebarNotebook] = []
    /// Trilium sorts the top-level notebooks itself: the root note carries `#sorted`. Read from the
    /// cache; the menu's sort choice sets or removes that label, so it holds on every device and in
    /// Trilium's own apps (TestFlight feedback).
    @State private var triliumSortsByTitle = false
    @State private var isChangingSort = false
    /// A sort choice just sent to Trilium, shown until the cache has the label too.
    @State private var pendingSortChoice: Bool?
    /// Asks first: Trilium rewrites the positions, so going back does not bring the old order back.
    @State private var confirmsTitleSort = false
    @AppStorage("useTriliumNoteColors") private var useTriliumNoteColors = true
    /// Before build 108: "manual", "title" or "custom", kept per device and in iCloud. Now Trilium
    /// holds the order; only read once to carry a dragged order over (`migrateCustomOrderToTrilium`).
    @AppStorage("sidebarNotebookOrder") private var notebookOrder = "manual"
    /// The custom order: note ids per server profile, as "profileId:id1,id2,…" lines. Siblings keep
    /// their place among themselves; notes not in it follow in Trilium's order.
    @AppStorage("sidebarNotebookCustomOrder") private var customOrderStore = ""
    @State private var counts = SidebarCounts()
    @State private var loadedKey: String?
    @State private var expanded: Set<String> = []
    @State private var showsNewNotebook = false
    @AppStorage(SavedSearches.storageKey) private var savedSearchesRaw = ""
    @State private var renamingSearch: SavedSearch?
    @State private var renameSearchTitle = ""
    @State private var newNotebookTitle = ""
    @State private var showsSyncDetails = false
    @State private var showsSwitchUser = false
    @State private var isOpeningJournal = false
    @State private var menuError: String?
    /// Long-press menu on a notebook row.
    @State private var pendingDelete: SidebarNotebook?
    @State private var eraseOnDelete = false
    @State private var appearanceTarget: NoteAppearanceTarget?
    @State private var newChildParent: SidebarNotebook?
    @State private var newChildTitle = ""
    @State private var moveRequest: NoteMoveRequest?
    /// The notebook a drag is over, and where on it: a line above or below, or an outline (into).
    @State private var dropTargetId: String?
    @State private var dropZone: SidebarDropZone = .into
    /// The note being dragged, so a row knows whether it can take a place beside it.
    @State private var draggingNoteId: String?
    private static let rowHeight: CGFloat = 42
    @AppStorage("showNoteTabsBar") private var showNoteTabsBar = false
    @Environment(NoteStack.self) private var noteStack

    /// The app's appearance, read before this view switches its own content to dark.
    @Environment(\.colorScheme) private var appearance

    private var accent: AppAccent { AppAccent.resolve(stored: appAccent, legacyTheme: colorTheme) }
    private var palette: SidebarPalette { SidebarPalette(appearance: appearance, accent: accent) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                searchField
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                VStack(spacing: 1) {
                    smartRow(.allNotes, icon: "doc.text", count: counts.allNotes)
                    smartRow(.inbox, icon: "tray", count: counts.inbox)
                    smartRow(.today, icon: "calendar", count: nil)
                    smartRow(.todo, icon: "checkmark.square", count: counts.todo)
                    smartRow(.favorites, icon: "star", count: counts.favorites)
                    smartRow(.recents, icon: "clock", count: nil)
                }
                .padding(.horizontal, 8)
                savedSearchesSection
                notebooksHeader
                // Lazy, like the note lists: an open notebook can hold thousands of notes.
                LazyVStack(spacing: 1) {
                    ForEach(sorted(notebooks)) { notebook in
                        notebookRows(notebook, depth: 0, siblings: notebooks, parentNoteId: TriliumTreeConstants.rootNoteId)
                    }
                }
                .padding(.horizontal, 8)
                // The sync status ends the list and scrolls with it, instead of a bar pinned over
                // the last notebooks of a long tree (TestFlight feedback).
                syncFooter
                    .padding(.top, 12)
                    // Room to scroll it clear of the quick-note button.
                    .padding(.bottom, 72)
            }
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottomTrailing) {
            if let onQuickCapture { quickNoteButton(onQuickCapture) }
        }
        // In the unfolded Duo's columns the window's side safe area (its sensor edge, ~80 pt held
        // sideways) reached the sidebar too and left a wide gap before the fold; and the hidden
        // bar kept its height, so the header sat ~60 pt below the note's bar. The header puts
        // the status bar's height back itself.
        .ignoresSafeArea(.container, edges: actionsInHeader ? [.horizontal, .top] : [])
        .background(palette.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .toolbar { toolbar }
        .toolbar(actionsInHeader ? .hidden : .automatic, for: .navigationBar)
        .navigationTitle(String(localized: "Notes", comment: "Sidebar: navigation title (shown only as the back button's name)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // Not on every appearance: as the root of the phone's stack the sidebar reappears after each
        // note, and recounting then made going back slow.
        .task(id: "\(appState.activeProfile?.id ?? "")-\(refreshToken)") {
            let key = "\(appState.activeProfile?.id ?? "")-\(refreshToken)"
            guard key != loadedKey else { return }
            await reload()
            loadedKey = key
            await migrateCustomOrderToTrilium()
        }
        .confirmationDialog(
            String(localized: "Sort notebooks by title in Trilium?", comment: "Sidebar: confirm title sort"),
            isPresented: $confirmsTitleSort,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Sort by Title", comment: "Sidebar: confirm title sort")) {
                Task { await setTriliumSortsByTitle(true) }
            }
            Button(String(localized: "Cancel", comment: "Alert dismiss"), role: .cancel) {}
        } message: {
            Text(String(localized: "Trilium keeps them in alphabetical order on every device and in its own apps. Switching back to Trilium order keeps the alphabetical order; the current order does not come back.", comment: "Sidebar: what the title sort does"))
        }
        .alert(String(localized: "New Notebook", comment: "Sidebar: create a top-level note"), isPresented: $showsNewNotebook) {
            TextField(String(localized: "Title", comment: "Quick capture title field placeholder"), text: $newNotebookTitle)
            Button(String(localized: "Cancel", comment: "Alert dismiss"), role: .cancel) {}
            Button(String(localized: "Create", comment: "Create note confirm")) { Task { await createNotebook() } }
        }
        .sheet(isPresented: $showsSwitchUser) {
            SwitchUserSheet().environment(appState)
        }
        .alert(
            String(localized: "Error", comment: "Generic error title"),
            isPresented: Binding(get: { menuError != nil }, set: { if !$0 { menuError = nil } }),
            actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
            message: { Text(menuError ?? "") }
        )
        .noteDeleteConfirmationAlert(
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            title: String(localized: "Delete Note?", comment: "Delete confirm title"),
            message: NoteDeleteConfirmationCopy.singleNoteMessage(title: pendingDelete?.title ?? ""),
            erasePermanently: $eraseOnDelete,
            onConfirm: {
                guard let notebook = pendingDelete else { return }
                let erase = eraseOnDelete
                Task { await delete(notebook, erase: erase) }
            },
            onCancel: { eraseOnDelete = false }
        )
        .sheet(item: $appearanceTarget) { target in
            NoteAppearancePickerSheet(
                title: target.title,
                initialTab: target.initialTab,
                currentIconClass: target.iconClass,
                currentColorLabel: target.colorLabel,
                onSelectIcon: { icon in
                    Task { await change { try await NoteAppearanceUpdater.setIconClass(icon, noteId: target.noteId, appState: appState) } }
                },
                onSelectColor: { color in
                    Task { await change { try await NoteAppearanceUpdater.setColor(color, noteId: target.noteId, appState: appState) } }
                }
            )
            .environment(\.colorScheme, appearance)
        }
        .alert(
            String(localized: "New Sub-note", comment: "Sidebar: create a note under a notebook"),
            isPresented: Binding(get: { newChildParent != nil }, set: { if !$0 { newChildParent = nil } })
        ) {
            TextField(String(localized: "Title", comment: "Quick capture title field placeholder"), text: $newChildTitle)
            Button(String(localized: "Cancel", comment: "Alert dismiss"), role: .cancel) {}
            Button(String(localized: "Create", comment: "Create note confirm")) {
                if let parent = newChildParent { Task { await createChild(under: parent) } }
            }
        }
        .noteMoveFlow($moveRequest) { Task { await forceReload() } }
        .sheet(isPresented: $showsSyncDetails) {
            SyncDetailsView()
                .environment(appState)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Header and search

    private var header: some View {
        Group {
            if actionsInHeader {
                // The title beside ⋯ and Settings when they fit side by side (the Duo held
                // sideways), the buttons on a row above it in a narrow column (upright), so the
                // title never truncates (TestFlight feedback).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        titleText.fixedSize()
                        Spacer(minLength: 0)
                        headerActions
                    }
                    VStack(alignment: .trailing, spacing: 6) {
                        headerActions
                        titleText.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 20)
                .padding(.trailing, 12)
                // Level with the note column's bar. The Duo's inner display reports ~84 pt of
                // top safe area upright, yet places bars ~24 pt from the top (its status sits at
                // the side), so this follows the bar.
                .padding(.top, 22)
                .padding(.bottom, 10)
            } else {
                titleRow
            }
        }
    }

    /// "Triquid Notes" and the server's name under it; beside the note column a tap goes home.
    @ViewBuilder
    private var titleText: some View {
        if let goHome {
            Button(action: goHome) { titleLabel }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Home", comment: "Sidebar: app title, goes back to the home screen"))
        } else {
            titleLabel
        }
    }

    private var titleLabel: some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text(verbatim: "Triquid ") + Text(verbatim: "Notes").foregroundStyle(accent.color))
                .headingFont(28)
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(appState.activeProfile?.name ?? "")
                .font(.footnote)
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center) {
            titleText
            Spacer(minLength: 8)
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    /// ⋯ and Settings sit in the navigation bar, like a list's buttons. With the bar hidden here (and
    /// drawn in the header), going back from a note left the note's buttons over the sidebar.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !actionsInHeader {
            ToolbarItemGroup(placement: .topBarTrailing) {
                moreMenu
                settingsButton
            }
        }
    }

    private var settingsButton: some View {
        Button {
            select(.settings)
        } label: {
            Label(String(localized: "Settings", comment: "Main tab"), systemImage: "gearshape")
        }
    }

    /// ⋯ and Settings beside the title, for the unfolded Duo's hand-laid columns: there the bar,
    /// in a window as short as a phone held sideways, stacked them vertically.
    private var headerActions: some View {
        HStack(spacing: 0) {
            if let hideSidebar {
                Button(action: hideSidebar) {
                    Label(String(localized: "Hide Sidebar", comment: "Sidebar: collapse the menu column"), systemImage: "sidebar.left")
                }
                .frame(width: 44, height: 44)
            }
            moreMenu
                .frame(width: 44, height: 44)
            settingsButton
                .frame(width: 44, height: 44)
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 17, weight: .medium))
        .tint(accent.color)
        .padding(.horizontal, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// What the tree's ⋯ menu offered before the sidebar: the journal, the open-notes bar and
    /// switching servers.
    private var moreMenu: some View {
        Menu {
            Button {
                Task { await openTodaysJournal() }
            } label: {
                Label(String(localized: "Open Today's Journal Note", comment: "Tree menu: open (or create) today's journal day note, as in Trilium"), systemImage: "calendar")
            }
            .disabled(isOpeningJournal)
            Button {
                showNoteTabsBar.toggle()
            } label: {
                Label(showNoteTabsBar
                      ? String(localized: "Hide open notes bar", comment: "Root tree menu: hide open-note tab strip")
                      : String(localized: "Show open notes bar", comment: "Root tree menu: show open-note tab strip"),
                      systemImage: "rectangle.split.1x2")
            }
            if PersistenceManager.shared.hasMultipleServerProfiles() {
                Divider()
                Button {
                    showsSwitchUser = true
                } label: {
                    Label(String(localized: "Switch user", comment: "Tree menu: switch signed-in instance"), systemImage: "person.2")
                }
            }
        } label: {
            Label(String(localized: "More", comment: "Root tree overflow menu"), systemImage: "ellipsis")
        }
    }

    private var searchField: some View {
        Button {
            select(.search)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                Text(String(localized: "Search", comment: "Main tab"))
                    .font(.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.secondary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(palette.field, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Search notes", comment: "Sidebar search field"))
    }

    // MARK: - Rows

    private func smartRow(_ source: NoteListSource, icon: String, count: Int?) -> some View {
        row(
            title: source.title,
            icon: { Image(systemName: icon).font(.system(size: 17)) },
            count: count.flatMap { $0 > 0 ? $0 : nil },
            isSelected: selection == .list(source),
            disclosure: nil,
            indent: 0
        ) {
            select(.list(source))
        }
    }

    // MARK: - Saved searches

    private var savedSearches: [SavedSearch] {
        SavedSearches.list(for: appState.activeProfile, raw: savedSearchesRaw)
    }

    /// Searches kept from the search screen; a tap runs the search again.
    @ViewBuilder
    private var savedSearchesSection: some View {
        if !savedSearches.isEmpty {
            sectionHeader(String(localized: "Saved Searches", comment: "Sidebar section: searches kept from the search screen"))
            VStack(spacing: 1) {
                ForEach(savedSearches) { search in
                    row(
                        title: search.name,
                        icon: { Image(systemName: "magnifyingglass").font(.system(size: 16)) },
                        count: nil,
                        isSelected: false,
                        disclosure: nil,
                        indent: 0
                    ) {
                        appState.pendingSearchQuery = search.query
                        select(.search)
                    }
                    .contextMenu {
                        Button {
                            renameSearchTitle = search.name
                            renamingSearch = search
                        } label: {
                            Label(String(localized: "Rename", comment: "Saved search menu"), systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            if let profile = appState.activeProfile { SavedSearches.remove(search, profile: profile) }
                        } label: {
                            Label(String(localized: "Remove Saved Search", comment: "Saved search menu"), systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .alert(
                String(localized: "Rename Saved Search", comment: "Saved search rename alert title"),
                isPresented: Binding(get: { renamingSearch != nil }, set: { if !$0 { renamingSearch = nil } })
            ) {
                TextField(String(localized: "Name", comment: "Saved search name field"), text: $renameSearchTitle)
                Button(String(localized: "Rename", comment: "Saved search menu")) {
                    if let search = renamingSearch, let profile = appState.activeProfile {
                        SavedSearches.rename(search, to: renameSearchTitle, profile: profile)
                    }
                    renamingSearch = nil
                }
                Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) { renamingSearch = nil }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer()
        }
        .foregroundStyle(palette.secondary)
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var notebooksHeader: some View {
        HStack {
            Text(String(localized: "Notebooks", comment: "Sidebar section: top-level notes"))
                .font(.system(size: 12, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer()
            Menu {
                Picker(String(localized: "Sort notebooks", comment: "Sidebar: notebook order menu"), selection: Binding(
                    get: { triliumSortsByTitle ? "title" : "manual" },
                    set: { choice in
                        if choice == "title" { confirmsTitleSort = true } else { Task { await setTriliumSortsByTitle(false) } }
                    }
                )) {
                    Label(String(localized: "Trilium order", comment: "Sidebar notebook order: as arranged in Trilium"), systemImage: "list.number")
                        .tag("manual")
                    Label(String(localized: "Title", comment: "Sidebar notebook order: alphabetical"), systemImage: "textformat")
                        .tag("title")
                }
            } label: {
                Image(systemName: isChangingSort ? "hourglass" : "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Sort notebooks", comment: "Sidebar: notebook order menu"))
            Button {
                newNotebookTitle = ""
                showsNewNotebook = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(!appState.isOnline)
            .accessibilityLabel(String(localized: "New notebook", comment: "Sidebar: create a top-level note"))
        }
        .foregroundStyle(palette.secondary)
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    /// Trilium's own order: it keeps notes sorted by title itself while `#sorted` is set.
    private func sorted(_ notebooks: [SidebarNotebook]) -> [SidebarNotebook] {
        notebooks
    }

    /// Sets or removes `#sorted` on the root note. Trilium then re-sorts the notebooks and the new
    /// positions reach every device with the next sync. Needs the server.
    private func setTriliumSortsByTitle(_ wanted: Bool) async {
        guard wanted != triliumSortsByTitle else { return }
        guard appState.isOnline, let client = appState.client, let profileId = appState.activeProfile?.id else {
            menuError = String(localized: "Changing the order needs a connection to your server.", comment: "Sidebar: change sort while offline")
            return
        }
        isChangingSort = true
        defer { isChangingSort = false }
        let root = TriliumTreeConstants.rootNoteId
        do {
            if wanted {
                try await client.createAttribute(CreateAttributeRequest(noteId: root, type: "label", name: "sorted", value: "", isInheritable: false, position: nil))
            } else {
                let note = try await client.getNote(root)
                for attribute in note.attributes where attribute.type == "label" && attribute.name == "sorted" && attribute.noteId == root {
                    try await client.deleteAttribute(noteId: root, attributeId: attribute.attributeId)
                }
            }
            // The cache learns the label with the next sync; show the choice now.
            pendingSortChoice = wanted
            triliumSortsByTitle = wanted
            await applyServerOrder(parentNoteId: root, client: client, profileId: profileId)
        } catch {
            menuError = APIError.from(error).localizedDescription
        }
    }

    private func readTriliumSort(profileId: String) {
        let attributes = (try? PersistenceManager.shared.fetchCachedAttributes(noteId: TriliumTreeConstants.rootNoteId, serverProfileId: profileId)) ?? []
        let cached = attributes.contains { $0.type == "label" && $0.name == "sorted" }
        if let pending = pendingSortChoice {
            if pending == cached { pendingSortChoice = nil }
            triliumSortsByTitle = pending
        } else {
            triliumSortsByTitle = cached
        }
    }

    /// A note dropped onto a notebook goes into it (online or queued offline), unless that would
    /// put a note inside its own sub-tree.
    private func moveInto(_ noteId: String, target: SidebarNotebook) async {
        if contains(noteId, descendant: target.noteId, in: notebooks) {
            menuError = String(localized: "A note cannot be moved under itself.", comment: "Move validation")
            return
        }
        guard let branchId = NoteMover.branchId(of: target.noteId, appState: appState) else {
            menuError = String(localized: "Could not resolve the note’s branch in the local cache.", comment: "Move branch missing offline")
            return
        }
        do {
            try await NoteMover.move(noteId: noteId, toParent: target.noteId, parentBranchId: branchId, appState: appState)
            withAnimation(.snappy) { _ = expanded.insert(target.noteId) }
            await forceReload()
        } catch {
            menuError = error.localizedDescription
        }
    }

    /// Whether `descendantId` sits anywhere under `ancestorId` (or is it).
    private func contains(_ ancestorId: String, descendant descendantId: String, in nodes: [SidebarNotebook]) -> Bool {
        for node in nodes {
            if node.noteId == ancestorId {
                return node.noteId == descendantId || subtree(node).contains(descendantId)
            }
            if contains(ancestorId, descendant: descendantId, in: node.folders) { return true }
        }
        return false
    }

    private func subtree(_ node: SidebarNotebook) -> Set<String> {
        node.folders.reduce(into: Set<String>()) { set, child in
            set.insert(child.noteId)
            set.formUnion(subtree(child))
        }
    }

    // MARK: - Order in Trilium

    /// Puts `draggedId` in `target`'s place among `siblings` in Trilium itself, so every device
    /// and Trilium's own apps show the same order (it used to be a separate order kept in iCloud;
    /// TestFlight feedback). Needs the server; offline it says so instead of keeping a second order.
    private func move(_ draggedId: String, beside target: SidebarNotebook, after: Bool, among siblings: [SidebarNotebook], parentNoteId: String) async {
        guard draggedId != target.noteId, siblings.contains(where: { $0.noteId == draggedId }) else { return }
        guard appState.isOnline, let client = appState.client, let profileId = appState.activeProfile?.id else {
            menuError = String(localized: "Reordering needs a connection to your server.", comment: "Sidebar: drag to reorder while offline")
            return
        }
        var ids = sorted(siblings).map(\.noteId)
        ids.removeAll { $0 == draggedId }
        let targetIndex = ids.firstIndex(of: target.noteId) ?? ids.endIndex
        ids.insert(draggedId, at: after ? min(targetIndex + 1, ids.endIndex) : targetIndex)
        let persistence = PersistenceManager.shared
        let branchIds = ids.compactMap {
            (try? persistence.fetchCachedBranch(noteId: $0, parentNoteId: parentNoteId, serverProfileId: profileId))?.branchId
        }
        guard branchIds.count == ids.count, let moved = (try? persistence.fetchCachedBranch(noteId: draggedId, parentNoteId: parentNoteId, serverProfileId: profileId))?.branchId else {
            menuError = String(localized: "Could not resolve the note’s branch in the local cache.", comment: "Move branch missing offline")
            return
        }
        // Trilium keeps a #sorted level sorted by title, so a drag there would not stick.
        if triliumSortsByTitle && parentNoteId == TriliumTreeConstants.rootNoteId {
            menuError = String(localized: "The notebooks are sorted by title in Trilium. Choose Trilium order to arrange them by hand.", comment: "Sidebar: drag while sorted by title")
            return
        }
        do {
            try await client.placeBranchInSiblingOrder(moved, orderedSiblingBranchIds: branchIds)
            await applyServerOrder(parentNoteId: parentNoteId, client: client, profileId: profileId)
        } catch {
            menuError = APIError.from(error).localizedDescription
        }
    }

    /// Reads a parent's child positions back from Trilium into the cache and redraws the menu.
    private func applyServerOrder(parentNoteId: String, client: any TriliumClientProtocol, profileId: String) async {
        if let (_, branches) = try? await client.getNoteWithBranches(parentNoteId) {
            let positions = Dictionary(branches.map { ($0.branchId, $0.notePosition) }, uniquingKeysWith: { first, _ in first })
            let persistence = PersistenceManager.shared
            try? persistence.applyChildBranchPositions(positions, parentNoteId: parentNoteId, serverProfileId: profileId)
            try? persistence.commitBatch()
        }
        await reload()
    }

    /// Builds before 108 kept a dragged order in iCloud ("Custom"). Once online, that order is
    /// written to Trilium level by level, then the stored copy is dropped, so nothing is lost.
    private func migrateCustomOrderToTrilium() async {
        guard notebookOrder != "manual" || !customOrderStore.isEmpty else { return }
        guard appState.isOnline, let client = appState.client, let profile = appState.activeProfile else { return }
        let lines = customOrderStore.split(separator: "\n")
        var order: [String] = []
        for key in [SettingsCloudSync.serverKey(for: profile), profile.id] {
            if let line = lines.first(where: { $0.hasPrefix(key + ":") }) {
                order = line.dropFirst(key.count + 1).split(separator: ",").map(String.init)
                break
            }
        }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let persistence = PersistenceManager.shared
        func walk(_ siblings: [SidebarNotebook], parentNoteId: String) async {
            let wanted = siblings.enumerated().sorted { a, b in
                let ra = rank[a.element.noteId] ?? Int.max
                let rb = rank[b.element.noteId] ?? Int.max
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element.noteId)
            if wanted != siblings.map(\.noteId) {
                let branchIds = wanted.compactMap {
                    (try? persistence.fetchCachedBranch(noteId: $0, parentNoteId: parentNoteId, serverProfileId: profile.id))?.branchId
                }
                if branchIds.count == wanted.count {
                    // One branch at a time beside its new neighbour, walking the wanted order.
                    for branchId in branchIds {
                        try? await client.placeBranchInSiblingOrder(branchId, orderedSiblingBranchIds: branchIds)
                    }
                    await applyServerOrder(parentNoteId: parentNoteId, client: client, profileId: profile.id)
                }
            }
            for notebook in siblings where !notebook.folders.isEmpty {
                await walk(notebook.folders, parentNoteId: notebook.noteId)
            }
        }
        await walk(notebooks, parentNoteId: TriliumTreeConstants.rootNoteId)
        customOrderStore = ""
        notebookOrder = "manual"
    }

    private func notebookRows(_ notebook: SidebarNotebook, depth: Int, siblings: [SidebarNotebook], parentNoteId: String) -> AnyView {
        let isExpanded = expanded.contains(notebook.noteId)
        let isOpen = noteStack.currentNote?.noteId == notebook.noteId
        let tint = useTriliumNoteColors ? TriliumNoteColorMapper.swiftUIColor(for: notebook.color) : nil
        return AnyView(LazyVStack(spacing: 1) {
            row(
                title: notebook.title,
                icon: {
                    NoteIconView(
                        iconClass: notebook.iconClass,
                        fallbackNoteType: NoteType(rawValue: notebook.noteType) ?? .text,
                        size: .regular,
                        foregroundStyle: tint ?? (isOpen ? accent.color : palette.icon)
                    )
                },
                titleColor: tint,
                count: notebook.childCount > 0 ? notebook.childCount : nil,
                isSelected: isOpen,
                disclosure: notebook.folders.isEmpty ? nil : isExpanded,
                indent: CGFloat(depth) * 22,
                onDisclosure: {
                    withAnimation(.snappy) {
                        if isExpanded { expanded.remove(notebook.noteId) } else { expanded.insert(notebook.noteId) }
                    }
                }
            ) {
                // Every item is a note (as in Trilium): it opens in the editor, with its sub-notes
                // listed under it; the arrow shows them here.
                onOpenNote(notebook.noteId, notebook.title)
            }
            // The same long-press menu as rows in lists and under a note.
            .contextMenu { notebookMenu(notebook) }
            // Long-press and drag. Over the upper or lower third of a note at the same level, a line
            // shows the place it takes above or below it; over the middle, an outline: into that
            // note. (The reorder edge used to be 10 pt, so a drop nearly always went in; TestFlight.)
            .onDrag {
                draggingNoteId = notebook.noteId
                return NSItemProvider(object: notebook.noteId as NSString)
            }
            .onDrop(of: [.plainText], delegate: SidebarRowDropDelegate(
                noteId: notebook.noteId,
                rowHeight: Self.rowHeight,
                draggingNoteId: draggingNoteId,
                canReorder: { id in siblings.contains { $0.noteId == id } },
                targetId: $dropTargetId,
                zone: $dropZone
            ) { id, zone in
                draggingNoteId = nil
                switch zone {
                case .before, .after:
                    Task { await move(id, beside: notebook, after: zone == .after, among: siblings, parentNoteId: parentNoteId) }
                case .into:
                    Task { await moveInto(id, target: notebook) }
                }
            })
            .overlay(alignment: dropZone == .after ? .bottom : .top) {
                if dropTargetId == notebook.noteId {
                    if dropZone == .into {
                        Capsule().strokeBorder(accent.color, lineWidth: 2)
                    } else {
                        Capsule()
                            .fill(accent.color)
                            .frame(height: 3)
                            .padding(.leading, 30 + CGFloat(depth) * 22)
                            .offset(y: dropZone == .after ? 2 : -2)
                    }
                }
            }
            if isExpanded {
                ForEach(sorted(notebook.folders)) { folder in
                    notebookRows(folder, depth: depth + 1, siblings: notebook.folders, parentNoteId: notebook.noteId)
                }
            }
        })
    }

    /// One sidebar row: disclosure (when it has sub-folders), icon, title, count. Selected rows sit on
    /// a lighter pill and take the accent.
    private func row<Icon: View>(
        title: String,
        @ViewBuilder icon: () -> Icon,
        titleColor: Color? = nil,
        count: Int?,
        isSelected: Bool,
        disclosure: Bool?,
        indent: CGFloat,
        onDisclosure: @escaping () -> Void = {},
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Group {
                if let disclosure {
                    Button(action: onDisclosure) {
                        Image(systemName: disclosure ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 42)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(disclosure
                        ? String(localized: "Collapse", comment: "Sidebar: hide sub-folders")
                        : String(localized: "Expand", comment: "Sidebar: show sub-folders"))
                } else {
                    Color.clear.frame(width: 22, height: 42)
                }
            }
            .foregroundStyle(palette.secondary)
            Button(action: action) {
                HStack(spacing: 10) {
                    icon()
                        .foregroundStyle(isSelected ? accent.color : palette.icon)
                        .frame(width: 22)
                    Text(title)
                        .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(titleColor ?? palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let count {
                        Text(count, format: .number)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(palette.secondary)
                    }
                }
                .frame(height: 42)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .padding(.leading, 4 + indent)
        .padding(.trailing, 12)
        .background(isSelected ? palette.selection : .clear, in: .capsule)
        .hoverEffect(.highlight)
    }

    private func quickNoteButton(_ onQuickCapture: @escaping () -> Void) -> some View {
        FloatingComposeButton(
            tint: accent.color,
            accessibilityLabel: String(localized: "New quick note", comment: "Sidebar: floating button that opens quick capture"),
            action: onQuickCapture
        )
        .padding(.trailing, 18)
        .padding(.bottom, 12)
        .intoSideStrip(trailingPadding: 18, width: 52)
    }

    // MARK: - Footer

    private var syncFooter: some View {
        let status = SyncStatusSummary(appState: appState)
        return HStack(spacing: 8) {
            Button {
                showsSyncDetails = true
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(status.dotColor).frame(width: 7, height: 7)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(SyncStatusSummary(appState: appState).summary)
                    }
                }
                .font(.footnote)
                .foregroundStyle(palette.secondary)
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                Task { await SyncStatusSummary.syncNow(appState: appState) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .medium))
                    .symbolEffect(.rotate, isActive: appState.syncManager.isSyncing)
                    .frame(width: 36, height: 36)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.secondary)
            .disabled(!status.canSyncNow)
            .accessibilityLabel(String(localized: "Sync now", comment: "Sync bar button"))
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(palette.background)
    }

    // MARK: - Actions

    private func select(_ item: SidebarItem) {
        selection = item
        onChoose()
    }

    private func reload() async {
        guard let profileId = appState.activeProfile?.id else { return }
        let persistence = PersistenceManager.shared
        let loader = await NoteListLoader.background(persistence.container)
        let inboxId = InboxNote.find(profileId: profileId, persistence: persistence)?.noteId
        let favoriteCount = (try? persistence.fetchFavorites(serverProfileId: profileId).count) ?? 0
        // The tree first, then the counts.
        notebooks = (try? await loader.notebookTree(profileId: profileId)) ?? []
        readTriliumSort(profileId: profileId)
        counts = (try? await loader.counts(profileId: profileId, inboxNoteId: inboxId, favoriteCount: favoriteCount)) ?? SidebarCounts()

    }

    // MARK: - Notebook long-press menu

    @ViewBuilder
    private func notebookMenu(_ notebook: SidebarNotebook) -> some View {
        Button {
            onOpenNote(notebook.noteId, notebook.title)
        } label: {
            Label(String(localized: "Open Note", comment: "Note list chip: open the folder note itself"), systemImage: "doc.text")
        }
        Button {
            newChildTitle = ""
            newChildParent = notebook
        } label: {
            Label(String(localized: "New Sub-note", comment: "Sidebar: create a note under a notebook"), systemImage: "plus")
        }
        .disabled(!appState.isOnline)
        Button {
            UIPasteboard.general.url = NoteLink.url(for: notebook.noteId)
        } label: {
            Label(String(localized: "Copy Link", comment: "Note list: copy a triquidnotes:// link"), systemImage: "link")
        }
        Button {
            Task { await toggleFavorite(notebook) }
        } label: {
            Label(String(localized: "Favorite", comment: "Note list: add or remove a favorite"), systemImage: "star")
        }
        .disabled(!appState.isOnline)
        Button {
            moveRequest = NoteMoveRequest(noteId: notebook.noteId, title: notebook.title)
        } label: {
            Label(String(localized: "Move", comment: "Note overflow: move under another parent"), systemImage: "arrow.forward.folder")
        }
        Divider()
        Button {
            appearanceTarget = NoteAppearanceTarget(noteId: notebook.noteId, title: notebook.title, iconClass: notebook.iconClass, colorLabel: notebook.color, initialTab: .color)
        } label: {
            Label(String(localized: "Color…", comment: "Note list: pick the note's Trilium color"), systemImage: "paintpalette")
        }
        .disabled(!appState.isOnline)
        Button {
            appearanceTarget = NoteAppearanceTarget(noteId: notebook.noteId, title: notebook.title, iconClass: notebook.iconClass, colorLabel: notebook.color, initialTab: .icon)
        } label: {
            Label(String(localized: "Icon…", comment: "Note list: pick the note's Trilium icon"), systemImage: "face.smiling")
        }
        .disabled(!appState.isOnline)
        Divider()
        Button(role: .destructive) {
            eraseOnDelete = false
            pendingDelete = notebook
        } label: {
            Label(String(localized: "Delete Note", comment: "Note overflow"), systemImage: "trash")
        }
    }

    private func toggleFavorite(_ notebook: SidebarNotebook) async {
        guard let profileId = appState.activeProfile?.id else { return }
        let isFavorite = ((try? PersistenceManager.shared.fetchFavorites(serverProfileId: profileId)) ?? []).contains { $0.noteId == notebook.noteId }
        do {
            try await FavoriteBookmarks.setFavorite(!isFavorite, noteId: notebook.noteId, title: notebook.title, noteType: notebook.noteType, appState: appState)
            await forceReload()
        } catch {
            menuError = APIError.from(error).localizedDescription
        }
    }

    private func delete(_ notebook: SidebarNotebook, erase: Bool) async {
        let tree = TreeViewModel(appState: appState, parentNoteId: TriliumTreeConstants.rootNoteId)
        if await tree.deleteNoteAndSubnotes(noteId: notebook.noteId, eraseNotes: erase, refreshTree: false) {
            if noteStack.currentNote?.noteId == notebook.noteId { noteStack.closeNote() }
            await forceReload()
        } else if let error = tree.error {
            menuError = error
        }
    }

    private func createChild(under parent: SidebarNotebook) async {
        let title = NoteCreationTitle.resolved(from: newChildTitle)
        let tree = TreeViewModel(appState: appState, parentNoteId: parent.noteId)
        if let noteId = await tree.createChildNote(parentNoteId: parent.noteId, title: title) {
            expanded.insert(parent.noteId)
            await forceReload()
            noteStack.closeNote()
            noteStack.push(.note(NoteDestination(noteId: noteId, title: title, startInEditMode: true)))
        } else if let error = tree.error {
            menuError = error
        }
    }

    private func change(_ action: () async throws -> Void) async {
        do {
            try await action()
            await forceReload()
        } catch {
            menuError = APIError.from(error).localizedDescription
        }
    }

    /// Reloads the tree and counts after a change made here (the usual reload skips repeats).
    private func forceReload() async {
        await reload()
    }

    private func openTodaysJournal() async {
        isOpeningJournal = true
        defer { isOpeningJournal = false }
        do {
            let note = try await TreeViewModel(appState: appState, parentNoteId: TriliumTreeConstants.rootNoteId).todaysJournalNote()
            noteStack.closeNote()
            noteStack.push(.note(NoteDestination(noteId: note.noteId, title: note.title, openTabId: note.openTabId)))
        } catch {
            menuError = error.localizedDescription
        }
    }

    private func createNotebook() async {
        let title = newNotebookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let tree = TreeViewModel(appState: appState, parentNoteId: TriliumTreeConstants.rootNoteId)
        if let noteId = await tree.createChildNote(parentNoteId: TriliumTreeConstants.rootNoteId, title: title) {
            await reload()
            select(.list(.notebook(noteId: noteId, title: title)))
        }
    }
}

/// The round, accent-tinted glass compose button at the bottom right of the sidebar and of a note
/// list, matching a note's edit button.
struct FloatingComposeButton: View {
    let tint: Color
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image("EditNoteFloating")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .foregroundStyle(Color(fixed: "#FFFFFF"))
                .padding(14)
                .glassEffect(.regular.tint(tint).interactive(), in: .circle)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

extension EnvironmentValues {
    /// The sidebar draws ⋯ and Settings in its header instead of the navigation bar.
    @Entry var sidebarActionsInHeader = false
    /// Collapses the hand-laid sidebar column (unfolded Duo); nil where the split view has its own button.
    @Entry var sidebarHideAction: (() -> Void)? = nil
    /// Shows the home screen beside the menu; nil on a phone, where the menu is the home.
    @Entry var sidebarHomeAction: (() -> Void)? = nil
}

/// Where on a sidebar row a dragged note lands.
enum SidebarDropZone {
    case before, into, after
}

/// Drops on a sidebar row: the upper and lower thirds of a note at the same level take a place
/// beside it, the middle (or any part of a note elsewhere in the tree) moves the note into it.
private struct SidebarRowDropDelegate: DropDelegate {
    let noteId: String
    let rowHeight: CGFloat
    let draggingNoteId: String?
    let canReorder: (String) -> Bool
    @Binding var targetId: String?
    @Binding var zone: SidebarDropZone
    let onDrop: (String, SidebarDropZone) -> Void

    private func zone(at y: CGFloat) -> SidebarDropZone {
        guard let draggingNoteId, canReorder(draggingNoteId) else { return .into }
        if y < rowHeight / 3 { return .before }
        if y > rowHeight * 2 / 3 { return .after }
        return .into
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggingNoteId != nil && draggingNoteId != noteId
    }

    func dropEntered(info: DropInfo) {
        targetId = noteId
        zone = zone(at: info.location.y)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        targetId = noteId
        let next = zone(at: info.location.y)
        if next != zone { zone = next }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if targetId == noteId { targetId = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { targetId = nil }
        guard let draggingNoteId, draggingNoteId != noteId,
              let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let dropZone = zone(at: info.location.y)
        // Called on the main queue below only.
        nonisolated(unsafe) let onDrop = onDrop
        // Only the note dragged from this menu: text dropped from elsewhere moves nothing.
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            let isOurs = (object as? String) == draggingNoteId
            DispatchQueue.main.async { if isOurs { onDrop(draggingNoteId, dropZone) } }
        }
        return true
    }
}
