import SwiftUI
import UIKit

struct SearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(NoteStack.self) private var stack
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("useCustomTreeColors") private var useCustomTreeColors: Bool = false
    @AppStorage("treeLightBgColor") private var treeLightBgColor: String = "#F2F2F7"
    @AppStorage("treeDarkBgColor") private var treeDarkBgColor: String = "#1c1c1e"
    @State private var viewModel: SearchViewModel?
    @FocusState private var isSearchFieldFocused: Bool
    @AppStorage(SavedSearches.storageKey) private var savedSearchesRaw = ""
    @State private var showsSaveSearch = false
    @State private var saveSearchName = ""

    private var treeBgColor: Color? {
        guard useCustomTreeColors else { return nil }
        return colorScheme == .dark ? Color(hex: treeDarkBgColor) : Color(hex: treeLightBgColor)
    }

    private var treeChromeBackground: Color {
        treeBgColor ?? Color.trinoteGround
    }

    private var listRowBackgroundColor: Color {
        treeBgColor ?? Color.trinoteCard
    }

    var body: some View {
        Group {
            if let viewModel {
                searchContent(viewModel)
            } else {
                ProgressView()
            }
        }
        .background(treeChromeBackground)
        .widePageTitle(String(localized: "Search", comment: "Search tab title"))
        .task {
            if viewModel == nil {
                let vm = SearchViewModel(appState: appState)
                viewModel = vm
                vm.loadRecentSearches()
            }
            runPendingSavedSearch()
        }
        .onChange(of: appState.pendingSearchQuery) { _, _ in runPendingSavedSearch() }
        .alert(String(localized: "Save Search", comment: "Search: save the current search"), isPresented: $showsSaveSearch) {
            TextField(String(localized: "Name", comment: "Saved search name field"), text: $saveSearchName)
            Button(String(localized: "Save", comment: "Save button")) {
                if let vm = viewModel, let profile = appState.activeProfile {
                    SavedSearches.add(name: saveSearchName, query: vm.query, profile: profile)
                }
            }
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {}
        } message: {
            Text(String(localized: "It appears under Saved Searches in the menu.", comment: "Search: save alert message"))
        }
        .navigationDestination(for: NoteRoute.self) { route in
            route.noteDestination?.makeDetailView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .trinoteWillSwitchServerProfile)) { _ in
            stack.popToLevel(0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .trinoteSearchTabReselected)) { _ in
            viewModel?.clearSearch()
            isSearchFieldFocused = true
        }
    }

    @ViewBuilder
    private func searchContent(_ vm: SearchViewModel) -> some View {
        VStack(spacing: 0) {
            searchBar(vm)
            if let problem = vm.queryProblem, !vm.query.isEmpty {
                Label {
                    Text(problem)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .accessibilityLabel(String(format: String(localized: "Search query problem: %@", comment: "VoiceOver: search lint message"), problem))
            }

            if vm.isSearching {
                Spacer()
                ProgressView(String(localized: "Searching…", comment: "Search in progress"))
                Spacer()
            } else if let error = vm.error, vm.results.isEmpty {
                Spacer()
                ContentUnavailableView {
                    Label(String(localized: "Search Error", comment: "Search failure title"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button(String(localized: "Retry", comment: "Retry search")) { vm.searchNow(forceServer: true) }
                        .buttonStyle(.bordered)
                }
                Spacer()
            } else if vm.hasSearched && vm.results.isEmpty && vm.isOfflineResults {
                Spacer()
                ContentUnavailableView {
                    Label(String(localized: "No Results on This Device", comment: "Offline search: nothing found locally"), systemImage: "iphone.slash")
                } description: {
                    Text(vm.localResultsDetails.joined(separator: "\n"))
                } actions: {
                    if vm.localResultsCanRetryServer {
                        Button(String(localized: "Retry", comment: "Retry search")) { vm.searchNow(forceServer: true) }
                            .buttonStyle(.bordered)
                    }
                }
                Spacer()
            } else if vm.hasSearched && vm.results.isEmpty {
                Spacer()
                ContentUnavailableView.search(text: vm.query)
                Spacer()
            } else if vm.hasSearched {
                resultsList(vm)
            } else {
                recentSearchesList(vm)
            }
        }
        // In the wide main area (iPad, Mac) a readable centered column, not edge to edge.
        .frame(maxWidth: 720, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .background(treeChromeBackground)
    }

    private func searchBar(_ vm: SearchViewModel) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                if let label = LabelQuery.parse(vm.query) {
                    // A tag search reads as the tag, not as Trilium's #name="value" syntax.
                    Button {
                        vm.clearSearch()
                        isSearchFieldFocused = true
                    } label: {
                        Label(label.friendly, systemImage: "tag")
                            .labelStyle(TagChipLabelStyle())
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(.tint.opacity(0.14), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Searching tag \(label.friendly)", comment: "VoiceOver: current tag search"))
                    Spacer(minLength: 0)
                } else {
                TextField(String(localized: "Search notes…", comment: "Search field placeholder"), text: Binding(
                    get: { vm.query },
                    set: { newValue in
                        let wasEmpty = vm.query.isEmpty
                        vm.query = newValue
                        vm.onQueryChanged()
                        if !wasEmpty, newValue.isEmpty {
                            isSearchFieldFocused = false
                        }
                    }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFieldFocused)
                .onSubmit { vm.searchNow() }
                .accessibilityLabel(String(localized: "Search notes", comment: "VoiceOver search field"))
                }

                if !vm.query.isEmpty {
                    Button {
                        vm.clearSearch()
                        isSearchFieldFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(String(localized: "Clear search", comment: "VoiceOver"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            // A Liquid Glass capsule, like the system search fields.
            .glassEffect(.regular.interactive(), in: .capsule)

            if !vm.query.isEmpty, vm.hasSearched {
                saveSearchButton(vm)
            }
        }
        .padding(.horizontal)
        // Beside the tree the field starts where the tree card does, right under the title.
        .padding(.top, horizontalSizeClass == .regular ? 0 : 16)
        .padding(.bottom, 4)
        .background(treeChromeBackground)
    }

    /// Keeps the current search in the sidebar, or takes it out again when it is already there.
    private func saveSearchButton(_ vm: SearchViewModel) -> some View {
        let isSaved = SavedSearches.list(for: appState.activeProfile, raw: savedSearchesRaw)
            .contains { $0.query == SavedSearches.normalized(vm.query) }
        return Button {
            if isSaved {
                if let profile = appState.activeProfile { SavedSearches.remove(query: vm.query, profile: profile) }
            } else {
                saveSearchName = LabelQuery.parse(vm.query)?.friendly ?? SavedSearches.normalized(vm.query)
                showsSaveSearch = true
            }
        } label: {
            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(isSaved
            ? String(localized: "Remove saved search", comment: "VoiceOver: search bookmark button")
            : String(localized: "Save search", comment: "VoiceOver: search bookmark button"))
    }

    /// Runs a search picked under Saved Searches in the sidebar.
    private func runPendingSavedSearch() {
        guard let query = appState.pendingSearchQuery, let vm = viewModel else { return }
        appState.pendingSearchQuery = nil
        vm.query = query
        vm.searchNow()
    }

    private func openNote(_ note: NoteItem, findQuery: String?, matchIndex1Based: Int?) {
        // Optionally deep-links into find-on-page at a specific match.
        stack.push(.note(NoteDestination(
            noteId: note.noteId,
            title: note.uiTitle(forProtectedSessionActive: appState.protectedSessionActive),
            findQuery: findQuery,
            findMatchIndex1Based: matchIndex1Based
        )))
    }

    private func resultsList(_ vm: SearchViewModel) -> some View {
        List {
            if vm.isOfflineResults {
                Section {
                    localResultsBanner(vm)
                        .listRowBackground(Color.orange.opacity(0.08))
                }
            }

            Section {
                ForEach(vm.results) { note in
                    searchResultSection(note: note, vm: vm)
                        .listRowBackground(listRowBackgroundColor)
                }
            } header: {
                Text(
                    vm.results.count == 1
                        ? String(localized: "1 result", comment: "Search results count")
                        : String(localized: "\(vm.results.count) results", comment: "Search results count")
                )
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(treeChromeBackground)
    }

    /// Why these results come from this device, and what they may be missing; Retry asks the server again.
    private func localResultsBanner(_ vm: SearchViewModel) -> some View {
        let lines = vm.localResultsDetails
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "icloud.slash")
                .font(.caption)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let first = lines.first {
                    Text(first)
                        .font(.caption)
                }
                ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if vm.localResultsCanRetryServer {
                Button(String(localized: "Retry", comment: "Retry search")) { vm.searchNow(forceServer: true) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .foregroundStyle(.orange)
    }

    private static let maxVisibleMatches = 20

    @ViewBuilder
    private func searchResultSection(note: NoteItem, vm: SearchViewModel) -> some View {
        let canExpand = note.type.supportsReadOnlyOnPageFind
        let expanded = vm.expandedMatchNoteIds.contains(note.noteId)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                if canExpand {
                    Button {
                        vm.toggleMatchExpansion(for: note)
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        expanded
                            ? String(localized: "Hide matches", comment: "Search result expand")
                            : String(localized: "Show matches", comment: "Search result expand")
                    )
                }

                Button {
                    openNote(note, findQuery: nil, matchIndex1Based: nil)
                } label: {
                    SearchResultRow(
                        note: note,
                        searchQuery: vm.query,
                        showTrailingChevron: true,
                        snippet: vm.snippetsByNoteId[note.noteId]
                    )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Drag a result into another app (or another Trinote window) as a link.
                .draggable(NoteDragItem(noteId: note.noteId, title: note.title))
            }

            if expanded && canExpand {
                matchExpansionContent(note: note, vm: vm)
            }
        }
        .environment(appState)
    }

    @ViewBuilder
    private func matchExpansionContent(note: NoteItem, vm: SearchViewModel) -> some View {
        let allMatches = vm.matchLines(for: note.noteId)
        let visibleMatches = Array(allMatches.prefix(Self.maxVisibleMatches))
        let hasMore = allMatches.count > Self.maxVisibleMatches

        if vm.loadingMatchNoteIds.contains(note.noteId) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "Loading matches…", comment: "Search expansion"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 30)
            .padding(.bottom, 8)
        } else if let err = vm.matchLoadErrorByNoteId[note.noteId],
                  allMatches.isEmpty {
            Text(err)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 30)
                .padding(.bottom, 8)
        }

        ForEach(visibleMatches) { match in
            Button {
                let q = vm.query.trimmingCharacters(in: .whitespacesAndNewlines)
                openNote(note, findQuery: q, matchIndex1Based: match.matchIndex1Based)
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Text("–")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    SearchMatchPreviewLine(text: match.previewLine, query: vm.query)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
                .padding(.leading, 30)
            }
            .buttonStyle(.plain)
        }

        if hasMore {
            HStack(spacing: 6) {
                Text("–")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(String(localized: "more references in note", comment: "Search match truncation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
            .padding(.vertical, 4)
            .padding(.leading, 30)
        }
    }

    /// A recent search: a tag search shows as its tag, anything else as typed.
    @ViewBuilder
    private func searchQueryLabel(_ query: String) -> some View {
        if let label = LabelQuery.parse(query) {
            Label(label.friendly, systemImage: "tag")
                .labelStyle(TagChipLabelStyle())
                .font(.body)
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(query)
        }
    }

    /// The labels used most across the notes; tapping one searches for it.
    @ViewBuilder
    private func labelCloud(_ vm: SearchViewModel) -> some View {
        let labels = appState.activeProfile.map {
            Array(LabelSuggester.vocabulary(serverProfileId: $0.id, context: PersistenceManager.shared.context)
                .filter { NoteLabelVisibility.isTag(name: $0.name, value: $0.value) }
                .prefix(24))
        } ?? []
        if !labels.isEmpty {
            VStack(spacing: 10) {
                Text(String(localized: "Quick search", comment: "Search: tag cloud title"))
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.trinoteTextSecondary)
                FlowLayout(spacing: 8, lineSpacing: 8, centersLines: true) {
                    ForEach(labels, id: \.self) { label in
                        Button {
                            vm.searchLabel(label)
                        } label: {
                            Label(label.friendly, systemImage: "tag")
                                .labelStyle(TagChipLabelStyle())
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(.tint.opacity(0.14), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Search label \(label.friendly)", comment: "VoiceOver: search notes with this label"))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentSearchesList(_ vm: SearchViewModel) -> some View {
        if vm.recentSearches.isEmpty {
            // Scrolls so a long tag cloud never runs into the title.
            ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(String(localized: "Search your notes", comment: "Search empty state title"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(String(localized: "Type to search by title, content, or attributes", comment: "Search empty state hint"))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                labelCloud(vm)
                    .padding(.top, 16)
            }
            .padding()
            .padding(.top, 48)
            }
            .scrollDismissesKeyboard(.interactively)
        } else {
            List {
                ForEach(vm.recentSearches, id: \.id) { search in
                    Button {
                        vm.selectRecentSearch(search)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                searchQueryLabel(search.query)
                                    .font(.body)
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                                Text(search.searchedAt.relativeDisplay)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.quaternary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(listRowBackgroundColor)
                }
                .onDelete { offsets in
                    vm.deleteRecentSearches(at: offsets)
                }
                Section {
                    labelCloud(vm)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(treeChromeBackground)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Text(String(localized: "Recent Searches", comment: "Search history section"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                    Spacer()
                    Button(String(localized: "Clear", comment: "Clear all recent searches")) {
                        vm.clearRecentSearches()
                    }
                    .font(.subheadline)
                    .accessibilityHint(String(localized: "Clears all recent searches", comment: "Clear recent searches accessibility hint"))
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity)
                .background(treeChromeBackground)
            }
        }
    }
}

// MARK: - Query highlight (titles + previews)

enum SearchQueryHighlight {
    static func attributedString(text: String, query: String) -> AttributedString {
        attributedString(text: text, terms: [query], options: [.caseInsensitive])
    }

    /// Highlights every term (offline results: each word or phrase of the query, ignoring case and accents as the
    /// offline index does).
    static func attributedString(
        text: String,
        terms: [String],
        options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    ) -> AttributedString {
        let mutable = NSMutableAttributedString(string: text)
        let nsText = text as NSString
        let len = nsText.length
        let bg = UIColor.systemYellow.withAlphaComponent(0.38)
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var loc = 0
            while loc < len {
                let r = nsText.range(of: trimmed, options: options, range: NSRange(location: loc, length: len - loc))
                if r.location == NSNotFound { break }
                mutable.addAttribute(.backgroundColor, value: bg, range: r)
                loc = r.location + max(r.length, 1)
            }
        }
        return AttributedString(mutable)
    }
}

struct SearchMatchPreviewLine: View {
    let text: String
    let query: String

    var body: some View {
        Text(SearchQueryHighlight.attributedString(text: text, query: query))
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }
}

struct SearchResultRow: View {
    let note: NoteItem
    /// Current search query; title matches are highlighted (case-insensitive).
    var searchQuery: String = ""
    var showTrailingChevron: Bool = true
    /// Trilium's snippet for this result (matched text and breadcrumb), when the server sent one.
    var snippet: SearchResultSnippet? = nil

    @Environment(AppState.self) private var appState
    @AppStorage("useTriliumNoteColors") private var useTriliumNoteColors: Bool = true

    private var displayTitle: String {
        note.uiTitle(forProtectedSessionActive: appState.protectedSessionActive)
    }

    private var titleHighlightQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Breadcrumb under root (same as Recents); empty when it would only repeat the title.
    private var pathDisplay: String {
        guard let profileId = appState.activeProfile?.id else { return "" }
        let pathFull = PersistenceManager.shared.cachedNotePathDisplay(
            noteId: note.noteId,
            leafTitle: note.title,
            leafIsProtected: note.isProtected,
            serverProfileId: profileId,
            protectedSessionActive: appState.protectedSessionActive
        )
        if pathFull != displayTitle { return pathFull }
        // Not in the local cache: the server's breadcrumb, which ends with the note's own title.
        guard let serverPath = snippet?.pathTitle, serverPath != displayTitle else { return "" }
        return serverPath
    }

    private var modifiedLabel: String? {
        let raw = note.dateModified.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return raw.triliumDate()?.relativeDisplay ?? raw
    }

    /// Trilium `#color` when enabled; suppressed for locked protected notes (matches Recents).
    private var triliumColor: Color? {
        guard useTriliumNoteColors else { return nil }
        if note.isProtected, !appState.protectedSessionActive { return nil }
        return TriliumNoteColorMapper.swiftUIColor(for: note.colorLabelValue)
    }

    @ViewBuilder
    private var titleView: some View {
        let color = triliumColor ?? Color.primary
        Group {
            if titleHighlightQuery.isEmpty {
                Text(displayTitle)
            } else {
                Text(SearchQueryHighlight.attributedString(text: displayTitle, query: titleHighlightQuery))
            }
        }
        .font(.body)
        .lineLimit(2)
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    private var effectiveIconClass: String? {
        let profileId = appState.activeProfile?.id
        if let resolved = NoteIconClassResolver.effectiveIconClass(
            noteId: note.noteId,
            ownIconClass: note.iconClass,
            templateRelationValue: note.templateRelationValue,
            parentNoteProvider: { parentId in
                guard let profileId else { return nil }
                return PersistenceManager.shared.parentNoteContextForIconWalk(
                    noteId: parentId,
                    serverProfileId: profileId
                )
            },
            templateIconClassProvider: { target in
                guard let profileId else {
                    return TriliumBuiltinTemplateIcons.iconClass(for: target)
                }
                return PersistenceManager.shared.cachedTemplateIconClass(
                    templateTarget: target,
                    serverProfileId: profileId
                )
            }
        ) {
            return resolved
        }
        guard let profileId else { return note.resolvedIconClass }
        return PersistenceManager.shared.cachedEffectiveNoteIconClass(noteId: note.noteId, serverProfileId: profileId)
            ?? note.resolvedIconClass
    }

    var body: some View {
        HStack(spacing: 12) {
            NoteIconView(
                iconClass: effectiveIconClass,
                fallbackNoteType: note.iconFallbackNoteType,
                size: .regular,
                foregroundStyle: triliumColor ?? .secondary
            )
            .frame(width: 24)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                titleView

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let modifiedLabel {
                        Text(modifiedLabel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if !pathDisplay.isEmpty {
                        Text(pathDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let content = snippet?.content {
                    Text(content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 2)
                }
                if let attribute = snippet?.attribute {
                    Text(attribute)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showTrailingChevron {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("\(displayTitle), \(note.uiNoteTypeDisplayName)")
    }
}

#Preview {
    NoteStackHost(stack: NoteStack()) {
        SearchView()
    }
    .environment(AppState())
    .modelContainer(PersistenceManager.shared.container)
}
