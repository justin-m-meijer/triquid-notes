import SwiftUI

struct RecentsView: View {
    @Environment(AppState.self) private var appState
    @Environment(NoteStack.self) private var stack
    @Environment(\.colorScheme) private var colorScheme
    /// Set in the iPad split layout: notes open in the note pane instead of being pushed here.
    @AppStorage("useTriliumNoteColors") private var useTriliumNoteColors: Bool = true
    /// Mirrors the tree's background settings so the Recents list shares the same chrome
    /// (in particular when the user has chosen a custom tree background colour).
    @AppStorage("useCustomTreeColors") private var useCustomTreeColors: Bool = false
    @AppStorage("treeLightBgColor") private var treeLightBgColor: String = "#F2F2F7"
    @AppStorage("treeDarkBgColor") private var treeDarkBgColor: String = "#1c1c1e"
    /// Opened (tracked on this device) or Edited (by last modification in the cache), redesign §3.
    @AppStorage("recentsSegment") private var segment: RecentsSegment = .opened
    @State private var recentNotes: [RecentsRow] = []
    /// Cached breadcrumb path per note (from SwiftData); empty string if unavailable.
    @State private var pathByNoteId: [String: String] = [:]
    /// Row title with protected-note masking (SwiftData may still hold decrypted titles after restart).
    @State private var displayTitleByNoteId: [String: String] = [:]
    /// Icon context for the top-level-under-root note (same visual grouping as tree).
    @State private var iconContextByNoteId: [String: NoteRowIconContext] = [:]
    /// Raw value of the leaf note's `#color` label (Trilium tree color), per note id.
    @State private var colorLabelByNoteId: [String: String] = [:]

    private var treeBgColor: Color? {
        guard useCustomTreeColors else { return nil }
        return colorScheme == .dark ? Color(hex: treeDarkBgColor) : Color(hex: treeLightBgColor)
    }

    /// Same fallback as `TreeView.treeChromeBackground` so both views land on the system grouped
    /// background when no custom colour is configured.
    private var treeChromeBackground: Color {
        treeBgColor ?? Color.trinoteGround
    }

    var body: some View {
        Group {
                List {
                    // The segments sit on the ground above the card, under the large title.
                    Section {
                        Picker(String(localized: "Show", comment: "Recents: segment picker"), selection: $segment) {
                            Text(String(localized: "Opened", comment: "Recents segment: notes opened on this device")).tag(RecentsSegment.opened)
                            Text(String(localized: "Edited", comment: "Recents segment: notes by last edit")).tag(RecentsSegment.edited)
                        }
                        .pickerStyle(.segmented)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                    Section {
                    ForEach(recentNotes, id: \.id) { recent in
                        Button {
                            let navTitle = displayTitleByNoteId[recent.noteId] ?? recent.title
                            stack.push(.note(NoteDestination(noteId: recent.noteId, title: navTitle)))
                        } label: {
                            HStack(spacing: 12) {
                                let rowIcon = recentsRowIcon(for: recent)
                                NoteIconView(
                                    iconClass: rowIcon.iconClass,
                                    fallbackNoteType: rowIcon.fallbackNoteType,
                                    size: .regular,
                                    foregroundStyle: resolvedIconColor(for: recent)
                                )
                                .frame(width: 24)
                                .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayTitleByNoteId[recent.noteId] ?? recent.title)
                                        .font(.body)
                                        .lineLimit(2)
                                        .foregroundStyle(resolvedTitleColor(for: recent))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .multilineTextAlignment(.leading)
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(recent.accessedAt.relativeDisplay)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                            .fixedSize(horizontal: true, vertical: false)
                                        if let path = pathByNoteId[recent.noteId], !path.isEmpty {
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

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.quaternary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .draggable(NoteDragItem(noteId: recent.noteId, title: displayTitleByNoteId[recent.noteId] ?? recent.title))
                        .listRowBackground(treeBgColor ?? Color.trinoteCard)
                        .listRowSeparatorTint(Color.trinoteSeparator)
                    }
                    }
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(.compact)
                .contentMargins(.top, 0, for: .scrollContent)
                .scrollContentBackground(.hidden)
                .background(treeChromeBackground)
                .overlay {
                    if recentNotes.isEmpty {
                        ContentUnavailableView {
                            Label(String(localized: "No Recent Notes", comment: "Recents empty"), systemImage: "clock")
                        } description: {
                            Text(segment == .opened
                                 ? String(localized: "Notes you open will appear here for quick access.", comment: "Recents empty hint")
                                 : String(localized: "Notes edited on any device appear here after a sync.", comment: "Recents: edited segment empty hint"))
                        }
                    }
                }
        }
        .widePageTitle(String(localized: "Recents", comment: "Recents tab title"), gapBelow: 1)
        .task(id: segment) { loadRecents() }
        .refreshable { loadRecents() }
        .onChange(of: appState.protectedSessionActive) { _, _ in loadRecents() }
        .onReceive(NotificationCenter.default.publisher(for: .trinoteRecentsMergedFromCloud)) { _ in loadRecents() }
        .navigationDestination(for: NoteRoute.self) { route in
            route.noteDestination?.makeDetailView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .trinoteWillSwitchServerProfile)) { _ in
            stack.popToLevel(0)
        }
    }

    private func loadRecents() {
        guard let profileId = appState.activeProfile?.id else { return }
        let pm = PersistenceManager.shared
        do {
            let raw: [RecentsRow] = switch segment {
            case .opened:
                try pm.fetchRecentNotes(serverProfileId: profileId).map {
                    RecentsRow(noteId: $0.noteId, title: $0.title, noteType: $0.noteType, accessedAt: $0.accessedAt)
                }
            case .edited:
                try pm.fetchRecentlyEditedNotes(serverProfileId: profileId).map {
                    RecentsRow(noteId: $0.noteId, title: $0.title, noteType: $0.noteType, accessedAt: Self.editedDate($0.utcDateModified))
                }
            }
            var paths: [String: String] = [:]
            var titlesOut: [String: String] = [:]
            var icons: [String: NoteRowIconContext] = [:]
            var colors: [String: String] = [:]
            var visible: [RecentsRow] = []
            visible.reserveCapacity(raw.count)
            paths.reserveCapacity(raw.count)
            icons.reserveCapacity(raw.count)
            colors.reserveCapacity(raw.count)

            for recent in raw {
                if GhostNoteTracker.shared.contains(recent.noteId, serverProfileId: profileId) {
                    continue
                }

                let leafProtected = (try? pm.fetchCachedNote(id: recent.noteId, serverProfileId: profileId))?.isProtected ?? false
                let rowTitle = NoteItem.maskedStoredTitle(
                    recent.title,
                    isProtected: leafProtected,
                    protectedSessionActive: appState.protectedSessionActive
                )

                let pathFull = pm.cachedNotePathDisplay(
                    noteId: recent.noteId,
                    leafTitle: recent.title,
                    leafIsProtected: leafProtected,
                    serverProfileId: profileId,
                    protectedSessionActive: appState.protectedSessionActive
                )
                // Avoid duplicating the title line when cache has no ancestors.
                let pathUI = (pathFull == rowTitle) ? "" : pathFull

                let hasCachedLeaf = (try? pm.fetchCachedNote(id: recent.noteId, serverProfileId: profileId)) != nil
                // Deleted / purged notes: no cache row and no breadcrumb trail — drop from list.
                if !hasCachedLeaf && pathUI.isEmpty {
                    continue
                }

                visible.append(recent)
                paths[recent.noteId] = pathUI
                titlesOut[recent.noteId] = rowTitle
                icons[recent.noteId] = pm.recentsRowIconContext(
                    noteId: recent.noteId,
                    fallbackNoteType: recent.noteType,
                    serverProfileId: profileId
                )
                if let colorRaw = pm.cachedNoteColorLabel(noteId: recent.noteId, serverProfileId: profileId) {
                    colors[recent.noteId] = colorRaw
                }
            }

            recentNotes = visible
            pathByNoteId = paths
            displayTitleByNoteId = titlesOut
            iconContextByNoteId = icons
            colorLabelByNoteId = colors
        } catch {
            Log.persistence.error("Failed to load recents: \(error)")
            recentNotes = []
            pathByNoteId = [:]
            displayTitleByNoteId = [:]
            iconContextByNoteId = [:]
            colorLabelByNoteId = [:]
        }
    }

    /// Trilium writes `utcDateModified` as "yyyy-MM-dd HH:mm:ss.SSSZ".
    private static func editedDate(_ raw: String?) -> Date {
        guard let raw else { return .distantPast }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss.SSSX", "yyyy-MM-dd HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ss.SSSX"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return .distantPast
    }

    private func recentsRowIcon(for recent: RecentsRow) -> NoteRowIconContext {
        if let ctx = iconContextByNoteId[recent.noteId] { return ctx }
        return NoteRowIconContext(
            iconClass: nil,
            fallbackNoteType: NoteType(rawValue: recent.noteType) ?? .text
        )
    }

    /// Trilium `#color` label wins when the global setting is on and the value is recognized.
    /// Suppressed for protected notes while the session is locked (so masked rows keep their muted look).
    private func triliumColor(for recent: RecentsRow) -> Color? {
        guard useTriliumNoteColors else { return nil }
        if let profileId = appState.activeProfile?.id,
           let cached = try? PersistenceManager.shared.fetchCachedNote(id: recent.noteId, serverProfileId: profileId),
           cached.isProtected,
           !appState.protectedSessionActive {
            return nil
        }
        return TriliumNoteColorMapper.swiftUIColor(for: colorLabelByNoteId[recent.noteId])
    }

    private func resolvedTitleColor(for recent: RecentsRow) -> Color {
        triliumColor(for: recent) ?? .trinoteTextPrimary
    }

    private func resolvedIconColor(for recent: RecentsRow) -> Color {
        triliumColor(for: recent) ?? .trinoteIcon
    }
}

enum RecentsSegment: String {
    case opened
    case edited
}

/// One row in either segment; `accessedAt` is the open time or the edit time.
private struct RecentsRow: Identifiable {
    var id: String { noteId }
    let noteId: String
    let title: String
    let noteType: String
    let accessedAt: Date
}

#Preview {
    NoteStackHost(stack: NoteStack()) {
        RecentsView()
    }
    .environment(AppState())
    .modelContainer(PersistenceManager.shared.container)
}
