import SwiftUI
import UIKit

/// The signed-in app (v2 redesign): sidebar → note list → note. One stack starting at the sidebar;
/// where there is room (iPad, unfolded iPhone Duo held landscape, Mac) the note sits beside that
/// stack in a second column, as in the handoff's split layout.
struct MainShellView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.displayScale) private var displayScale

    @State private var selection: SidebarItem? = .list(.allNotes)
    /// The open note (`NoteDestination`), shared with every view that opens notes: the second column
    /// on wide layouts, the top of the stack on a phone.
    @State private var noteStack = NoteStack()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The hand-laid sidebar (unfolded Duo) folded away with its hide button.
    @State private var handSidebarHidden = {
        #if DEBUG
        // `-TrinoteDebugHideSidebar YES`: start with the hand-laid menu folded away (Duo checks).
        return UserDefaults.standard.bool(forKey: "TrinoteDebugHideSidebar")
        #else
        return false
        #endif
    }()
    /// The screens pushed over the sidebar (a list, folders, search, settings). On a phone the open
    /// note goes on top of them; wide, it is in the other column.
    @State private var compactScreens: [CompactScreen] = []
    /// iPad and Mac: Settings fills the note column, so the sidebar stays beside it.
    @State private var settingsInDetail = false
    @State private var settingsPath = NavigationPath()
    /// iPad and Mac: a smart folder or search in the note column (its root first, then folders
    /// opened from it); a note opened there goes on top, with back to the list.
    @State private var detailScreens: [CompactScreen] = []
    /// Reloads the sidebar and the lists: after a sync, a new note or a shared import.
    @State private var refreshToken = 0

    @State private var showQuickCapture = false
    @State private var showScanner = false
    @State private var isProcessingScan = false
    @State private var scanError: String?
    @State private var postureMonitor = PostureMonitor()
    private let quickActions = QuickActionRouter.shared

    /// Recreates the columns when the active server changes, so no view keeps the old server's notes.
    private var instanceId: String {
        "\(appState.activeProfile?.id ?? "none")-\(appState.tabNavigationResetGeneration)"
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactStack
            } else {
                columns
            }
        }
        .id(instanceId)
        .environment(noteStack)
        .environment(\.isSplitNoteLayout, horizontalSizeClass == .regular)
        .environment(\.postureMonitor, postureMonitor)
        .background {
            HingeObserver(monitor: postureMonitor)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .background(Color.trinoteGround.ignoresSafeArea())
        .modifier(SoftScrollEdgeOnMac())
        // A note opened from anywhere takes the note column back from Settings.
        .onChange(of: noteStack.topNoteDestination?.routeId) { _, routeId in
            if routeId != nil {
                settingsInDetail = false
                settingsPath = NavigationPath()
            }
        }
        .onChange(of: appState.syncManager.isSyncing) { wasSyncing, isSyncing in
            if wasSyncing, !isSyncing {
                refreshToken += 1
                refreshSpotlightIndex()
            }
        }
        .task(id: appState.activeProfile?.id) { refreshSpotlightIndex() }
        .focusedSceneValue(\.mainWindowActions, MainWindowActions(
            show: { item in choose(item) },
            newNote: { showQuickCapture = true },
            syncNow: { Task { await SyncStatusSummary.syncNow(appState: appState) } }
        ))
        .sheet(isPresented: $showQuickCapture) {
            QuickCaptureSheet(onOpenInEditor: { noteId, title in
                noteStack.closeNote()
                noteStack.push(.note(NoteDestination(noteId: noteId, title: title, startInEditMode: true)))
            }, sharedFile: appState.shareImport.quickCaptureFile)
            .environment(appState)
            .onDisappear {
                // Closed without saving: drop the shared file rather than offer it again.
                if appState.shareImport.quickCaptureFile != nil { appState.shareImport.discardQuickCaptureFile() }
                refreshToken += 1
            }
        }
        // A file shared to the app (share sheet, scan) opens Quick capture with the file attached.
        .onChange(of: appState.shareImport.quickCaptureFile != nil, initial: true) { _, hasFile in
            if hasFile { showQuickCapture = true }
        }
        .modifier(MainShellModifiers(onShareImportActivated: {}))
        .onChange(of: appState.shareImport.pendingOpenNote) { _, pending in
            guard let pending else { return }
            noteStack.closeNote()
            noteStack.push(.note(NoteDestination(
                noteId: pending.noteId,
                title: pending.title,
                startInEditMode: true,
                attachmentIdToInsert: pending.attachmentIdToInsert,
                attachmentTitleToInsert: pending.attachmentTitleToInsert
            )))
            appState.shareImport.consumePendingOpenNote()
            refreshToken += 1
        }
        .onChange(of: appState.pendingNoteLink) { _, link in
            guard let link else { return }
            appState.pendingNoteLink = nil
            open(link)
        }
        .onChange(of: quickActions.pending, initial: true) { _, request in
            guard let request else { return }
            quickActions.pending = nil
            switch request.action {
            case .newNote: showQuickCapture = true
            case .scanDocument: showScanner = QuickCapture.canScan
            }
        }
        .onChange(of: quickActions.pendingNote, initial: true) { _, link in
            guard let link else { return }
            quickActions.pendingNote = nil
            open(link)
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanView(
                onScan: { pages in
                    showScanner = false
                    isProcessingScan = true
                    Task {
                        defer { isProcessingScan = false }
                        // Staged like a share: the import flow asks where to file it and opens the note.
                        do { try await QuickCapture.stageScan(pages, appState: appState) } catch { scanError = error.localizedDescription }
                    }
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
        .overlay {
            if isProcessingScan {
                ProgressView(String(localized: "Recognizing text…", comment: "Quick capture: OCR in progress"))
                    .padding(24)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
        .alert(
            String(localized: "Scan Not Saved", comment: "Scan intent: staging failed"),
            isPresented: Binding(get: { scanError != nil }, set: { if !$0 { scanError = nil } }),
            actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
            message: { Text(scanError ?? "") }
        )
        .task {
            // A link that arrived before this view existed (cold launch from Spotlight or a URL).
            if let link = appState.pendingNoteLink {
                appState.pendingNoteLink = nil
                open(link)
            }
            #if DEBUG
            // `-TrinoteDebugOpenNote <noteId>`: open a note at launch, for UI checks and screenshots.
            if let noteId = UserDefaults.standard.string(forKey: "TrinoteDebugOpenNote") {
                try? await Task.sleep(for: .seconds(1))
                open(NoteLink(noteId: noteId))
                // `-TrinoteDebugPageDown <n>`: then scroll the note down n pages.
                let pages = UserDefaults.standard.integer(forKey: "TrinoteDebugPageDown")
                for _ in 0..<pages {
                    try? await Task.sleep(for: .seconds(1.5))
                    NotificationCenter.default.post(name: .trinoteReaderPageRequest, object: TabletopPageDirection.down)
                }
            }
            // `-TrinoteDebugShow settings|search|allNotes|inbox|today|todo|favorites|recents`.
            if let item = UserDefaults.standard.string(forKey: "TrinoteDebugShow") {
                let map: [String: SidebarItem] = [
                    "settings": .settings, "search": .search, "allNotes": .list(.allNotes), "inbox": .list(.inbox),
                    "today": .list(.today), "todo": .list(.todo), "favorites": .list(.favorites), "recents": .list(.recents),
                ]
                if let target = map[item] { choose(target) }
            }
            // `-TrinoteDebugNotebook <notebook noteId>`: show a notebook's list at launch.
            if let noteId = UserDefaults.standard.string(forKey: "TrinoteDebugNotebook") {
                let title = appState.activeProfile.flatMap { try? PersistenceManager.shared.fetchCachedNote(id: noteId, serverProfileId: $0.id)?.title } ?? ""
                choose(.list(.notebook(noteId: noteId, title: title)))
            }
            #endif
        }
    }

    // MARK: - Columns

    /// iPad, Mac and the unfolded Duo: the sidebar stack (sidebar → list → folders) beside the note.
    @ViewBuilder
    private var columns: some View {
        if let sidebarWidth = fixedSidebarWidth {
            // The unfolded Duo: a split view turns its sidebar into an overlay at these widths
            // (TestFlight feedback). The menu stays put on the left third, the note beside it.
            HStack(spacing: 0) {
                if !handSidebarHidden {
                    // No stack of its own: everything the sidebar opens goes to the note column,
                    // and a stack's (hidden) bar kept its height, so the header's buttons sat
                    // ~60 pt below the note's bar (TestFlight feedback).
                    sidebar
                        .environment(\.sidebarActionsInHeader, true)
                        .environment(\.sidebarHideAction, {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { handSidebarHidden = true }
                        })
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .leading))
                    Rectangle()
                        .fill(Color.trinoteSeparator)
                        .frame(width: 1 / displayScale)
                        .ignoresSafeArea()
                }
                detailColumn
                    .frame(maxWidth: .infinity)
                    // With the menu folded away, a round button bottom left brings it back, a
                    // mirror of the compose button: a column of its own pushed the note off
                    // centre, and top left it would cover a back button (TestFlight feedback).
                    // Where iOS puts the bar's buttons down the side (sideways), it joins them in
                    // that strip above the compose button, like every floating button there.
                    // Upright it sits in the bar with the screen's own buttons (TestFlight feedback).
                    .overlay(alignment: .bottomTrailing) {
                        if handSidebarHidden, postureMonitor.geometry.barsAtSide {
                            showSidebarButton
                                .padding(.trailing, 16)
                                .padding(.bottom, 12 + 52 + 14)
                                .intoSideStrip(trailingPadding: 16, width: 52)
                                .transition(.opacity)
                        }
                    }
                    // The page titles move up level with the bar's buttons: in this tall window
                    // the bar sits high and left a gap above them (TestFlight feedback).
                    .environment(\.titleBesideBar, true)
            }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarColumn
                    .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
            } detail: {
                detailColumn
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    /// Brings the hand-laid menu back from the note column's bar, upright on the unfolded Duo.
    private var showSidebarInBar: (() -> Void)? {
        guard fixedSidebarWidth != nil, handSidebarHidden, !postureMonitor.geometry.barsAtSide else { return nil }
        return { withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { handSidebarHidden = false } }
    }

    private var showSidebarButton: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { handSidebarHidden = false }
        } label: {
            Label(String(localized: "Show Sidebar", comment: "Unfolded Duo: bring the menu column back"), systemImage: "sidebar.left")
                .labelStyle(.iconOnly)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 52, height: 52)
        }
        .glassEffect(.regular.interactive(), in: .circle)
    }

    /// The sidebar's width when it is laid out by hand (the unfolded Duo): a third of the window.
    /// Nil where the split view does (iPad, Mac).
    private var fixedSidebarWidth: CGFloat? {
        // A third of the window held either way, as Apple's own apps do on the unfolded Duo
        // (Settings: ~320 pt of 951 sideways). Ending on the fold left the note half the screen
        // (TestFlight feedback).
        // Half open like a book, the menu takes the page before the fold: 50/50 on the hinge.
        if postureMonitor.posture == .book, let hinge = postureMonitor.sidebarWidthAtHinge { return hinge }
        let width = postureMonitor.geometry.windowSize.width
        guard width > 0, width < 760 || postureMonitor.sidebarWidthAtHinge != nil else { return nil }
        return (width / 3).rounded()
    }

    private var sidebarColumn: some View {
        NavigationStack(path: $compactScreens) {
            sidebar
                .navigationDestination(for: CompactScreen.self) { screen in
                    screenView(screen)
                }
        }
    }

    private var detailColumn: some View {
        Group {
            // Settings gets a stack of its own, a separate branch: its pages (Theme & accent) are
            // pushed with plain links, and in one shared stack they stayed on top of a note opened
            // from the sidebar afterwards.
            if settingsInDetail {
                NavigationStack(path: $settingsPath) {
                    SettingsView()
                        .environment(\.settingsPagesByValue, true)
                        .containerBackground(Color(uiColor: .trinoteEditorCanvas), for: .navigation)
                }
            } else {
                // One stack for lists and notes: replacing one stack with another went through black.
                NavigationStack(path: detailPath) {
                    detailRoot
                        .containerBackground(Color(uiColor: .trinoteEditorCanvas), for: .navigation)
                        .modifier(ShowSidebarToolbarItem(action: showSidebarInBar))
                        .navigationDestination(for: CompactScreen.self) { screen in
                            screenView(screen)
                                .modifier(ShowSidebarToolbarItem(action: showSidebarInBar))
                        }
                }
            }
        }
        // While one screen replaces another (a list for a note) the column showed black for a
        // moment; the palette's canvas sits behind all of them.
        .background(Color(uiColor: .trinoteEditorCanvas).ignoresSafeArea())
    }

    /// A phone (and the Duo's cover display): one stack from the sidebar, so back always goes to
    /// the screen before. A collapsed three-column view put the list column between the sidebar
    /// and every note, which showed up (and jumped) on the way back.
    private var compactStack: some View {
        NavigationStack(path: compactPath) {
            sidebar
                .navigationDestination(for: CompactScreen.self) { screen in
                    screenView(screen)
                }
        }
    }

    @ViewBuilder
    private func screenView(_ screen: CompactScreen) -> some View {
        switch screen {
        case .list(let source): noteList(source)
        case .search: SearchView()
        case .settings: SettingsView()
        case .note(let note): note.makeDetailView()
        }
    }

    /// What the note column's stack starts with: a smart folder or search, else the open note, else
    /// the welcome screen with the compose button.
    @ViewBuilder
    private var detailRoot: some View {
        if let root = detailScreens.first {
            screenView(root)
        } else if let note = noteStack.topNoteDestination {
            note.makeDetailView()
        } else {
            WelcomeView(onShowList: { choose(.list($0)) }, refreshToken: refreshToken)
                .overlay(alignment: .bottomTrailing) {
                    FloatingComposeButton(
                        tint: .accentColor,
                        accessibilityLabel: String(localized: "New note", comment: "Tab bar: quick capture button")
                    ) { showQuickCapture = true }
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .intoSideStrip(trailingPadding: 16, width: 52)
                }
        }
    }

    /// The note column's stack under a list: folders opened from it, then the open note. Going back
    /// past the note closes it.
    private var detailPath: Binding<[CompactScreen]> {
        Binding(
            // Without a list the note is the root itself, not pushed.
            get: {
                guard !detailScreens.isEmpty else { return [] }
                return Array(detailScreens.dropFirst()) + (noteStack.topNoteDestination.map { [.note($0)] } ?? [])
            },
            set: { path in
                guard !detailScreens.isEmpty else { return }
                let screens = path.filter { !$0.isNote }
                if !path.contains(where: \.isNote), noteStack.topNoteDestination != nil {
                    noteStack.closeNote()
                }
                let updated = Array(detailScreens.prefix(1)) + screens
                if updated != detailScreens { detailScreens = updated }
            }
        )
    }

    /// `compactScreens` with the open note on top. Going back past the note closes it.
    private var compactPath: Binding<[CompactScreen]> {
        Binding(
            get: { compactScreens + (noteStack.topNoteDestination.map { [.note($0)] } ?? []) },
            set: { path in
                let screens = path.filter { !$0.isNote }
                if !path.contains(where: \.isNote), noteStack.topNoteDestination != nil {
                    noteStack.closeNote()
                }
                if screens != compactScreens { compactScreens = screens }
            }
        )
    }

    private var sidebar: some View {
        SidebarView(selection: $selection, onChoose: {
            guard let selection else { return }
            choose(selection)
        }, refreshToken: refreshToken,
        // The sidebar's compose button only shows with the sidebar itself; a pushed list has its own.
        // Wide, compose lives once, in the note column (TestFlight feedback); a phone keeps it here.
        onQuickCapture: horizontalSizeClass == .compact ? { showQuickCapture = true } : nil,
        onOpenNote: { noteId, _ in
            // A note opened in the sidebar sits right on the sidebar: back returns there (phone), and
            // wide the sidebar stays put beside it.
            compactScreens = []
            // Wide: a note from the sidebar fills the note column on its own.
            detailScreens = []
            open(NoteLink(noteId: noteId))
        })
        .environment(\.sidebarHomeAction, horizontalSizeClass == .compact ? nil : { goHome() })
    }

    private func noteList(_ source: NoteListSource) -> some View {
        NoteListView(
            source: source,
            refreshToken: refreshToken,
            onOpenFolder: { folder in
                if horizontalSizeClass == .compact {
                    compactScreens.append(.list(folder))
                } else {
                    detailScreens.append(.list(folder))
                }
            },
            onQuickCapture: { showQuickCapture = true }
        )
    }

    // MARK: - Actions

    /// Back to the home screen beside the menu (wide): the app title in the menu brings it back
    /// after search, a list or Settings had replaced it (TestFlight feedback).
    private func goHome() {
        selection = nil
        compactScreens = []
        detailScreens = []
        settingsInDetail = false
        noteStack.closeNote()
    }

    private func choose(_ item: SidebarItem) {
        selection = item
        if horizontalSizeClass == .compact {
            settingsInDetail = false
            compactScreens = [CompactScreen(item)]
            noteStack.closeNote()
            return
        }
        // Wide: everything opens in the note column; the sidebar stays as it is.
        columnVisibility = .all
        compactScreens = []
        noteStack.closeNote()
        if item == .settings {
            detailScreens = []
            settingsPath = NavigationPath()
            settingsInDetail = true
        } else {
            settingsInDetail = false
            detailScreens = [CompactScreen(item)]
        }
    }

    /// Opens a linked note over whatever is open (Spotlight, `triquidnotes://`, Shortcuts).
    private func open(_ link: NoteLink) {
        let title = appState.activeProfile.flatMap {
            try? PersistenceManager.shared.fetchCachedNote(id: link.noteId, serverProfileId: $0.id)?.title
        } ?? ""
        noteStack.closeNote()
        noteStack.push(.note(NoteDestination(noteId: link.noteId, title: title, startInEditMode: link.startInEditMode)))
    }

    /// Brings Spotlight up to date with the cache after a sync (incremental; see `SpotlightIndexer`).
    private func refreshSpotlightIndex() {
        let related = RelatedNotes.shared
        Task { await related.invalidate() }
        guard SpotlightIndexer.isEnabled, let profile = appState.activeProfile else { return }
        let container = PersistenceManager.shared.container
        let profileId = profile.id
        let name = profile.name
        Task.detached(priority: .utility) {
            await SpotlightIndexer(modelContainer: container).update(profileId: profileId, profileName: name)
        }
    }
}

/// Signed-in app chrome: local-transfer banner, catch-up sync when back online, share-import
/// activation, and the first-sync choice sheet.
struct MainShellModifiers: ViewModifier {
    @Environment(AppState.self) private var appState
    /// Called when a share arrives, so the layout can bring the notes forward.
    let onShareImportActivated: () -> Void

    func body(content: Content) -> some View {
        // Observe share-import activation so the layout can react when a share arrives.
        let _ = appState.shareImport.activationToken

        content
            .onChange(of: appState.networkMonitor.isConnected) { _, online in
                guard online, appState.isAuthenticated else { return }
                Task {
                    let refreshed = await appState.refreshTriliumSession()
                    await appState.flushPendingLocalChangesIfPossible(assumeSessionIsReady: refreshed)
                    await appState.runIncrementalSync(maxWaitSeconds: 120, downloadChangedBodies: false)
                }
            }
            .onChange(of: appState.shareImport.activationToken) { _, _ in
                if appState.shareImport.phase != .idle {
                    onShareImportActivated()
                }
            }
            .sheet(item: firstSyncRequest) { request in
                FirstSyncChoiceSheet(request: request)
                    .environment(appState)
            }
    }

    /// A server's first full sync waits here for what to keep offline.
    private var firstSyncRequest: Binding<SyncManager.FirstSyncRequest?> {
        Binding(get: { appState.syncManager.pendingFirstSync }, set: { _ in })
    }
}

/// macOS draws a hard, frosted band under the toolbar when content scrolls beneath it; iOS fades it.
/// The soft fade looks the same on every device.
struct SoftScrollEdgeOnMac: ViewModifier {
    func body(content: Content) -> some View {
        // Both the Mac app and the iPad app running on a Mac.
        if ProcessInfo.processInfo.isMacCatalystApp || ProcessInfo.processInfo.isiOSAppOnMac {
            content.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            content
        }
    }
}

/// One screen of the phone's navigation stack.
enum CompactScreen: Hashable {
    case list(NoteListSource)
    case search
    case settings
    case note(NoteDestination)

    init(_ item: SidebarItem) {
        switch item {
        case .list(let source): self = .list(source)
        case .search: self = .search
        case .settings: self = .settings
        }
    }

    var isNote: Bool {
        if case .note = self { return true }
        return false
    }
}

/// The show-menu button in a screen's bar, beside its own buttons.
private struct ShowSidebarToolbarItem: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        content.toolbar {
            if let action {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: action) {
                        Label(String(localized: "Show Sidebar", comment: "Unfolded Duo: bring the menu column back"), systemImage: "sidebar.left")
                    }
                }
            }
        }
    }
}

extension EnvironmentValues {
    /// A page title may sit level with the bar's buttons instead of under the bar (unfolded Duo).
    @Entry var titleBesideBar = false
}
