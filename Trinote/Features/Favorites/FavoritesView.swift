import SwiftUI
import SwiftData

private enum FavoritesSortOrder: String, CaseIterable {
    case titleAscending = "A–Z"
    case titleDescending = "Z–A"
}

/// One top-level notebook (child of `root`) and its favorited descendants.
private struct FavoriteNotebookSection: Identifiable {
    let id: String
    let title: String
    let items: [FavoriteNote]
}

struct FavoritesView: View {
    var onNoteDeleted: (() -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(NoteStack.self) private var stack
    @Environment(\.colorScheme) private var colorScheme
    /// Set in the iPad split layout: notes open in the note pane instead of being pushed here.
    @AppStorage("useTriliumNoteColors") private var useTriliumNoteColors: Bool = true
    @AppStorage("useCustomTreeColors") private var useCustomTreeColors: Bool = false
    @AppStorage("treeLightBgColor") private var treeLightBgColor: String = "#F2F2F7"
    @AppStorage("treeDarkBgColor") private var treeDarkBgColor: String = "#1c1c1e"
    @State private var favorites: [FavoriteNote] = []
    /// Same row chrome as Recents: path from cache, tree “notebook” icon, last-open time when known.
    @State private var pathByNoteId: [String: String] = [:]
    @State private var displayTitleByNoteId: [String: String] = [:]
    @State private var iconContextByNoteId: [String: NoteRowIconContext] = [:]
    @State private var lastAccessByNoteId: [String: Date] = [:]
    /// Raw value of the leaf note's `#color` label (Trilium tree color), per note id.
    @State private var colorLabelByNoteId: [String: String] = [:]
    @State private var isEditMode = false
    @State private var selectedIds: Set<String> = []
    @State private var sortOrder: FavoritesSortOrder = .titleAscending
    @State private var deleteError: String?
    @State private var openingEntry: FixedEntry?
    /// Only a slow answer shows a spinner; a quick one opens without the row changing at all.
    @State private var showsOpeningSpinner = false

    @State private var confirmRemoveFromFavorites = false
    @State private var confirmBulkDelete = false
    @State private var eraseNotesOnBulkDelete = false
    @State private var confirmOpenDuplicatePicker = false
    @State private var confirmRunDuplicate = false
    @State private var showDuplicateParentPicker = false
    @State private var duplicateTargetParent: DuplicateParent?
    @State private var isBulkWorking = false

    private struct DuplicateParent: Equatable {
        let id: String
        let title: String
    }

    private var selectedCount: Int { selectedIds.count }

    private var bulkDuplicateConfirmMessage: String {
        guard let p = duplicateTargetParent else { return "" }
        return String(localized: "Create \(selectedCount) duplicate(s) under “\(p.title)”?", comment: "Favorites bulk duplicate confirm")
    }

    private var treeBgColor: Color? {
        guard useCustomTreeColors else { return nil }
        return colorScheme == .dark ? Color(hex: treeDarkBgColor) : Color(hex: treeLightBgColor)
    }

    private var treeChromeBackground: Color {
        treeBgColor ?? Color.trinoteGround
    }

    private var groupedFavoriteSections: [FavoriteNotebookSection] {
        guard let profileId = appState.activeProfile?.id, !favorites.isEmpty else { return [] }
        let pm = PersistenceManager.shared
        var buckets: [String: [FavoriteNote]] = [:]
        var titles: [String: String] = [:]

        for fav in favorites {
            let key: String
            if let topId = pm.topLevelNotebookId(noteId: fav.noteId, serverProfileId: profileId) {
                key = topId
                if titles[key] == nil {
                    if let cached = try? pm.fetchCachedNote(id: topId, serverProfileId: profileId) {
                        let t = cached.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let raw = t.isEmpty ? String(localized: "Notebook", comment: "Default notebook title") : t
                        titles[key] = NoteItem.maskedStoredTitle(
                            raw,
                            isProtected: cached.isProtected,
                            protectedSessionActive: appState.protectedSessionActive
                        )
                    } else {
                        titles[key] = "Notebook"
                    }
                }
            } else {
                key = "__other__"
                titles[key] = String(localized: "Other", comment: "Favorites grouping")
            }
            buckets[key, default: []].append(fav)
        }

        let session = appState.protectedSessionActive
        let sortKey: (FavoriteNote) -> String = { fav in
            let prot = (try? pm.fetchCachedNote(id: fav.noteId, serverProfileId: profileId))?.isProtected ?? false
            return NoteItem.maskedStoredTitle(fav.title, isProtected: prot, protectedSessionActive: session)
        }
        let sortedItems: ([FavoriteNote]) -> [FavoriteNote] = { notes in
            switch sortOrder {
            case .titleAscending:
                notes.sorted { sortKey($0).localizedCaseInsensitiveCompare(sortKey($1)) == .orderedAscending }
            case .titleDescending:
                notes.sorted { sortKey($0).localizedCaseInsensitiveCompare(sortKey($1)) == .orderedDescending }
            }
        }

        let keys = buckets.keys.sorted { a, b in
            if a == "__other__" { return false }
            if b == "__other__" { return true }
            return (titles[a] ?? "").localizedCaseInsensitiveCompare(titles[b] ?? "") == .orderedAscending
        }

        return keys.map { k in
            FavoriteNotebookSection(id: k, title: titles[k] ?? k, items: sortedItems(buckets[k] ?? []))
        }
    }

    var body: some View {
        mainContent
            .widePageTitle(String(localized: "Favorites", comment: "Favorites tab title"))
            .toolbar { toolbarContent }
            .task {
                loadFavorites()
                // Favorites became `#bookmarked`; label the ones made on this device before that.
                await FavoriteBookmarks.migrateLocalFavoritesIfNeeded(appState: appState)
                loadFavorites()
            }
            .onAppear { loadFavorites() }
            .refreshable { loadFavorites() }
            .onChange(of: appState.protectedSessionActive) { _, _ in loadFavorites() }
            .onChange(of: appState.activeProfile?.id) { _, _ in loadFavorites() }
            .onReceive(NotificationCenter.default.publisher(for: .trinoteWillSwitchServerProfile)) { _ in
                stack.popToLevel(0)
            }
            .alert(String(localized: "Delete Failed", comment: "Favorites error"), isPresented: deleteErrorBinding) {
                Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
            .alert(String(localized: "Remove from Favorites?", comment: "Favorites bulk confirm"), isPresented: $confirmRemoveFromFavorites) {
                Button(String(localized: "Cancel", comment: "Favorites alert"), role: .cancel) {}
                Button(String(localized: "Remove", comment: "Favorites alert"), role: .destructive) {
                    performBulkRemoveFromFavorites()
                }
            } message: {
                Text(String(localized: "Remove \(selectedCount) note(s) from Favorites? They will not be deleted from the server.", comment: "Favorites bulk remove"))
            }
            .noteDeleteConfirmationAlert(
                isPresented: $confirmBulkDelete,
                title: String(localized: "Delete Notes?", comment: "Favorites bulk delete"),
                message: NoteDeleteConfirmationCopy.bulkMessage(count: selectedCount),
                erasePermanently: $eraseNotesOnBulkDelete,
                onConfirm: {
                    let erase = eraseNotesOnBulkDelete
                    Task { await performBulkDeleteNotes(eraseNotes: erase) }
                },
                onCancel: { eraseNotesOnBulkDelete = false }
            )
            .alert(String(localized: "Duplicate Notes", comment: "Favorites duplicate flow"), isPresented: $confirmOpenDuplicatePicker) {
                Button(String(localized: "Cancel", comment: "Favorites alert"), role: .cancel) {}
                Button(String(localized: "Continue", comment: "Favorites duplicate")) {
                    showDuplicateParentPicker = true
                }
            } message: {
                Text(String(localized: "Next, choose a parent in the tree. \(selectedCount) duplicate(s) will be created as children of that note, or you can place them at the top level under Notes.", comment: "Favorites duplicate hint"))
            }
            .alert(String(localized: "Create Duplicates?", comment: "Favorites duplicate confirm"), isPresented: $confirmRunDuplicate) {
                Button(String(localized: "Cancel", comment: "Favorites alert"), role: .cancel) {
                    duplicateTargetParent = nil
                }
                Button(String(localized: "Create", comment: "Favorites duplicate")) {
                    Task { await performBulkDuplicate() }
                }
            } message: {
                Text(bulkDuplicateConfirmMessage)
            }
            .navigationDestination(for: NoteRoute.self) { route in
                route.noteDestination?.makeDetailView()
            }
            .sheet(isPresented: $showDuplicateParentPicker) {
                ParentPickerSheet(
                    navigationTitle: String(localized: "Choose Parent"),
                    instruction: String(localized: "Choose where to place the duplicates. Use the tree to open folders, then tap a note to select it as the parent."),
                    topLevelButtonTitle: String(localized: "Top level (under Notes)"),
                    onPick: { parentId, title, _ in
                        duplicateTargetParent = DuplicateParent(id: parentId, title: title)
                        showDuplicateParentPicker = false
                        confirmRunDuplicate = true
                    }
                )
                .environment(appState)
            }
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )
    }

    @ViewBuilder
    private var mainContent: some View {
        favoritesList
    }

    /// Inbox and Today are always here (redesign §3); Trilium resolves which note each is.
    private enum FixedEntry: CaseIterable {
        case inbox
        case today

        var title: String {
            switch self {
            case .inbox: String(localized: "Inbox", comment: "Favorites: fixed entry for Trilium's inbox")
            case .today: String(localized: "Today", comment: "Favorites: fixed entry for today's journal note")
            }
        }

        var systemImage: String {
            switch self {
            case .inbox: "tray"
            case .today: "calendar"
            }
        }
    }

    private var fixedEntries: some View {
        Section {
            ForEach(FixedEntry.allCases, id: \.self) { entry in
                Button {
                    open(entry)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: entry.systemImage)
                            .font(.body)
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                        Text(entry.title)
                            .foregroundStyle(Color.trinoteTextPrimary)
                        Spacer(minLength: 0)
                        if openingEntry == entry, showsOpeningSpinner {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Color.trinoteTextTertiary)
                        }
                    }
                    .frame(minHeight: 34)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(treeBgColor ?? Color.trinoteCard)
            }
        }
    }

    private func open(_ entry: FixedEntry) {
        guard appState.isOnline, let client = appState.client else {
            deleteError = String(localized: "Inbox and Today need a connection to the server.", comment: "Favorites: fixed entry while offline")
            return
        }
        // The local calendar day; `.iso8601` alone would format in UTC.
        guard openingEntry == nil else { return }
        let day = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        openingEntry = entry
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if openingEntry == entry { showsOpeningSpinner = true }
        }
        Task {
            defer {
                openingEntry = nil
                showsOpeningSpinner = false
            }
            do {
                let note = switch entry {
                case .inbox: try await CaptureDestinations.resolveInboxNote(client: client, profileId: appState.activeProfile?.id ?? "", day: day)
                case .today: try await client.getDayNote(onISODay: day)
                }
                stack.push(.note(NoteDestination(noteId: note.noteId, title: note.title)))
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private var favoritesList: some View {
        let sections = groupedFavoriteSections
        return List {
            // Inbox and Today come from a Trilium server.
            if appState.activeProfile?.isLocal != true {
                fixedEntries
            }
            if sections.isEmpty {
                Section {
                    Text(String(localized: "Long-press a note in the tree and choose “Add to Favorites” to add it here.", comment: "Favorites empty hint"))
                        .font(.callout)
                        .foregroundStyle(Color.trinoteTextSecondary)
                        .listRowBackground(Color.clear)
                }
            }
            // Rounded cards per notebook, like Recents and the tree (redesign §3).
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { fav in
                        favoriteListItem(fav)
                            .listRowBackground(treeBgColor ?? Color.trinoteCard)
                    }
                } header: {
                    favoriteSectionHeader(section)
                }
            }
        }
        .listStyle(.insetGrouped)
        // Same list metrics as the note tree, so the first card lines up with the tree's.
        .listSectionSpacing(.compact)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(treeChromeBackground)
        .disabled(isBulkWorking)
    }

    private func favoriteSectionHeader(_ section: FavoriteNotebookSection) -> some View {
        let headerIcon = sectionHeaderIconContext(for: section)
        return HStack(spacing: 6) {
            NoteIconView(
                iconClass: headerIcon.iconClass,
                fallbackNoteType: headerIcon.fallbackNoteType,
                size: .regular,
                foregroundStyle: Color.trinoteTextSecondary
            )
            .accessibilityHidden(true)
            Text(section.title)
                .lineLimit(1)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.trinoteTextSecondary)
        .accessibilityAddTraits(.isHeader)
    }

    private func sectionHeaderIconContext(for section: FavoriteNotebookSection) -> NoteRowIconContext {
        guard let profileId = appState.activeProfile?.id else {
            return NoteRowIconContext(iconClass: nil, fallbackNoteType: .text)
        }
        if section.id == "__other__" {
            return NoteRowIconContext(iconClass: nil, fallbackNoteType: .collection)
        }
        return PersistenceManager.shared.recentsRowIconContext(
            noteId: section.id,
            fallbackNoteType: NoteType.text.rawValue,
            serverProfileId: profileId
        )
    }

    @ViewBuilder
    private func favoriteListItem(_ fav: FavoriteNote) -> some View {
        Group {
            if isEditMode {
                Button { toggleSelection(fav.noteId) } label: { favoriteRow(fav) }
                    .buttonStyle(.plain)
            } else {
                Button {
                    let navTitle = displayTitleByNoteId[fav.noteId] ?? fav.title
                    stack.push(.note(NoteDestination(noteId: fav.noteId, title: navTitle)))
                } label: { favoriteRow(fav) }
                    .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { contextMenuContent(for: fav) }
    }

    @ViewBuilder
    private func contextMenuContent(for fav: FavoriteNote) -> some View {
        Button { sortOrder = .titleAscending } label: {
            Label(String(localized: "Sort by Title (A–Z)", comment: "Favorites context menu"), systemImage: "arrow.up")
        }
        Button { sortOrder = .titleDescending } label: {
            Label(String(localized: "Sort by Title (Z–A)", comment: "Favorites context menu"), systemImage: "arrow.down")
        }
        Divider()
        Button(role: .destructive) {
            Task { await deleteNote(fav) }
        } label: {
            Label(String(localized: "Delete Note", comment: "Favorites context menu"), systemImage: "trash")
        }
        Button { removeFavorite(fav) } label: {
            Label(String(localized: "Remove from Favorites", comment: "Favorites context menu"), systemImage: "star.slash")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 16) {
                if isEditMode, !selectedIds.isEmpty {
                    Menu {
                        Button {
                            confirmRemoveFromFavorites = true
                        } label: {
                            Label(String(localized: "Remove from Favorites", comment: "Favorites bulk menu"), systemImage: "star.slash")
                        }
                        .disabled(isBulkWorking)

                        Button(role: .destructive) {
                            eraseNotesOnBulkDelete = false
                            confirmBulkDelete = true
                        } label: {
                            Label(String(localized: "Delete Notes", comment: "Favorites bulk menu"), systemImage: "trash")
                        }
                        .disabled(isBulkWorking)

                        Button {
                            confirmOpenDuplicatePicker = true
                        } label: {
                            Label(String(localized: "Duplicate under Parent…", comment: "Favorites bulk menu"), systemImage: "doc.on.doc")
                        }
                        .disabled(isBulkWorking)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(String(localized: "Bulk actions", comment: "Favorites toolbar"))
                }
                if isEditMode {
                    Button {
                        isEditMode = false
                        selectedIds.removeAll()
                    } label: {
                        Label(String(localized: "Done", comment: "Favorites edit mode"), systemImage: "checkmark")
                    }
                    .disabled(isBulkWorking)
                } else if !favorites.isEmpty {
                    // The same sliders button as Home's Customize, with what Edit and the context
                    // menu offered.
                    Menu {
                        Button {
                            isEditMode = true
                        } label: {
                            Label(String(localized: "Select Notes", comment: "Favorites: enter selection mode"), systemImage: "checkmark.circle")
                        }
                        Picker(String(localized: "Sort", comment: "Favorites sort menu"), selection: $sortOrder) {
                            Label(String(localized: "Title (A–Z)", comment: "Favorites sort"), systemImage: "arrow.up").tag(FavoritesSortOrder.titleAscending)
                            Label(String(localized: "Title (Z–A)", comment: "Favorites sort"), systemImage: "arrow.down").tag(FavoritesSortOrder.titleDescending)
                        }
                    } label: {
                        Label(String(localized: "Options", comment: "Favorites options menu"), systemImage: "slider.horizontal.3")
                    }
                    .disabled(isBulkWorking)
                }
            }
        }
    }

    private func favoriteRow(_ fav: FavoriteNote) -> some View {
        HStack(spacing: 12) {
            if isEditMode {
                Image(systemName: selectedIds.contains(fav.noteId) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIds.contains(fav.noteId) ? Color.accentColor : Color.secondary)
            }
            let rowIcon = favoritesRowIcon(for: fav)
            NoteIconView(
                iconClass: rowIcon.iconClass,
                fallbackNoteType: rowIcon.fallbackNoteType,
                size: .regular,
                foregroundStyle: resolvedIconColor(for: fav)
            )
            .frame(width: 24)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitleByNoteId[fav.noteId] ?? fav.title)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(resolvedTitleColor(for: fav))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let accessLabel = favoritesAccessLabel(for: fav) {
                        Text(accessLabel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if let path = pathByNoteId[fav.noteId], !path.isEmpty {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isEditMode {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func favoritesRowIcon(for fav: FavoriteNote) -> NoteRowIconContext {
        if let ctx = iconContextByNoteId[fav.noteId] { return ctx }
        return NoteRowIconContext(
            iconClass: nil,
            fallbackNoteType: NoteType(rawValue: fav.noteType) ?? .text
        )
    }

    private func favoritesAccessLabel(for fav: FavoriteNote) -> String? {
        guard let d = lastAccessByNoteId[fav.noteId] else { return nil }
        return d.relativeDisplay
    }

    private func triliumColor(for fav: FavoriteNote) -> Color? {
        guard useTriliumNoteColors else { return nil }
        if let profileId = appState.activeProfile?.id,
           let cached = try? PersistenceManager.shared.fetchCachedNote(id: fav.noteId, serverProfileId: profileId),
           cached.isProtected,
           !appState.protectedSessionActive {
            return nil
        }
        return TriliumNoteColorMapper.swiftUIColor(for: colorLabelByNoteId[fav.noteId])
    }

    private func resolvedTitleColor(for fav: FavoriteNote) -> Color {
        triliumColor(for: fav) ?? .primary
    }

    private func resolvedIconColor(for fav: FavoriteNote) -> Color {
        triliumColor(for: fav) ?? .secondary
    }

    private func toggleSelection(_ noteId: String) {
        if selectedIds.contains(noteId) {
            selectedIds.remove(noteId)
        } else {
            selectedIds.insert(noteId)
        }
    }

    private func loadFavorites() {
        guard let profileId = appState.activeProfile?.id else {
            favorites = []
            pathByNoteId = [:]
            displayTitleByNoteId = [:]
            iconContextByNoteId = [:]
            lastAccessByNoteId = [:]
            colorLabelByNoteId = [:]
            return
        }
        let pm = PersistenceManager.shared
        do {
            let raw = try pm.fetchFavorites(serverProfileId: profileId)
            var paths: [String: String] = [:]
            var titlesOut: [String: String] = [:]
            var icons: [String: NoteRowIconContext] = [:]
            var access: [String: Date] = [:]
            var colors: [String: String] = [:]
            var visible: [FavoriteNote] = []
            visible.reserveCapacity(raw.count)

            for fav in raw {
                if GhostNoteTracker.shared.contains(fav.noteId, serverProfileId: profileId) {
                    continue
                }

                let leafProtected = (try? pm.fetchCachedNote(id: fav.noteId, serverProfileId: profileId))?.isProtected ?? false
                let rowTitle = NoteItem.maskedStoredTitle(
                    fav.title,
                    isProtected: leafProtected,
                    protectedSessionActive: appState.protectedSessionActive
                )

                let pathFull = pm.cachedNotePathDisplay(
                    noteId: fav.noteId,
                    leafTitle: fav.title,
                    leafIsProtected: leafProtected,
                    serverProfileId: profileId,
                    protectedSessionActive: appState.protectedSessionActive
                )
                let pathUI = (pathFull == rowTitle) ? "" : pathFull

                let hasCachedLeaf = (try? pm.fetchCachedNote(id: fav.noteId, serverProfileId: profileId)) != nil
                if !hasCachedLeaf && pathUI.isEmpty {
                    continue
                }

                visible.append(fav)
                paths[fav.noteId] = pathUI
                titlesOut[fav.noteId] = rowTitle

                icons[fav.noteId] = pm.recentsRowIconContext(
                    noteId: fav.noteId,
                    fallbackNoteType: fav.noteType,
                    serverProfileId: profileId
                )
                if let recent = try? pm.fetchRecentNote(noteId: fav.noteId, serverProfileId: profileId) {
                    access[fav.noteId] = recent.accessedAt
                }
                if let colorRaw = pm.cachedNoteColorLabel(noteId: fav.noteId, serverProfileId: profileId) {
                    colors[fav.noteId] = colorRaw
                }
            }

            favorites = visible
            pathByNoteId = paths
            displayTitleByNoteId = titlesOut
            iconContextByNoteId = icons
            lastAccessByNoteId = access
            colorLabelByNoteId = colors
        } catch {
            Log.persistence.error("Failed to load favorites: \(error)")
            favorites = []
            pathByNoteId = [:]
            displayTitleByNoteId = [:]
            iconContextByNoteId = [:]
            lastAccessByNoteId = [:]
            colorLabelByNoteId = [:]
        }
    }

    private func performBulkRemoveFromFavorites() {
        let chosen = favorites.filter { selectedIds.contains($0.noteId) }.map { ($0.noteId, $0.title, $0.noteType) }
        Task {
            do {
                for (noteId, title, noteType) in chosen {
                    try await FavoriteBookmarks.setFavorite(false, noteId: noteId, title: title, noteType: noteType, appState: appState)
                }
            } catch {
                Log.persistence.error("Failed to remove favorites: \(error)")
                deleteError = error.localizedDescription
            }
            loadFavorites()
            selectedIds.removeAll()
            isEditMode = false
        }
    }

    private func performBulkDeleteNotes(eraseNotes: Bool) async {
        guard appState.client != nil, appState.activeProfile?.id != nil else {
            deleteError = "Cannot delete while offline."
            return
        }
        isBulkWorking = true
        defer { isBulkWorking = false }
        let ids = Array(selectedIds)
        for noteId in ids where noteId != "root" {
            if let fav = favorites.first(where: { $0.noteId == noteId }) {
                await deleteFavoriteNoteOnServer(fav, postSync: false, eraseNotes: eraseNotes)
            }
        }
        confirmBulkDelete = false
        selectedIds.removeAll()
        isEditMode = false
        loadFavorites()
        onNoteDeleted?()
    }

    private func performBulkDuplicate() async {
        guard let client = appState.client, let parent = duplicateTargetParent, let profileId = appState.activeProfile?.id else {
            duplicateTargetParent = nil
            return
        }
        isBulkWorking = true
        defer {
            isBulkWorking = false
            duplicateTargetParent = nil
            confirmRunDuplicate = false
        }
        let ids = Array(selectedIds)
        var failures = 0
        for noteId in ids {
            do {
                let response = try await client.duplicateNoteAsChild(sourceNoteId: noteId, parentNoteId: parent.id)
                try? PersistenceManager.shared.cacheNote(from: response.note, serverProfileId: profileId)
                try? PersistenceManager.shared.cacheBranch(from: response.branch, serverProfileId: profileId)
                try? PersistenceManager.shared.commitBatch()
            } catch {
                failures += 1
                Log.api.error("Bulk duplicate failed for \(noteId): \(error)")
            }
        }
        if failures > 0 {
            deleteError = failures == ids.count
                ? "Could not duplicate the selected notes."
                : "\(failures) of \(ids.count) notes could not be duplicated (e.g. protected notes)."
        }
        selectedIds.removeAll()
        isEditMode = false
        loadFavorites()
        onNoteDeleted?()
    }

    private func removeFavorite(_ fav: FavoriteNote) {
        let (noteId, title, noteType) = (fav.noteId, fav.title, fav.noteType)
        Task {
            do {
                try await FavoriteBookmarks.setFavorite(false, noteId: noteId, title: title, noteType: noteType, appState: appState)
            } catch {
                Log.persistence.error("Failed to remove favorite: \(error)")
                deleteError = error.localizedDescription
            }
            loadFavorites()
        }
    }

    private func deleteNote(_ fav: FavoriteNote) async {
        await deleteFavoriteNoteOnServer(fav, postSync: true, eraseNotes: false)
    }

    private func deleteFavoriteNoteOnServer(_ fav: FavoriteNote, postSync: Bool, eraseNotes: Bool) async {
        guard let client = appState.client, let profileId = appState.activeProfile?.id else {
            if postSync { deleteError = "Cannot delete while offline." }
            return
        }
        guard fav.noteId != "root" else { return }
        do {
            try await client.deleteNote(fav.noteId, eraseNotes: eraseNotes)
            GhostNoteTracker.shared.add(fav.noteId, serverProfileId: profileId)
            PersistenceManager.shared.removeFavoritesForCachedSubtree(rootNoteId: fav.noteId, serverProfileId: profileId)
            PersistenceManager.shared.closeOpenNoteTabs(forDeletedNoteId: fav.noteId, serverProfileId: profileId)
            try? PersistenceManager.shared.deleteCachedNotes(noteIds: [fav.noteId], serverProfileId: profileId)
            loadFavorites()
            if postSync { onNoteDeleted?() }
        } catch {
            if postSync {
                deleteError = APIError.from(error).localizedDescription
            }
            Log.api.error("Failed to delete note: \(error)")
        }
    }
}

#Preview {
    NoteStackHost(stack: NoteStack()) {
        FavoritesView()
    }
    .environment(AppState())
    .modelContainer(PersistenceManager.shared.container)
}
