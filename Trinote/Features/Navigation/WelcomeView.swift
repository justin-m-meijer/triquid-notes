import SwiftUI

/// Fills the detail column of the split layout while no note is open: shortcuts the user picks
/// (recent notes, favorites) as cards, opened beside the tree.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(NoteStack.self) private var stack
    /// Opens a smart folder (the to-do list) in the note column.
    var onShowList: (NoteListSource) -> Void = { _ in }
    /// Bumped after a sync (as for the sidebar), so to-dos and recents reload with the new notes.
    var refreshToken = 0
    @Environment(\.titleBesideBar) private var titleBesideBar
    @AppStorage(WelcomeSection.orderKey) private var sectionOrder = ""
    @AppStorage("welcomeShowsRecents") private var showsRecents = true
    @AppStorage("welcomeRecentsCount") private var recentsCount = 5
    @AppStorage("welcomeShowsFavorites") private var showsFavorites = true
    @AppStorage("welcomeShowsCapture") private var showsCapture = true
    @AppStorage("welcomeShowsTodos") private var showsTodos = true
    @AppStorage("welcomeShowsTips") private var showsTips = true

    @State private var recents: [WelcomeNoteCard] = []
    @State private var favorites: [WelcomeNoteCard] = []
    @State private var todos: [WelcomeNoteCard] = []
    @State private var todoTotal = 0
    @State private var capture: CaptureKind?
    @State private var isProcessingScan = false
    @State private var captureError: String?

    static let recentsCountChoices = [3, 5, 10]
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header

                // In the order chosen in Settings › Home Screen (synced through iCloud).
                ForEach(WelcomeSection.ordered(sectionOrder)) { kind in
                    sectionView(kind)
                }
                if !showsTips && !showsCapture && !showsTodos && !showsRecents && !showsFavorites {
                    ContentUnavailableView(
                        String(localized: "Nothing to show", comment: "Welcome screen: all sections hidden"),
                        systemImage: "slider.horizontal.3",
                        description: Text(String(localized: "Choose what to show in Settings › Home Screen.", comment: "Welcome screen: all sections hidden hint"))
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 28)
            // The greeting lines up with the large notebook title beside it; on the unfolded Duo
            // with the bar's buttons, where the bar sits high above it.
            .padding(.top, titleBesideBar ? 22 : 0)
            .padding(.bottom, 24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .ignoresSafeArea(.container, edges: titleBesideBar ? .top : [])
        .background(Color.trinoteGround)
        // The same compact bar as Recents, Favorites and Search beside the tree (see widePageTitle).
        .toolbarTitleDisplayMode(.inline)
        .task(id: loadKey) {
            load()
            await loadTodos()
        }
        .fullScreenCover(item: $capture) { kind in
            switch kind {
            case .photo:
                PhotoCaptureView(
                    onCapture: { image in
                        capture = nil
                        do { try QuickCapture.stagePhoto(image, appState: appState) } catch { captureError = error.localizedDescription }
                    },
                    onCancel: { capture = nil }
                )
                .ignoresSafeArea()
            case .scan:
                DocumentScanView(
                    onScan: { pages in
                        capture = nil
                        isProcessingScan = true
                        Task {
                            defer { isProcessingScan = false }
                            do { try await QuickCapture.stageScan(pages, appState: appState) } catch { captureError = error.localizedDescription }
                        }
                    },
                    onCancel: { capture = nil }
                )
                .ignoresSafeArea()
            }
        }
        .overlay {
            if isProcessingScan {
                ProgressView(String(localized: "Recognizing text…", comment: "Quick capture: OCR in progress"))
                    .padding(24)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
        .alert(
            String(localized: "Capture Failed", comment: "Quick capture error title"),
            isPresented: Binding(get: { captureError != nil }, set: { if !$0 { captureError = nil } }),
            actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
            message: { Text(captureError ?? "") }
        )
    }

    @ViewBuilder
    private func sectionView(_ kind: WelcomeSection) -> some View {
        switch kind {
        case .tips:
            if showsTips { tipsCard }
        case .capture:
            if showsCapture { captureButtons }
        case .todos:
            if showsTodos {
                section(
                    title: String(localized: "Todo", comment: "Welcome screen: notes with open to-dos section"),
                    systemImage: "checklist",
                    cards: todos,
                    emptyText: String(localized: "Notes with open to-dos appear here.", comment: "Welcome screen: no open to-dos"),
                    showAll: todoTotal > todos.count ? { onShowList(.todo) } : nil
                )
            }
        case .recents:
            if showsRecents {
                section(
                    title: String(localized: "Recent", comment: "Welcome screen: recent notes section"),
                    systemImage: "clock",
                    cards: recents,
                    emptyText: String(localized: "Notes you open appear here.", comment: "Welcome screen: no recent notes")
                )
            }
        case .favorites:
            if showsFavorites {
                section(
                    title: String(localized: "Favorites", comment: "Welcome screen: favorites section"),
                    systemImage: "star",
                    cards: favorites,
                    emptyText: String(localized: "Mark a note as a favorite to keep it here.", comment: "Welcome screen: no favorites")
                )
            }
        }
    }

    // MARK: - Capture

    private enum CaptureKind: String, Identifiable {
        case photo
        case scan
        var id: String { rawValue }
    }

    private var captureButtons: some View {
        HStack(spacing: 14) {
            captureButton(
                title: String(localized: "Photo", comment: "Welcome screen: take a photo into a new note"),
                subtitle: String(localized: "Into a new note", comment: "Welcome screen: photo button subtitle"),
                systemImage: "camera.fill",
                tint: .orange,
                isAvailable: QuickCapture.canTakePhoto
            ) { capture = .photo }
            captureButton(
                title: String(localized: "Scan", comment: "Welcome screen: scan a document into a new note"),
                subtitle: String(localized: "PDF with searchable text", comment: "Welcome screen: scan button subtitle"),
                systemImage: "doc.viewfinder.fill",
                tint: .teal,
                isAvailable: QuickCapture.canScan
            ) { capture = .scan }
        }
        .disabled(isProcessingScan)
    }

    private func captureButton(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        isAvailable: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(tint.gradient, in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(isAvailable ? subtitle : String(localized: "No camera on this device", comment: "Welcome screen: capture unavailable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(Color.trinoteCard, in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(WelcomeCardButtonStyle())
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.55)
    }

    // MARK: - Header

    private var header: some View {
        // The greeting first, then the date; where the notes live is under the note list.
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .headingFont(34)
                .foregroundStyle(Color.trinoteTextPrimary)
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: String(localized: "Good morning", comment: "Welcome screen greeting")
        case 12..<18: String(localized: "Good afternoon", comment: "Welcome screen greeting")
        default: String(localized: "Good evening", comment: "Welcome screen greeting")
        }
    }

    // MARK: - Tips

    private struct Tip: Identifiable {
        let id: Int
        let systemImage: String
        let tint: Color
        let title: String
        let detail: String
    }

    private var tips: [Tip] {
        [
            Tip(id: 0, systemImage: "apple.intelligence", tint: .purple,
                title: String(localized: "Summarize a note", comment: "Welcome tip title"),
                detail: String(localized: "Apple Intelligence sums up a note on this device, in your language.", comment: "Welcome tip detail")),
            Tip(id: 1, systemImage: "hand.draw", tint: .blue,
                title: String(localized: "Drag to organize", comment: "Welcome tip title"),
                detail: String(localized: "Drag a notebook onto the top or bottom of another to put it there, or onto the middle to move it inside.", comment: "Welcome tip detail")),
            Tip(id: 2, systemImage: "arrow.up.and.down.text.horizontal", tint: .orange,
                title: String(localized: "Your own order", comment: "Welcome tip title"),
                detail: String(localized: "The order is kept in Trilium, so it’s the same on all your devices and in Trilium itself.", comment: "Welcome tip detail")),
            Tip(id: 3, systemImage: "folder", tint: .teal,
                title: String(localized: "Move from anywhere", comment: "Welcome tip title"),
                detail: String(localized: "Long-press any note, in a list or under a note, and choose Move.", comment: "Welcome tip detail")),
        ]
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(String(localized: "What's new", comment: "Welcome screen: tips about recent features"), systemImage: "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.trinoteTextPrimary)
                Spacer()
                Button {
                    withAnimation { showsTips = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.trinoteGround, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Hide tips", comment: "Welcome screen: hide the tips card"))
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(tips) { tip in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: tip.systemImage)
                            .font(.title3)
                            .foregroundStyle(tip.tint)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tip.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.trinoteTextPrimary)
                            Text(tip.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(18)
        .background(Color.trinoteCard, in: .rect(cornerRadius: 16))
    }

    // MARK: - Sections

    private func section(
        title: String,
        systemImage: String,
        cards: [WelcomeNoteCard],
        emptyText: String,
        showAll: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.trinoteTextPrimary)
                Spacer()
                if let showAll {
                    Button(String(localized: "Show all", comment: "Welcome screen: open the full list of a section"), action: showAll)
                        .font(.callout.weight(.medium))
                }
            }
            if cards.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Color.trinoteCard, in: .rect(cornerRadius: 16))
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(cards) { card in
                        Button { open(card) } label: { cardView(card) }
                            .buttonStyle(WelcomeCardButtonStyle())
                    }
                }
            }
        }
    }

    private func cardView(_ card: WelcomeNoteCard) -> some View {
        HStack(alignment: .center, spacing: 12) {
            NoteIconView(iconClass: card.icon.iconClass, fallbackNoteType: card.icon.fallbackNoteType, foregroundStyle: .accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.headline)
                    .foregroundStyle(Color.trinoteTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !card.path.isEmpty {
                // Parent notes, root first: "Projects › Alpha › Spec".
                    Text(card.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.bottom, 2)
                }
                if let accessedAt = card.accessedAt {
                    Text(accessedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        // One height for every card, so rows line up whatever a card has to say: room for a
        // two-line title, the path and the time. A minimum alone let long titles grow the card.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 118)
        .background(Color.trinoteCard, in: .rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
    }

    // MARK: - Data

    private struct LoadKey: Equatable {
        let profileId: String?
        let recentsCount: Int
        let protectedSessionActive: Bool
        let refreshToken: Int
    }

    private var loadKey: LoadKey {
        LoadKey(
            profileId: appState.activeProfile?.id,
            recentsCount: recentsCount,
            protectedSessionActive: appState.protectedSessionActive,
            refreshToken: refreshToken
        )
    }

    private func open(_ card: WelcomeNoteCard) {
        stack.push(.note(NoteDestination(noteId: card.noteId, title: card.title)), fromLevel: stack.subtreePath.count)
    }

    private func load() {
        guard let profileId = appState.activeProfile?.id else {
            recents = []
            favorites = []
            return
        }
        let pm = PersistenceManager.shared
        let recentRows = (try? pm.fetchRecentNotes(serverProfileId: profileId)) ?? []
        recents = Array(recentRows.lazy.compactMap {
            makeCard(noteId: $0.noteId, storedTitle: $0.title, noteType: $0.noteType, accessedAt: $0.accessedAt,
                     profileId: profileId, dropWhenUncached: true)
        }.prefix(recentsCount))
        let favoriteRows = (try? pm.fetchFavorites(serverProfileId: profileId)) ?? []
        favorites = favoriteRows.compactMap {
            makeCard(noteId: $0.noteId, storedTitle: $0.title, noteType: $0.noteType, accessedAt: nil,
                     profileId: profileId, dropWhenUncached: false)
        }
    }

    /// Notes with open to-dos, read off the main thread like the Todo list.
    private func loadTodos() async {
        guard let profileId = appState.activeProfile?.id else {
            todos = []
            todoTotal = 0
            return
        }
        let loader = await NoteListLoader.background(PersistenceManager.shared.container)
        guard let summary = try? await loader.todoSummary(profileId: profileId, limit: Self.todoLimit) else { return }
        todoTotal = summary.total
        todos = summary.rows.compactMap {
            makeCard(noteId: $0.noteId, storedTitle: $0.title, noteType: $0.noteType, accessedAt: $0.modified,
                     profileId: profileId, dropWhenUncached: false)
        }
    }

    private static let todoLimit = 4

    /// Same masking and filtering as the Recents tab: protected titles stay masked while the
    /// session is locked; deleted notes (no cache row, no breadcrumb) are left out of recents.
    private func makeCard(
        noteId: String,
        storedTitle: String,
        noteType: String,
        accessedAt: Date?,
        profileId: String,
        dropWhenUncached: Bool
    ) -> WelcomeNoteCard? {
        let pm = PersistenceManager.shared
        if GhostNoteTracker.shared.contains(noteId, serverProfileId: profileId) { return nil }
        let cached = try? pm.fetchCachedNote(id: noteId, serverProfileId: profileId)
        let isProtected = cached?.isProtected ?? false
        let title = NoteItem.maskedStoredTitle(storedTitle, isProtected: isProtected, protectedSessionActive: appState.protectedSessionActive)
        let fullPath = pm.cachedNotePathDisplay(
            noteId: noteId,
            leafTitle: storedTitle,
            leafIsProtected: isProtected,
            serverProfileId: profileId,
            protectedSessionActive: appState.protectedSessionActive
        )
        // The breadcrumb ends with the note itself; the card already shows that as its title.
        var crumbs = fullPath.components(separatedBy: " -> ")
        if crumbs.count > 1 { crumbs.removeLast() } else { crumbs = [] }
        let path = crumbs.joined(separator: " › ")
        if dropWhenUncached, cached == nil, fullPath == title { return nil }
        return WelcomeNoteCard(
            noteId: noteId,
            title: title,
            path: path,
            accessedAt: accessedAt,
            icon: NoteRowIconContext(
                iconClass: pm.cachedNoteIconClass(noteId: noteId, serverProfileId: profileId),
                fallbackNoteType: NoteType(rawValue: cached?.noteType ?? noteType) ?? .text
            )
        )
    }
}

private struct WelcomeNoteCard: Identifiable {
    var id: String { noteId }
    let noteId: String
    let title: String
    let path: String
    let accessedAt: Date?
    let icon: NoteRowIconContext
}

/// A light press state for cards, so they feel tappable without looking like system buttons.
private struct WelcomeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// The home screen's sections, in the order the person arranges them.
enum WelcomeSection: String, CaseIterable, Identifiable {
    case tips, capture, todos, recents, favorites

    static let orderKey = "welcomeSectionOrder"
    var id: String { rawValue }

    /// The stored order (comma-separated), with sections it does not mention appended, so a
    /// section added later still shows.
    static func ordered(_ stored: String) -> [WelcomeSection] {
        var result: [WelcomeSection] = []
        for name in stored.split(separator: ",") {
            if let kind = WelcomeSection(rawValue: String(name)), !result.contains(kind) { result.append(kind) }
        }
        for kind in allCases where !result.contains(kind) { result.append(kind) }
        return result
    }

    static func storage(_ order: [WelcomeSection]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }

    var title: String {
        switch self {
        case .tips: String(localized: "What's new", comment: "Welcome screen menu")
        case .capture: String(localized: "Photo and scan", comment: "Welcome screen menu")
        case .todos: String(localized: "Todo", comment: "Welcome screen menu")
        case .recents: String(localized: "Recent notes", comment: "Welcome screen menu")
        case .favorites: String(localized: "Favorites", comment: "Welcome screen menu")
        }
    }

    var systemImage: String {
        switch self {
        case .tips: "sparkles"
        case .capture: "camera"
        case .todos: "checklist"
        case .recents: "clock"
        case .favorites: "star"
        }
    }

    /// The AppStorage key of the section's on/off switch.
    var visibilityKey: String {
        switch self {
        case .tips: "welcomeShowsTips"
        case .capture: "welcomeShowsCapture"
        case .todos: "welcomeShowsTodos"
        case .recents: "welcomeShowsRecents"
        case .favorites: "welcomeShowsFavorites"
        }
    }
}

/// What the home screen beside the menu shows (iPad, Mac, the unfolded Duo), and in which order:
/// drag the handles to reorder. It lived in a menu in that screen's bar; in Settings the bar stays
/// free (TestFlight feedback). Order and switches sync through iCloud with the other settings.
struct HomeScreenSettingsView: View {
    @AppStorage(WelcomeSection.orderKey) private var sectionOrder = ""
    @AppStorage("welcomeRecentsCount") private var recentsCount = 5
    @AppStorage("welcomeShowsRecents") private var showsRecents = true

    var body: some View {
        // Styled like the other Settings pages, so it takes the theme's tinted surfaces.
        List {
            Section {
                ForEach(WelcomeSection.ordered(sectionOrder)) { kind in
                    SectionToggle(kind: kind)
                }
                .onMove { source, destination in
                    var order = WelcomeSection.ordered(sectionOrder)
                    order.move(fromOffsets: source, toOffset: destination)
                    sectionOrder = WelcomeSection.storage(order)
                }
            } footer: {
                Text(String(localized: "The page beside the menu on iPad, Mac and an unfolded iPhone Duo, while no note is open. Drag to change the order.", comment: "Settings: home screen footer"))
            }
            .listRowBackground(Color.trinoteCard)
            Section {
                Picker(String(localized: "Number of recent notes", comment: "Welcome screen menu"), selection: $recentsCount) {
                    ForEach(WelcomeView.recentsCountChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                .disabled(!showsRecents)
            }
            .listRowBackground(Color.trinoteCard)
        }
        // Reorder handles always showing, as in the system's own reorderable settings.
        .environment(\.editMode, .constant(.active))
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.trinoteGround)
        .navigationTitle(String(localized: "Home Screen", comment: "Settings page: what the home screen shows"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct SectionToggle: View {
        let kind: WelcomeSection
        @AppStorage private var isOn: Bool

        init(kind: WelcomeSection) {
            self.kind = kind
            _isOn = AppStorage(wrappedValue: true, kind.visibilityKey)
        }

        var body: some View {
            Toggle(isOn: $isOn) {
                Label(kind.title, systemImage: kind.systemImage)
            }
        }
    }
}
