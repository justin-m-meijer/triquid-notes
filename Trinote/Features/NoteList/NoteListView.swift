import SwiftUI
import UIKit

/// The middle column (v2 redesign, artboard 2): a notebook's or smart folder's notes with a preview,
/// the first image and the date, newest first. A notebook's sub-folders sit as chips above the list;
/// a chip opens that folder.
struct NoteListView: View {
    @Environment(\.appFont) private var appFont
    @Environment(AppState.self) private var appState
    @Environment(NoteStack.self) private var stack
    let source: NoteListSource
    let refreshToken: Int
    /// Opens a sub-folder in this column.
    let onOpenFolder: (NoteListSource) -> Void
    /// New note outside a notebook goes through Quick capture.
    let onQuickCapture: () -> Void
    /// The round compose button; on iPad and Mac the note column has the only one.
    var showsComposeButton = true

    @AppStorage(NoteListOrder.storageKey) private var orderRaw: String = NoteListOrder.edited.rawValue
    @AppStorage(AppAccent.storageKey) private var appAccent: String = ""
    @AppStorage("colorTheme") private var colorTheme: String = ColorTheme.default.rawValue
    @State private var content = NoteListContent()
    /// The source, order and server `content` was last loaded for.
    @State private var loadedKey: String?
    @State private var isLoading = true
    @State private var inboxError: String?
    @State private var filter = ""
    @State private var showsFilter = false
    @State private var pendingDelete: NoteListRowData?
    @State private var eraseOnDelete = false
    @State private var appearanceTarget: NoteAppearanceTarget?
    @State private var moveRequest: NoteMoveRequest?
    @State private var actionError: String?
    @State private var tree: TreeViewModel?

    private var accent: AppAccent { AppAccent.resolve(stored: appAccent, legacyTheme: colorTheme) }
    @AppStorage("useTriliumNoteColors") private var useTriliumNoteColors = true

    /// A folder's Trilium `#color`, else the accent.
    private func folderTint(_ folder: NoteListFolder) -> Color {
        (useTriliumNoteColors ? TriliumNoteColorMapper.swiftUIColor(for: folder.color) : nil) ?? accent.color
    }

    private var order: NoteListOrder {
        let stored = NoteListOrder(rawValue: orderRaw) ?? .edited
        return stored == .manual && !source.supportsManualOrder ? .edited : stored
    }

    private var visibleRows: [NoteListRowData] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return content.rows }
        return content.rows.filter {
            $0.title.localizedStandardContains(query) || $0.preview.localizedStandardContains(query)
        }
    }

    private var notebookId: String? {
        if case .notebook(let noteId, _) = source { return noteId }
        return nil
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                if showsFilter {
                    filterField
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                if !content.folders.isEmpty {
                    folderChips
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 12, trailing: 0))
                        .listRowSeparator(.hidden, edges: .top)
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                ForEach(visibleRows) { row in
                    rowButton(row)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.trinoteGround.ignoresSafeArea())
        .overlay { emptyState }
        // Room for the last row to scroll clear of the compose button.
        .contentMargins(.bottom, 84, for: .scrollContent)
        .overlay(alignment: .bottomTrailing) {
            if showsComposeButton {
            FloatingComposeButton(
                tint: accent.color,
                accessibilityLabel: String(localized: "New note", comment: "Tab bar: quick capture button")
            ) {
                Task { await newNote() }
            }
            .padding(.trailing, 18)
            .padding(.bottom, 12)
            .intoSideStrip(trailingPadding: 18, width: 52)
            }
        }
        .refreshable { await SyncStatusSummary.syncNow(appState: appState) }
        .toolbar { toolbar }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .task(id: "\(source)-\(order.rawValue)-\(refreshToken)-\(appState.activeProfile?.id ?? "")") { await load() }
        .alert(
            String(localized: "Couldn't Create the Inbox", comment: "Empty Inbox: create failed"),
            isPresented: Binding(get: { inboxError != nil }, set: { if !$0 { inboxError = nil } })
        ) {
            Button(String(localized: "OK", comment: "Alert dismiss")) { inboxError = nil }
        } message: {
            Text(inboxError ?? "")
        }
        // The same confirm popup as the tree and the note screen, with the permanent-erase switch.
        .noteDeleteConfirmationAlert(
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            title: String(localized: "Delete Note?", comment: "Delete confirm title"),
            message: NoteDeleteConfirmationCopy.singleNoteMessage(title: pendingDelete?.title ?? ""),
            erasePermanently: $eraseOnDelete,
            onConfirm: {
                guard let row = pendingDelete else { return }
                let erase = eraseOnDelete
                Task { await delete(row, erase: erase) }
            },
            onCancel: { eraseOnDelete = false }
        )
        .noteMoveFlow($moveRequest) { Task { await load() } }
        .sheet(item: $appearanceTarget) { target in
            NoteAppearancePickerSheet(
                title: target.title,
                initialTab: target.initialTab,
                currentIconClass: target.iconClass,
                currentColorLabel: target.colorLabel,
                onSelectIcon: { icon in
                    Task { await setAppearance { try await NoteAppearanceUpdater.setIconClass(icon, noteId: target.noteId, appState: appState) } }
                },
                onSelectColor: { color in
                    Task { await setAppearance { try await NoteAppearanceUpdater.setColor(color, noteId: target.noteId, appState: appState) } }
                }
            )
        }
        .alert(
            String(localized: "Error", comment: "Generic error title"),
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
            actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
            message: { Text(actionError ?? "") }
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.title)
                .headingFont(32)
                .foregroundStyle(Color.trinoteTextPrimary)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(content.rows.count == 1
                     ? String(localized: "1 note", comment: "Markdown export result")
                     : String(localized: "\(content.rows.count) notes", comment: "Markdown export result"))
                Text(verbatim: "·")
                Menu {
                    Picker(String(localized: "Sort by", comment: "Note list order menu"), selection: $orderRaw) {
                        ForEach(NoteListOrder.allCases.filter { $0 != .manual || source.supportsManualOrder }) { option in
                            Text(option.localizedTitle).tag(option.rawValue)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(order.localizedTitle)
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .accessibilityLabel(String(localized: "Sort by \(order.localizedTitle)", comment: "Note list order menu, current order"))
            }
            .font(.footnote)
            .foregroundStyle(Color.trinoteTextTertiary)
        }
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.trinoteTextTertiary)
            TextField(String(localized: "Search in \(source.title)", comment: "Note list: filter field"), text: $filter)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.trinoteTextTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear", comment: "Clear text field"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color.trinoteFill, in: .capsule)
    }

    /// Sub-folders: a heading, then chips with a folder icon and a chevron, so they read as places to
    /// go into rather than notes (TestFlight feedback on build 42).
    private var folderChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Folders", comment: "Note list: heading above a notebook's sub-folder chips"))
                .font(.system(size: 12, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.trinoteTextTertiary)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(content.folders) { folder in
                        Button {
                            onOpenFolder(.notebook(noteId: folder.noteId, title: folder.title))
                        } label: {
                            HStack(spacing: 6) {
                                if folder.iconClass?.isEmpty == false {
                                    NoteIconView(
                                        iconClass: folder.iconClass,
                                        fallbackNoteType: NoteType(rawValue: folder.noteType) ?? .text,
                                        size: .compact,
                                        foregroundStyle: folderTint(folder)
                                    )
                                } else {
                                    Image(systemName: "folder.fill")
                                        .font(.callout)
                                        .foregroundStyle(folderTint(folder))
                                }
                                Text(folder.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.trinoteTextPrimary)
                                Text(folder.childCount, format: .number)
                                    .font(.caption)
                                    .foregroundStyle(Color.trinoteTextTertiary)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.trinoteTextTertiary)
                            }
                            .padding(.leading, 10)
                            .padding(.trailing, 12)
                            .frame(height: 34)
                            .background(Color.trinoteFill, in: .capsule)
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                open(noteId: folder.noteId, title: folder.title)
                            } label: {
                                Label(String(localized: "Open Note", comment: "Note list chip: open the folder note itself"), systemImage: "doc.text")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Rows

    private func rowButton(_ row: NoteListRowData) -> some View {
        let isSelected = stack.currentNote?.noteId == row.noteId
        return Button {
            open(noteId: row.noteId, title: row.title)
        } label: {
            NoteListRow(row: row, accent: accent, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowSeparatorTint(Color.trinoteSeparator)
        .listRowBackground(isSelected ? accent.color.opacity(0.07) : Color.clear)
        .draggable(NoteDragItem(noteId: row.noteId, title: row.title))
        .contextMenu { rowMenu(row) }
        // iPad and Mac: drag a note onto a notebook in the sidebar to move it there.
        .draggable(row.noteId)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { requestDelete(row) } label: {
                Label(String(localized: "Delete Note", comment: "Note overflow"), systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: NoteListRowData) -> some View {
        Button {
            open(noteId: row.noteId, title: row.title)
        } label: {
            Label(String(localized: "Open Note", comment: "Note list chip: open the folder note itself"), systemImage: "doc.text")
        }
        Button {
            UIPasteboard.general.url = NoteLink.url(for: row.noteId)
        } label: {
            Label(String(localized: "Copy Link", comment: "Note list: copy a triquidnotes:// link"), systemImage: "link")
        }
        Button {
            Task { await toggleFavorite(row) }
        } label: {
            Label(String(localized: "Favorite", comment: "Note list: add or remove a favorite"), systemImage: "star")
        }
        .disabled(!appState.isOnline)
        Button {
            moveRequest = NoteMoveRequest(noteId: row.noteId, title: row.title)
        } label: {
            Label(String(localized: "Move", comment: "Note overflow: move under another parent"), systemImage: "arrow.forward.folder")
        }
        Divider()
        Button {
            appearanceTarget = NoteAppearanceTarget(noteId: row.noteId, title: row.title, iconClass: row.iconClass, colorLabel: row.color, initialTab: .color)
        } label: {
            Label(String(localized: "Color…", comment: "Note list: pick the note's Trilium color"), systemImage: "paintpalette")
        }
        .disabled(!appState.isOnline)
        Button {
            appearanceTarget = NoteAppearanceTarget(noteId: row.noteId, title: row.title, iconClass: row.iconClass, colorLabel: row.color, initialTab: .icon)
        } label: {
            Label(String(localized: "Icon…", comment: "Note list: pick the note's Trilium icon"), systemImage: "face.smiling")
        }
        .disabled(!appState.isOnline)
        Divider()
        Button(role: .destructive) { requestDelete(row) } label: {
            Label(String(localized: "Delete Note", comment: "Note overflow"), systemImage: "trash")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !isLoading, content.rows.isEmpty, content.folders.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No Notes", comment: "Note list: nothing to show"), systemImage: "doc.text")
            } description: {
                Text(content.missingSourceHint ?? String(localized: "Notes you add here appear in this list.", comment: "Note list: empty"))
            } actions: {
                if content.missingInbox {
                    Button(String(localized: "Create an Inbox", comment: "Empty Inbox: makes an Inbox note labeled #inbox")) {
                        do {
                            try InboxNote.create(appState: appState)
                            Task { await load() }
                        } catch {
                            inboxError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                withAnimation(.snappy) {
                    showsFilter.toggle()
                    if !showsFilter { filter = "" }
                }
            } label: {
                Label(String(localized: "Search in \(source.title)", comment: "Note list: filter field"), systemImage: "magnifyingglass")
            }
            Menu {
                Picker(String(localized: "Sort by", comment: "Note list order menu"), selection: $orderRaw) {
                    ForEach(NoteListOrder.allCases.filter { $0 != .manual || source.supportsManualOrder }) { option in
                        Text(option.localizedTitle).tag(option.rawValue)
                    }
                }
            } label: {
                Label(String(localized: "Sort and view options", comment: "Note list toolbar menu"), systemImage: "ellipsis")
            }
        }
    }

    // MARK: - Actions

    private func open(noteId: String, title: String) {
        stack.closeNote()
        stack.push(.note(NoteDestination(noteId: noteId, title: title)))
    }

    private func load() async {
        guard let profileId = appState.activeProfile?.id else { return }
        isLoading = true
        defer { isLoading = false }
        let persistence = PersistenceManager.shared
        let loader = await NoteListLoader.background(persistence.container)
        let inboxId = InboxNote.find(profileId: profileId, persistence: persistence)?.noteId
        let favorites = ((try? persistence.fetchFavorites(serverProfileId: profileId)) ?? []).map(\.noteId)
        let recents = ((try? persistence.fetchRecentNotes(serverProfileId: profileId, limit: 50)) ?? []).map(\.noteId)
        // A notebook not cached yet (lazy tree) is fetched once from the server, then read from the cache.
        if let notebookId, tree == nil {
            let model = TreeViewModel(appState: appState, parentNoteId: notebookId)
            tree = model
            if (try? persistence.fetchCachedChildren(parentNoteId: notebookId, serverProfileId: profileId))?.isEmpty ?? true {
                await model.loadTree()
            }
        }
        // A list opened afresh shows its top rows with previews first; a long notebook's other previews follow.
        // A refresh of the list on screen loads everything at once, so its previews don't blink.
        let key = "\(source)-\(order.rawValue)-\(profileId)"
        let previewLimit = key == loadedKey ? Int.max : Self.firstPreviews
        guard let loaded = try? await loader.load(source, profileId: profileId, order: order, inboxNoteId: inboxId, favoriteIds: favorites, recentIds: recents, previewLimit: previewLimit) else { return }
        if loaded != content { content = loaded }
        loadedKey = key
        guard loaded.previewsPending,
              let full = try? await loader.load(source, profileId: profileId, order: order, inboxNoteId: inboxId, favoriteIds: favorites, recentIds: recents),
              !Task.isCancelled, full != content
        else { return }
        content = full
    }

    /// Rows a list opened afresh shows with previews before the rest: more than a screenful.
    private static let firstPreviews = 60

    private func newNote() async {
        guard let notebookId else {
            onQuickCapture()
            return
        }
        let model = tree ?? TreeViewModel(appState: appState, parentNoteId: notebookId)
        let title = String(localized: "New note", comment: "Default title of a note created from a list")
        if let noteId = await model.createChildNote(parentNoteId: notebookId, title: title) {
            FreshEmptyNotes.register(noteId)
            stack.closeNote()
            stack.push(.note(NoteDestination(noteId: noteId, title: title, startInEditMode: true)))
            await load()
        } else if let error = model.error {
            actionError = error
        }
    }

    private func requestDelete(_ row: NoteListRowData) {
        eraseOnDelete = false
        pendingDelete = row
    }

    /// Any list can delete (Recents, Favorites, smart folders): the tree model is only borrowed to do it.
    private func delete(_ row: NoteListRowData, erase: Bool) async {
        let model = tree ?? TreeViewModel(appState: appState, parentNoteId: notebookId ?? "root")
        if await model.deleteNoteAndSubnotes(noteId: row.noteId, eraseNotes: erase, refreshTree: tree != nil) {
            if stack.currentNote?.noteId == row.noteId { stack.closeNote() }
            await load()
        } else if let error = model.error {
            actionError = error
        }
    }

    private func setAppearance(_ change: () async throws -> Void) async {
        do {
            try await change()
            await load()
        } catch {
            actionError = APIError.from(error).localizedDescription
        }
    }

    private func toggleFavorite(_ row: NoteListRowData) async {
        guard let profileId = appState.activeProfile?.id else { return }
        let isFavorite = ((try? PersistenceManager.shared.fetchFavorites(serverProfileId: profileId)) ?? []).contains { $0.noteId == row.noteId }
        do {
            try await FavoriteBookmarks.setFavorite(!isFavorite, noteId: row.noteId, title: row.title, noteType: row.noteType, appState: appState)
            if source == .favorites { await load() }
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// One note in a list: icon and title, two lines of the body, the first image or the file kind, the date.
struct NoteListRow: View {
    let row: NoteListRowData
    let accent: AppAccent
    let isSelected: Bool
    @AppStorage("useTriliumNoteColors") private var useTriliumNoteColors = true

    private var tint: Color? {
        useTriliumNoteColors ? TriliumNoteColorMapper.swiftUIColor(for: row.color) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                NoteIconView(
                    iconClass: row.iconClass,
                    fallbackNoteType: NoteType(rawValue: row.noteType) ?? .text,
                    size: .regular,
                    foregroundStyle: tint ?? .trinoteIcon
                )
                .frame(width: 20)
                Text(row.title.isEmpty ? String(localized: "Untitled", comment: "Spotlight: note without a title") : row.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(tint ?? Color.trinoteTextPrimary)
                    .lineLimit(1)
                if row.isProtected {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Color.trinoteTextTertiary)
                }
            }
            if !row.preview.isEmpty {
                Text(row.preview)
                    .font(.system(size: 15))
                    .lineSpacing(2)
                    .foregroundStyle(Color.trinoteTextSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if row.thumbnail != nil || row.fileBadge != nil {
                HStack(spacing: 8) {
                    if let data = row.thumbnail, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 112, height: 76)
                            .clipShape(.rect(cornerRadius: 10))
                            .accessibilityHidden(true)
                    }
                    if let badge = row.fileBadge {
                        VStack(alignment: .leading) {
                            Text(row.title)
                                .font(.caption)
                                .foregroundStyle(Color.trinoteTextSecondary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.trinoteTextSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.trinotePlaceholder, in: .rect(cornerRadius: 6))
                        }
                        .padding(10)
                        .frame(width: 112, height: 76, alignment: .leading)
                        .background(Color.trinoteFill, in: .rect(cornerRadius: 10))
                    }
                }
                .padding(.top, 4)
            }
            Text(NoteListDate.string(for: row.modified))
                .font(.caption)
                .foregroundStyle(Color.trinoteTextTertiary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if isSelected {
                UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: 3, topTrailing: 3))
                    .fill(accent.color)
                    .frame(width: 4)
                    .padding(.vertical, 10)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
