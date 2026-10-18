import SwiftUI
import UIKit

private struct CreateNoteSheetContext: Identifiable {
    let id = UUID()
    let parentNote: NoteItem
    let viewModel: TreeViewModel
}

private struct TreeShareSheetPayload: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ShareLocallySheetContext: Identifiable {
    var id: String { note.noteId }
    let note: NoteItem
}

private struct CopyToInstanceSheetContext: Identifiable {
    var id: String { note.noteId }
    let note: NoteItem
}

private struct MoveNoteSheetContext: Identifiable {
    let id = UUID()
    let sourceBranchId: String
    let sourceNoteId: String
    let sourceTitle: String
    let oldParentNoteId: String
}

private struct MoveNoteConfirmPayload {
    let sourceBranchId: String
    let sourceNoteId: String
    let sourceTitle: String
    let oldParentNoteId: String
    let targetParentNoteId: String
    let targetTitle: String
    let targetParentBranchId: String
}

/// Shown over the bulk delete sheet while the selection is deleted.
private struct NoteDeletionProgressView: View {
    let progress: TreeViewModel.DeletionProgress?

    var body: some View {
        VStack(spacing: 12) {
            if let progress, let total = progress.total, total > 1 {
                ProgressView(value: Double(min(progress.completed, total)), total: Double(total))
                    .frame(maxWidth: 240)
                Text(
                    String(
                        format: String(localized: "Deleting %1$d of %2$d notes…", comment: "Tree bulk delete progress"),
                        min(progress.completed, total),
                        total
                    )
                )
            } else {
                ProgressView()
                Text(String(localized: "Deleting notes…", comment: "Tree bulk delete progress before the count is known"))
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding()
    }
}

struct TreeView: View {
    let parentNoteId: String
    let parentTitle: String
    /// When set, tapping a note row selects it: parent for duplicate/move, or any note in the note / open-tab pickers. `(parentNoteId, displayTitle, parentBranchId)`.
    var onPickParent: ((String, String, String) -> Void)?
    /// Replaces the root **+** button in parent-picker mode (e.g. local transfer “Add as root note”).
    var rootPlacementButtonTitle: String?
    /// When `false`, hides sync / overflow toolbar items (embedded note pickers).
    var showsNavigationToolbar: Bool = true
    /// When `false`, hides the large “Notes” header row at the tree root (embedded note pickers).
    var showsRootNotebookHeader: Bool = true
    /// When `false`, hides the open-note tab bar inset (embedded note pickers).
    var showsNoteTabsBarInset: Bool = true
    /// Depth of this tree in its `NoteStack`: the root tree is 0 and owns `path[0]`; a drilled-down tree at `level` owns `path[level]`.
    var level: Int = 0

    init(
        parentNoteId: String = "root",
        parentTitle: String = "Notes",
        onPickParent: ((String, String, String) -> Void)? = nil,
        rootPlacementButtonTitle: String? = nil,
        showsNavigationToolbar: Bool = true,
        showsRootNotebookHeader: Bool = true,
        showsNoteTabsBarInset: Bool = true,
        level: Int = 0
    ) {
        self.parentNoteId = parentNoteId
        self.parentTitle = parentTitle
        self.onPickParent = onPickParent
        self.rootPlacementButtonTitle = rootPlacementButtonTitle
        self.showsNavigationToolbar = showsNavigationToolbar
        self.showsRootNotebookHeader = showsRootNotebookHeader
        self.showsNoteTabsBarInset = showsNoteTabsBarInset
        self.level = level
    }

    @Environment(AppState.self) private var appState
    @Environment(NoteStack.self) private var stack
    @Environment(\.isSplitNoteLayout) private var isSplitNoteLayout
    @Environment(\.colorScheme) private var colorScheme
    /// Set in the iPad split layout: notes open in the note pane instead of being pushed here.
    @State private var viewModel: TreeViewModel?
    /// Pull-to-refresh / toolbar refresh in progress; it reloads the tree after its sync, so a finished sync needn't.
    @State private var isRefreshingWithSync = false
    @State private var createSheetContext: CreateNoteSheetContext?
    @State private var noteToDelete: (note: NoteItem, vm: TreeViewModel)?
    @State private var appearanceTarget: NoteAppearanceTarget?
    @State private var appearanceError: String?
    @State private var eraseNotesOnDelete = false
    @State private var favoriteNoteIds: Set<String> = []
    @State private var showSharedNotesManagement = false
    @State private var showSwitchUserSheet = false
    @State private var showQuickCapture = false
    @State private var treeShareSheetPayload: TreeShareSheetPayload?
    @State private var shareLocallySheetContext: ShareLocallySheetContext?
    @State private var copyToInstanceSheetContext: CopyToInstanceSheetContext?
    @State private var treeSharingError: String?
    @State private var moveNoteSheetContext: MoveNoteSheetContext?
    @State private var moveNoteConfirmPayload: MoveNoteConfirmPayload?
    @State private var moveNoteError: String?
    @State private var isOpeningTodaysJournalNote = false
    @State private var todaysJournalNoteError: String?
    /// Mirrors `LastActiveOpenTabStore` for the active profile so the tab bar updates when the store changes.
    @State private var lastActiveOpenTabIdForBar: String = ""
    /// Branch id to scroll into view after revealing a note’s ancestors.
    @State private var pendingScrollBranchId: String?
    /// Note id of the current note (or deepest visible ancestor) to lightly highlight in the list.
    @State private var highlightedNoteId: String?

    @State private var isSelectMode = false
    @State private var selectedIds: Set<String> = []
    @State private var showBulkDeleteConfirm = false
    @State private var eraseNotesOnBulkDelete = false
    @State private var isBulkDeleting = false
    @State private var bulkDeleteError: String?

    @AppStorage("showNoteTabsBar") private var showNoteTabsBar: Bool = false
    @AppStorage(AppAccent.storageKey) private var appAccent: String = ""
    @AppStorage("colorTheme") private var colorTheme: String = ColorTheme.default.rawValue
    @AppStorage("highlightCurrentNoteInTree") private var highlightCurrentNoteInTree: Bool = true
    @AppStorage("useCustomTreeColors") private var useCustomTreeColors: Bool = false
    @AppStorage("useTriliumNoteColors") private var useTriliumNoteColors: Bool = true
    @AppStorage("treeLightTextColor") private var treeLightTextColor: String = "#1c1c1e"
    @AppStorage("treeDarkTextColor") private var treeDarkTextColor: String = "#e5e5e7"
    @AppStorage("treeLightBgColor") private var treeLightBgColor: String = "#ffffff"
    @AppStorage("treeDarkBgColor") private var treeDarkBgColor: String = "#1c1c1e"
    @AppStorage("treeLightSelectedNoteColor") private var treeLightSelectedNoteColor: String = "#E0EFFF"
    @AppStorage("treeDarkSelectedNoteColor") private var treeDarkSelectedNoteColor: String = "#192739"
    @AppStorage(CalendarJournalSettings.hideChildNotesInTree) private var hideCalendarChildNotesInTree = false

    private var treeTextColor: Color? {
        guard useCustomTreeColors else { return nil }
        return colorScheme == .dark ? Color(hex: treeDarkTextColor) : Color(hex: treeLightTextColor)
    }

    private var treeBgColor: Color? {
        guard useCustomTreeColors else { return nil }
        return colorScheme == .dark ? Color(hex: treeDarkBgColor) : Color(hex: treeLightBgColor)
    }

    /// Custom highlight fill when Custom Tree Colors is on; otherwise `nil` (accent wash is used).
    private var treeSelectedNoteColor: Color? {
        guard useCustomTreeColors else { return nil }
        return colorScheme == .dark
            ? Color(hex: treeDarkSelectedNoteColor)
            : Color(hex: treeLightSelectedNoteColor)
    }

    /// Trilium `#color` label wins when enabled and recognized; else custom tree text color (if on); else the primary text token.
    private func resolvedTreeTitleColor(for note: NoteItem) -> Color {
        noteColor(for: note) ?? treeTextColor ?? .trinoteTextPrimary
    }

    private func noteColor(for note: NoteItem) -> Color? {
        guard useTriliumNoteColors else { return nil }
        return TriliumNoteColorMapper.swiftUIColor(for: note.colorLabelValue)
    }

    private var accent: AppAccent {
        AppAccent.resolve(stored: appAccent, legacyTheme: colorTheme)
    }

    /// Fills space behind the tree list (scroll content is hidden); must not be `.clear` or the nav host shows white.
    private var treeChromeBackground: Color {
        treeBgColor ?? Color.trinoteGround
    }

    /// Keep refresh disabled only while sync is actively running, except allow retry after failures.
    private var canTriggerRefresh: Bool {
        let sync = appState.syncManager
        if sync.syncError != nil { return true }
        if appState.connectionError != nil { return true }
        return !sync.isSyncing
    }

    /// Only the main Notes tab tree hosts local-transfer alerts/sheets (not picker-embedded trees).
    private var isLocalTransferUIHost: Bool {
        onPickParent == nil && parentNoteId == TriliumTreeConstants.rootNoteId
    }

    var body: some View {
        treeViewWithSharedSheetsAndAlerts
            .sheet(item: $moveNoteSheetContext, content: moveNoteParentPickerSheet)
            .alert(
                String(localized: "Move Note", comment: "Move confirmation title"),
                isPresented: moveNoteConfirmBinding,
                actions: moveNoteConfirmActions,
                message: moveNoteConfirmMessage
            )
            .alert(
                "Error",
                isPresented: moveNoteErrorBinding,
                actions: moveNoteErrorActions,
                message: moveNoteErrorMessage
            )
    }

    /// Split from `body` so Swift can type-check the tree without timing out on one huge expression.
    private var treeViewWithSharedSheetsAndAlerts: some View {
        Group {
            if isLocalTransferUIHost {
                treeViewCommonSheetsAndAlerts
                    .alert(
                        String(localized: "Incoming note", comment: "Local transfer offer alert title"),
                        isPresented: localTransferOfferAlertBinding,
                        actions: localTransferOfferAlertActions,
                        message: localTransferOfferAlertMessage
                    )
                    .sheet(isPresented: localTransferParentPickerBinding) {
                        localTransferParentPickerSheet
                    }
                    .onChange(of: appState.shareImport.pendingOpenNote) { _, pending in
                        guard let pending else { return }
                        openSharedImportNote(
                            noteId: pending.noteId,
                            title: pending.title,
                            attachmentIdToInsert: pending.attachmentIdToInsert,
                            attachmentTitleToInsert: pending.attachmentTitleToInsert
                        )
                        appState.shareImport.consumePendingOpenNote()
                    }
            } else {
                treeViewCommonSheetsAndAlerts
            }
        }
    }

    private var treeViewCommonSheetsAndAlerts: some View {
        treeViewChromeAndDestinations
            .noteDeleteConfirmationAlert(
                isPresented: noteToDeleteBinding,
                title: String(localized: "Delete Note", comment: "Tree delete alert title"),
                message: noteToDelete.map {
                    NoteDeleteConfirmationCopy.singleNoteMessage(
                        title: $0.note.uiTitle(forProtectedSessionActive: appState.protectedSessionActive)
                    )
                } ?? "",
                confirmTitle: String(localized: "Delete Note and Subnotes", comment: "Tree delete confirm"),
                erasePermanently: $eraseNotesOnDelete,
                onConfirm: {
                    guard let (note, treeVm) = noteToDelete else { return }
                    let erase = eraseNotesOnDelete
                    let noteId = note.noteId
                    noteToDelete = nil
                    Task {
                        // Surfaced as an alert: the tree's inline error banner sits at the top of the list,
                        // out of sight when the deleted row was further down.
                        if !(await treeVm.deleteNoteAndSubnotes(noteId: noteId, eraseNotes: erase)) {
                            bulkDeleteError = treeVm.error ?? String(
                                localized: "The note could not be deleted.",
                                comment: "Tree single note delete failure"
                            )
                        }
                    }
                },
                onCancel: {
                    eraseNotesOnDelete = false
                    noteToDelete = nil
                }
            )
            .onReceive(NotificationCenter.default.publisher(for: .noteDeleted)) { _ in
                triggerSyncAndReload()
            }
            .onReceive(NotificationCenter.default.publisher(for: .trinoteTreeShouldRefresh), perform: handleTreeShouldRefresh)
            .onReceive(NotificationCenter.default.publisher(for: .ghostNoteDetected)) { _ in
                self.viewModel?.reloadFromCache()
            }
            .sheet(item: $createSheetContext, content: createChildNoteSheet)
            .sheet(isPresented: $showSharedNotesManagement) {
                SharedNotesManagementView()
                    .environment(appState)
            }
            .sheet(isPresented: $showSwitchUserSheet) {
                SwitchUserSheet()
                    .environment(appState)
            }
            .sheet(isPresented: $showQuickCapture) {
                QuickCaptureSheet(onOpenInEditor: { noteId, title in
                    stack.push(.note(NoteDestination(noteId: noteId, title: title, startInEditMode: true)), fromLevel: level)
                })
                .environment(appState)
            }
            .sheet(item: $treeShareSheetPayload, content: treeShareSheet)
            .sheet(item: $shareLocallySheetContext) { ctx in
                ShareLocallyView(note: ctx.note, client: appState.client)
                    .environment(appState)
            }
            .sheet(item: $copyToInstanceSheetContext) { ctx in
                CopyToInstanceSheet(note: ctx.note, sourceClient: appState.client)
                    .environment(appState)
            }
            .alert(
                "Error",
                isPresented: treeSharingErrorBinding,
                actions: treeSharingErrorActions,
                message: treeSharingErrorMessage
            )
            .onReceive(NotificationCenter.default.publisher(for: .trinoteLastActiveOpenTabIdChanged)) { note in
                guard let pid = note.userInfo?["serverProfileId"] as? String,
                      pid == appState.activeProfile?.id
                else { return }
                lastActiveOpenTabIdForBar = LastActiveOpenTabStore.get(profileId: pid)
            }
            .onReceive(NotificationCenter.default.publisher(for: .trinoteWillSwitchServerProfile)) { _ in
                resetNavigationStackBeforeServerProfileChange()
            }
            .sheet(isPresented: $showBulkDeleteConfirm, onDismiss: { eraseNotesOnBulkDelete = false }) {
                treeBulkDeleteConfirmSheet
            }
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
                isPresented: Binding(get: { appearanceError != nil }, set: { if !$0 { appearanceError = nil } }),
                actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
                message: { Text(appearanceError ?? "") }
            )
            .alert(
                String(localized: "Couldn't Open Today's Journal Note", comment: "Today's journal note error title"),
                isPresented: todaysJournalNoteErrorBinding,
                actions: {
                    Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) { todaysJournalNoteError = nil }
                },
                message: {
                    if let todaysJournalNoteError {
                        Text(todaysJournalNoteError)
                    }
                }
            )
            .alert(
                String(localized: "Delete Failed", comment: "Tree bulk delete error"),
                isPresented: bulkDeleteErrorBinding,
                actions: {
                    Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) { bulkDeleteError = nil }
                },
                message: {
                    if let bulkDeleteError {
                        Text(bulkDeleteError)
                    }
                }
            )
    }

    private func openTodaysJournalNote() {
        guard let vm = viewModel, !isOpeningTodaysJournalNote else { return }
        isOpeningTodaysJournalNote = true
        Task {
            defer { isOpeningTodaysJournalNote = false }
            do {
                let note = try await vm.todaysJournalNote()
                stack.push(.note(NoteDestination(noteId: note.noteId, title: note.title, openTabId: note.openTabId)), fromLevel: level)
            } catch {
                todaysJournalNoteError = error.localizedDescription
            }
        }
    }

    private var todaysJournalNoteErrorBinding: Binding<Bool> {
        Binding(
            get: { todaysJournalNoteError != nil },
            set: { if !$0 { todaysJournalNoteError = nil } }
        )
    }

    private var bulkDeleteErrorBinding: Binding<Bool> {
        Binding(
            get: { bulkDeleteError != nil },
            set: { if !$0 { bulkDeleteError = nil } }
        )
    }

    private var bulkDeleteConfirmPaths: [String] {
        guard let profileId = appState.activeProfile?.id else { return [] }
        return PersistenceManager.shared.slashPathsForNotesAndDescendants(
            selectedNoteIds: selectedIds,
            serverProfileId: profileId,
            protectedSessionActive: appState.protectedSessionActive
        )
    }

    private var treeBulkDeleteConfirmSheet: some View {
        NavigationStack {
            List {
                Section {
                    PermanentlyDeleteNotesToggle(isOn: $eraseNotesOnBulkDelete)
                } footer: {
                    Text(NoteDeleteConfirmationCopy.eraseFooter(erasePermanently: eraseNotesOnBulkDelete))
                }
                Section {
                    ForEach(bulkDeleteConfirmPaths, id: \.self) { path in
                        Text(path)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                } header: {
                    Text(NoteDeleteConfirmationCopy.bulkListHeader(erasePermanently: eraseNotesOnBulkDelete))
                    .textCase(nil)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "Delete Notes?", comment: "Tree bulk delete sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", comment: "Tree bulk delete cancel")) {
                        showBulkDeleteConfirm = false
                    }
                    .disabled(isBulkDeleting)
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(String(localized: "Delete", comment: "Tree bulk delete confirm"), role: .destructive) {
                        Task { await performBulkDeleteSelectedNotes() }
                    }
                    .disabled(isBulkDeleting || selectedIds.isEmpty)
                }
            }
            .interactiveDismissDisabled(isBulkDeleting)
            .overlay {
                if isBulkDeleting {
                    NoteDeletionProgressView(progress: viewModel?.deletionProgress)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
        }
    }

    private func exitSelectMode() {
        isSelectMode = false
        selectedIds.removeAll()
        showBulkDeleteConfirm = false
    }

    private func toggleNoteSelection(_ noteId: String) {
        guard noteId != "root" else { return }
        if selectedIds.contains(noteId) {
            selectedIds.remove(noteId)
        } else {
            selectedIds.insert(noteId)
        }
    }

    private func performBulkDeleteSelectedNotes() async {
        guard let vm = viewModel else { return }
        isBulkDeleting = true
        defer { isBulkDeleting = false }

        let profileId = appState.activeProfile?.id
        let idsToDelete: [String]
        if let profileId {
            idsToDelete = PersistenceManager.shared.maximalSelectedAncestorNoteIds(
                selectedNoteIds: selectedIds,
                serverProfileId: profileId
            )
        } else {
            idsToDelete = selectedIds.filter { $0 != "root" }.sorted()
        }

        let failures = await vm.deleteNotesAndSubnotes(noteIds: idsToDelete, eraseNotes: eraseNotesOnBulkDelete)

        showBulkDeleteConfirm = false
        exitSelectMode()

        if failures > 0 {
            bulkDeleteError = String(
                localized: "Could not delete \(failures) note(s). Try again when online.",
                comment: "Tree bulk delete partial failure"
            )
        }
    }

    private var localTransferOfferAlertBinding: Binding<Bool> {
        Binding(
            get: { appState.localTransfer.incomingOffer != nil },
            set: { newValue in
                if !newValue, appState.localTransfer.incomingOffer != nil {
                    Task { await appState.localTransfer.declineIncomingOffer() }
                }
            }
        )
    }

    private var localTransferParentPickerBinding: Binding<Bool> {
        Binding(
            get: { appState.localTransfer.showParentPicker },
            set: { newValue in
                if !newValue {
                    Task { await appState.localTransfer.parentPickerWasDismissedWithoutSelection() }
                }
            }
        )
    }

    @ViewBuilder
    private func localTransferOfferAlertActions() -> some View {
        Button(String(localized: "Accept", comment: "Local transfer offer accept")) {
            appState.localTransfer.beginAcceptanceFlow()
        }
        Button(String(localized: "Decline", comment: "Local transfer offer decline"), role: .cancel) {
            Task { await appState.localTransfer.declineIncomingOffer() }
        }
    }

    @ViewBuilder
    private func localTransferOfferAlertMessage() -> some View {
        if let offer = appState.localTransfer.incomingOffer {
            Text(
                String(
                    format: String(
                        localized: "%1$@ wants to send you “%2$@”.",
                        comment: "Local transfer offer message. %1$@ sender name, %2$@ note title."
                    ),
                    offer.senderDisplayName,
                    offer.title
                )
            )
        }
    }

    private var localTransferParentPickerSheet: some View {
        ParentPickerSheet(
            navigationTitle: String(localized: "Place Note", comment: "Local transfer parent picker title"),
            instruction: String(
                localized: "Choose where to add the received note in your tree.",
                comment: "Local transfer parent picker instruction"
            ),
            topLevelButtonTitle: "",
            showsTopLevelButton: false,
            rootHeaderPlacementTitle: String(
                localized: "Add as root note",
                comment: "Local transfer: place received note at top level"
            ),
            onPick: { parentNoteId, _, _ in
                Task {
                    await appState.localTransfer.parentPickerDidSelect(parentNoteId)
                }
            }
        )
        .environment(appState)
    }

    private var treeViewChromeAndDestinations: some View {
        Group {
            if let viewModel {
                treeContent(viewModel)
                    .onChange(of: appState.protectedSessionActive) { _, _ in
                        Task { await viewModel.refresh() }
                    }
                    .onChange(of: appState.syncManager.lastSyncDate) { _, _ in
                        // Pull-to-refresh reloads the tree itself once its sync is done.
                        guard !isRefreshingWithSync else { return }
                        Task { await viewModel.reloadAfterSyncIfShowingError() }
                    }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(treeChromeBackground)
            }
        }
        .background(treeChromeBackground)
        .modifier(TreeNavigationTitleModifier(
            parentNoteId: parentNoteId,
            parentTitle: parentTitle,
            showsRootNotebookHeader: showsRootNotebookHeader
        ))
        .if(showsNavigationToolbar) { view in
            view.toolbar { treeToolbarContent }
        }
        .task {
            if viewModel == nil {
                let vm = TreeViewModel(appState: appState, parentNoteId: parentNoteId)
                applyCalendarTreePreference(to: vm)
                viewModel = vm
                await vm.loadTree()
            }
            loadFavoriteIds()
            lastActiveOpenTabIdForBar = LastActiveOpenTabStore.get(profileId: appState.activeProfile?.id)
            autoRestoreOpenTabOnLaunchIfNeeded()
        }
        .onChange(of: hideCalendarChildNotesInTree) { _, _ in
            if let viewModel {
                applyCalendarTreePreference(to: viewModel)
            }
        }
        .onChange(of: appState.activeProfile?.id) { _, _ in
            loadFavoriteIds()
            Self.autoRestoreOpenTabHandledForProfileId = nil
            lastActiveOpenTabIdForBar = LastActiveOpenTabStore.get(profileId: appState.activeProfile?.id)
            resetNavigationStackBeforeServerProfileChange()
            Task { @MainActor in
                let vm = TreeViewModel(appState: appState, parentNoteId: parentNoteId)
                applyCalendarTreePreference(to: vm)
                viewModel = vm
                await vm.loadTree()
                if parentNoteId == "root" {
                    autoRestoreOpenTabOnLaunchIfNeeded()
                }
            }
        }
        // Only the root tree declares the destination; SwiftUI uses the one closest to the stack's root.
        .if(level == 0) { view in
            view.navigationDestination(for: NoteRoute.self, destination: routeDestination)
        }
        .onChange(of: stack.currentNote?.noteId, initial: true) { _, noteId in
            // Beside the open note, mark the row on this level that leads to it (the note itself or
            // the folder that holds it), the way returning from it would.
            guard isSplitNoteLayout, onPickParent == nil, let noteId, let vm = viewModel else { return }
            Task { @MainActor in
                highlightedNoteId = await vm.expandAncestorsTowardNote(noteId)?.noteId ?? noteId
            }
        }
        .onChange(of: stack.path) { oldPath, newPath in
            guard oldPath.count > level, newPath.count <= level else { return }
            if let popped = oldPath[level].noteDestination {
                revealPreviousNoteAfterPop(fallbackNoteId: popped.noteId)
            } else if let lastOpened = stack.lastOpenedNoteId, let vm = viewModel {
                // Back from a nested tree: mark the folder holding the last opened note, but keep the
                // scroll position where the user left this page.
                Task { @MainActor in
                    if let row = await vm.expandAncestorsTowardNote(lastOpened) {
                        highlightedNoteId = row.noteId
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Side by side (iPad), the open note's column shows the tabs; one strip is enough.
            if showNoteTabsBar, showsNoteTabsBarInset, !(isSplitNoteLayout && stack.topNoteDestination != nil) {
                NoteTabsBar(
                    currentOpenTabId: lastActiveOpenTabIdForBar.isEmpty ? nil : lastActiveOpenTabIdForBar,
                    onSelect: { tab in
                        LastActiveOpenTabStore.set(tab.id, profileId: appState.activeProfile?.id)
                        lastActiveOpenTabIdForBar = tab.id
                        stack.push(
                            .note(NoteDestination(noteId: tab.noteId, title: tab.title, openTabId: tab.id)),
                            fromLevel: level
                        )
                    },
                    onOpenTabRemoved: { _ in },
                    onTabsBecameEmpty: {
                        LastActiveOpenTabStore.set("", profileId: appState.activeProfile?.id)
                        lastActiveOpenTabIdForBar = ""
                    }
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var treeToolbarContent: some ToolbarContent {
        if isSelectMode, parentNoteId == "root", onPickParent == nil {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Done", comment: "Tree select mode done")) {
                    exitSelectMode()
                }
                .disabled(isBulkDeleting)
            }
            ToolbarItem(placement: .principal) {
                Text(
                    String(
                        format: String(localized: "%d selected", comment: "Tree select mode selected count"),
                        selectedIds.count
                    )
                )
                .font(.headline)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    eraseNotesOnBulkDelete = false
                    showBulkDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedIds.isEmpty || isBulkDeleting)
                .accessibilityLabel(String(localized: "Delete selected notes", comment: "Tree select mode delete"))
            }
        } else if parentNoteId == "root", viewModel != nil {
            if onPickParent == nil {
                // New note is a toolbar item (redesign §3), so on iPhone Duo it joins the trailing rail
                // and is among the last items to overflow (§5).
                if #available(iOS 27.0, *) {
                    newNoteToolbarItem.visibilityPriority(.high)
                } else {
                    newNoteToolbarItem
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if appState.activeProfile?.isLocal != true, onPickParent != nil {
                    TreeSyncButton(isEnabled: canTriggerRefresh, showsStatus: false) {
                        triggerSyncAndReload()
                    }
                }

                Menu {
                    if onPickParent == nil, PersistenceManager.shared.hasMultipleServerProfiles() {
                        Button {
                            showSwitchUserSheet = true
                        } label: {
                            Label(
                                String(localized: "Switch user", comment: "Tree menu: switch signed-in instance"),
                                systemImage: "person.2"
                            )
                        }
                        Divider()
                    }

                    if onPickParent == nil {
                        Button {
                            openTodaysJournalNote()
                        } label: {
                            Label(
                                String(localized: "Open Today's Journal Note", comment: "Tree menu: open (or create) today's journal day note, as in Trilium"),
                                systemImage: "calendar"
                            )
                        }
                        .disabled(isOpeningTodaysJournalNote)

                        Button {
                            isSelectMode = true
                            selectedIds.removeAll()
                        } label: {
                            Label(
                                String(localized: "Select", comment: "Tree menu: enter multi-select mode"),
                                systemImage: "checkmark.circle"
                            )
                        }
                    }

                    Button {
                        showNoteTabsBar.toggle()
                    } label: {
                        if showNoteTabsBar {
                            Label(
                                String(localized: "Hide open notes bar", comment: "Root tree menu: hide open-note tab strip"),
                                systemImage: "rectangle.split.1x2"
                            )
                        } else {
                            Label(
                                String(localized: "Show open notes bar", comment: "Root tree menu: show open-note tab strip"),
                                systemImage: "rectangle.split.1x2"
                            )
                        }
                    }
                } label: {
                    // Title and symbol both, so a vertical toolbar rail can show either (§5).
                    Label(String(localized: "More", comment: "Root tree overflow menu"), systemImage: "ellipsis.circle")
                }
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if appState.activeProfile?.isLocal != true {
                    TreeSyncButton(isEnabled: canTriggerRefresh, showsStatus: onPickParent == nil) {
                        triggerSyncAndReload()
                    }
                }

                if onPickParent == nil, PersistenceManager.shared.hasMultipleServerProfiles() {
                    Menu {
                        Button {
                            showSwitchUserSheet = true
                        } label: {
                            Label(
                                String(localized: "Switch user", comment: "Tree menu: switch signed-in instance"),
                                systemImage: "person.2"
                            )
                        }
                    } label: {
                        Label(String(localized: "More", comment: "Subtree overflow menu"), systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var newNoteToolbarItem: some ToolbarContent {
        // Same placement as the More menu and declared before it, so a vertical rail lists
        // New note first, then the remaining items (§5).
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                // New note is Quick capture (redesign screen 3); typed notes stay in the row menu.
                showQuickCapture = true
            } label: {
                Label(String(localized: "New note", comment: "Quick capture title"), systemImage: "plus")
                    .foregroundStyle(.trinoteOnAccent)
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel(String(localized: "New top-level note", comment: "Toolbar add note"))
        }
    }

    private var noteToDeleteBinding: Binding<Bool> {
        Binding(
            get: { noteToDelete != nil },
            set: { if !$0 { noteToDelete = nil } }
        )
    }

    private func handleTreeShouldRefresh(_ notification: Notification) {
        let nid = notification.userInfo?["noteId"] as? String
        guard let nid else {
            self.viewModel?.pruneDeletedNodes()
            if notification.userInfo?[Notification.Name.trinoteTreeReloadFromServerUserInfoKey] as? Bool == true {
                Task { await self.viewModel?.refreshFromServerIfOnline() }
            } else {
                self.viewModel?.reloadFromCache()
            }
            return
        }
        Task {
            guard let client = appState.client, let vm = viewModel else {
                self.viewModel?.reloadFromCache()
                return
            }
            do {
                let response = try await client.getNote(nid)
                let item = NoteItem(from: response)
                vm.applyNoteMetadataPatch(noteId: nid, newNote: item, animateList: false)
            } catch {
                vm.reloadFromCache()
            }
        }
    }

    @ViewBuilder
    private func routeDestination(_ route: NoteRoute) -> some View {
        switch route {
        case .subtree(let noteId, let title, let level):
            TreeView(
                parentNoteId: noteId,
                parentTitle: title,
                onPickParent: onPickParent,
                showsNavigationToolbar: showsNavigationToolbar,
                showsRootNotebookHeader: showsRootNotebookHeader,
                showsNoteTabsBarInset: showsNoteTabsBarInset,
                level: level
            )
        case .note(let destination):
            destination.makeDetailView()
        }
    }

    private func openNote(_ note: NoteItem) {
        stack.push(
            .note(NoteDestination(
                noteId: note.noteId,
                title: note.uiTitle(forProtectedSessionActive: appState.protectedSessionActive),
                seedChildSummaries: viewModel?.childNoteSummariesForDetailNavigation(parentNoteId: note.noteId)
            )),
            fromLevel: level
        )
    }

    private func createChildNoteSheet(_ ctx: CreateNoteSheetContext) -> some View {
        CreateChildNoteFromTreeSheet(
            parentNote: ctx.parentNote,
            viewModel: ctx.viewModel,
            onDismiss: { createSheetContext = nil },
            onNoteCreated: { noteId, title in
                stack.push(
                    .note(NoteDestination(noteId: noteId, title: title, startInEditMode: true)),
                    fromLevel: level
                )
            }
        )
    }

    private func treeShareSheet(_ payload: TreeShareSheetPayload) -> some View {
        ShareSheet(items: [payload.url])
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
    }

    private var treeSharingErrorBinding: Binding<Bool> {
        Binding(
            get: { treeSharingError != nil },
            set: { if !$0 { treeSharingError = nil } }
        )
    }

    @ViewBuilder
    private func treeSharingErrorActions() -> some View {
        Button(String(localized: "OK", comment: "Dismiss error"), role: .cancel) { treeSharingError = nil }
    }

    private func treeSharingErrorMessage() -> Text {
        Text(treeSharingError ?? String(localized: "An unknown error occurred.", comment: "Generic error"))
    }

    private func moveNoteParentPickerSheet(_ ctx: MoveNoteSheetContext) -> some View {
        ParentPickerSheet(
            navigationTitle: String(localized: "Move to…", comment: "Sheet title: pick parent for move"),
            instruction: String(
                localized: "Choose where to move the note. Open folders, then tap a note to select it as the new parent.",
                comment: "Instructions for move-note parent picker"
            ),
            topLevelButtonTitle: String(localized: "Top level (under Notes)", comment: "Move note under root"),
            onPick: { parentNoteId, title, parentBranchId in
                if parentNoteId == ctx.sourceNoteId {
                    moveNoteError = String(localized: "A note cannot be moved under itself.", comment: "Move validation")
                    moveNoteSheetContext = nil
                    return
                }
                moveNoteConfirmPayload = MoveNoteConfirmPayload(
                    sourceBranchId: ctx.sourceBranchId,
                    sourceNoteId: ctx.sourceNoteId,
                    sourceTitle: ctx.sourceTitle,
                    oldParentNoteId: ctx.oldParentNoteId,
                    targetParentNoteId: parentNoteId,
                    targetTitle: title,
                    targetParentBranchId: parentBranchId
                )
                moveNoteSheetContext = nil
            }
        )
        .environment(appState)
    }

    private var moveNoteConfirmBinding: Binding<Bool> {
        Binding(
            get: { moveNoteConfirmPayload != nil },
            set: { if !$0 { moveNoteConfirmPayload = nil } }
        )
    }

    @ViewBuilder
    private func moveNoteConfirmActions() -> some View {
        Button(String(localized: "Cancel", comment: "Cancel move"), role: .cancel) {
            moveNoteConfirmPayload = nil
        }
        Button(String(localized: "Move", comment: "Confirm move note")) {
            // Capture before the alert dismisses — `isPresented` can clear `moveNoteConfirmPayload` before the Task runs.
            guard let p = moveNoteConfirmPayload else { return }
            moveNoteConfirmPayload = nil
            Task { await performConfirmedTreeMove(payload: p) }
        }
    }

    @ViewBuilder
    private func moveNoteConfirmMessage() -> some View {
        if let p = moveNoteConfirmPayload {
            Text(
                String(
                    localized: "Move “\(p.sourceTitle)” under “\(p.targetTitle)”? The note will appear in the new location in the tree.",
                    comment: "Move confirmation: source and destination titles"
                )
            )
        }
    }

    private var moveNoteErrorBinding: Binding<Bool> {
        Binding(
            get: { moveNoteError != nil },
            set: { if !$0 { moveNoteError = nil } }
        )
    }

    @ViewBuilder
    private func moveNoteErrorActions() -> some View {
        Button(String(localized: "OK", comment: "Dismiss error"), role: .cancel) { moveNoteError = nil }
    }

    private func moveNoteErrorMessage() -> Text {
        Text(moveNoteError ?? "")
    }

    private func performConfirmedTreeMove(payload p: MoveNoteConfirmPayload) async {
        let persistence = PersistenceManager.shared
        if let profileId = appState.activeProfile?.id, !appState.isOnline {
            do {
                try persistence.applyOptimisticBranchMove(
                    sourceBranchId: p.sourceBranchId,
                    sourceNoteId: p.sourceNoteId,
                    targetParentNoteId: p.targetParentNoteId,
                    serverProfileId: profileId
                )
                try persistence.enqueuePendingBranchMove(
                    sourceBranchId: p.sourceBranchId,
                    targetParentBranchId: p.targetParentBranchId,
                    sourceNoteId: p.sourceNoteId,
                    oldParentNoteId: p.oldParentNoteId,
                    targetParentNoteId: p.targetParentNoteId,
                    serverProfileId: profileId
                )
                NotificationCenter.default.post(
                    name: .trinoteTreeShouldRefresh,
                    object: nil,
                    userInfo: ["noteId": p.sourceNoteId]
                )
                viewModel?.reloadFromCache()
            } catch {
                moveNoteError = APIError.from(error).localizedDescription
            }
            return
        }

        guard let client = appState.client else { return }
        do {
            try await client.moveBranchToParent(branchId: p.sourceBranchId, parentBranchId: p.targetParentBranchId)
            NotificationCenter.default.post(
                name: .trinoteTreeShouldRefresh,
                object: nil,
                userInfo: ["noteId": p.sourceNoteId]
            )
            await viewModel?.refresh()
        } catch {
            moveNoteError = APIError.from(error).localizedDescription
        }
    }

    /// Favorites are the `#bookmarked` label, so this writes to the server.
    private func toggleFavorite(_ note: NoteItem, isFav: Bool, onFavoriteChanged: @escaping () -> Void) {
        Task {
            do {
                try await FavoriteBookmarks.setFavorite(
                    !isFav, noteId: note.noteId, title: note.title, noteType: note.type.rawValue, appState: appState
                )
                onFavoriteChanged()
            } catch {
                Log.persistence.error("Failed to toggle favorite: \(error)")
                treeSharingError = error.localizedDescription
            }
        }
    }

    /// Pops note / subtree / tab destinations so no `NoteDetailView` stays mounted with the outgoing profile’s note ids when `activeProfile` changes (see `AppState` posting `.trinoteWillSwitchServerProfile`).
    private func resetNavigationStackBeforeServerProfileChange() {
        stack.popToLevel(level)
        pendingScrollBranchId = nil
        highlightedNoteId = nil
        moveNoteSheetContext = nil
        moveNoteConfirmPayload = nil
        createSheetContext = nil
        treeShareSheetPayload = nil
        noteToDelete = nil
        showSharedNotesManagement = false
        showSwitchUserSheet = false
        exitSelectMode()
        appState.localTransfer.cancelStagedIncomingOffer()
        appState.localTransfer.setReceiveMode(false)
    }

    private func loadFavoriteIds() {
        guard let profileId = appState.activeProfile?.id else {
            favoriteNoteIds = []
            return
        }
        do {
            let favs = try PersistenceManager.shared.fetchFavorites(serverProfileId: profileId)
            favoriteNoteIds = Set(favs.map(\.noteId))
        } catch {
            Log.persistence.error("Failed to load favorite IDs: \(error)")
        }
    }

    private func triggerSyncAndReload() {
        Task { await refreshWithSync() }
    }

    /// Shared by pull-to-refresh and the toolbar refresh button.
    private func refreshWithSync() async {
        isRefreshingWithSync = true
        defer { isRefreshingWithSync = false }
        // A sync that changed the cache already pruned and reloaded the tree (`.trinoteTreeShouldRefresh`); the
        // server reload below rebuilds it either way.
        await self.appState.refreshSessionThenIncrementalSync(maxWaitSeconds: 120, downloadChangedBodies: false)
        await self.viewModel?.refreshFromServerIfOnline()
    }

    /// Process-wide flag so we only auto-open a tab on the first qualifying root-tree appearance per app launch.
    /// Re-arms when the profile changes (multi-account switch) so the new profile gets its own one-shot restore.
    private static var autoRestoreOpenTabHandledForProfileId: String?

    /// On app launch, when the open-tab bar is enabled and the current profile has at least one tab,
    /// push the last active tab (or fall back to the most recently added — same precedence as
    /// `eagerRetargetActiveOpenTabFromCache` / `reconcileOpenTabsAfterLoad`).
    private func autoRestoreOpenTabOnLaunchIfNeeded() {
        guard parentNoteId == "root" else { return }
        guard showNoteTabsBar else { return }
        guard let profileId = appState.activeProfile?.id else { return }
        if Self.autoRestoreOpenTabHandledForProfileId == profileId { return }

        let pm = PersistenceManager.shared
        guard pm.openNoteTabCount(serverProfileId: profileId) > 0 else {
            // No tabs to restore — still mark as handled so we don't keep retrying this launch.
            Self.autoRestoreOpenTabHandledForProfileId = profileId
            return
        }

        let storedTabId = LastActiveOpenTabStore.get(profileId: profileId)
        var resolved: OpenNoteTab?
        if !storedTabId.isEmpty,
           let row = try? pm.fetchOpenNoteTab(id: storedTabId, serverProfileId: profileId) {
            resolved = row
        } else if let mostRecentId = try? pm.mostRecentlyAddedOpenNoteTabId(serverProfileId: profileId),
                  let row = try? pm.fetchOpenNoteTab(id: mostRecentId, serverProfileId: profileId) {
            resolved = row
        }
        guard let tab = resolved else {
            Self.autoRestoreOpenTabHandledForProfileId = profileId
            return
        }

        Self.autoRestoreOpenTabHandledForProfileId = profileId
        LastActiveOpenTabStore.set(tab.id, profileId: profileId)
        lastActiveOpenTabIdForBar = tab.id
        // Only push if we're not already showing a destination from this stack.
        if !stack.hasDestination(aboveLevel: level) {
            stack.push(
                .note(NoteDestination(noteId: tab.noteId, title: tab.title, openTabId: tab.id)),
                fromLevel: level
            )
        }
    }

    @ViewBuilder
    private func treeContent(_ vm: TreeViewModel) -> some View {
        if vm.isLoading && vm.rootChildren.isEmpty {
            loadingView
        } else if let error = vm.error, vm.rootChildren.isEmpty {
            connectionErrorView(vm: vm, error: error)
        } else {
            treeListView(vm)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            LaunchAppMark(size: 56)
            ProgressView()
            Text("Loading note tree…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(treeChromeBackground)
    }

    private func connectionErrorView(vm: TreeViewModel, error: String) -> some View {
        ContentUnavailableView {
            Label("Connection Error", systemImage: "wifi.exclamationmark")
        } description: {
            Text(error)
        } actions: {
            Button("Retry") {
                Task { await vm.loadTree() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(treeChromeBackground)
    }

    @ViewBuilder
    private func treeListView(_ vm: TreeViewModel) -> some View {
        treeList(vm)
            .background(treeChromeBackground)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
            Text(error)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal)
    }

    private var localTransferReceiveBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Receiving notes locally", comment: "Tree banner title"))
                    .font(.subheadline.weight(.semibold))
                Text(
                    String(
                        localized: "Nearby Triquid Notes users can send you a note. Turn this off from ⋯ when you are done.",
                        comment: "Tree banner local receive help"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.accentColor.opacity(0.08))
    }

    private func rootNotebookHeaderRow(viewModel vm: TreeViewModel) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(notebookDisplayName)
                    .font(.system(size: 34, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color.trinoteTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                // A local notebook is offline by design; the indicator is for a server that is unreachable.
                if !appState.isOnline, vm.isFromCache, appState.activeProfile?.isLocal != true {
                    Image(systemName: "icloud.slash")
                        .font(.headline)
                        .accessibilityLabel(String(localized: "Showing cached data", comment: "Offline cached data indicator"))
                }
            }
            Spacer(minLength: 0)
            if let onPickParent, let rootPlacementButtonTitle, parentNoteId == TriliumTreeConstants.rootNoteId {
                Button {
                    onPickParent(
                        TriliumTreeConstants.rootNoteId,
                        String(localized: "Notes", comment: "Root notebook screen title"),
                        TriliumTreeConstants.rootBranchId
                    )
                } label: {
                    Text(rootPlacementButtonTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// A drilled-down level (§4.1): the folder's name and how many notes it holds.
    private func folderHeaderRow(viewModel vm: TreeViewModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(parentTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.trinoteTextPrimary)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Text(String(localized: "\(vm.rootChildren.count) notes", comment: "Tree: number of notes in the folder shown"))
                .font(.footnote)
                .foregroundStyle(Color.trinoteTextSecondary)
        }
    }

    /// The large title (§4.1): the server's display name, else its host, else "Notes".
    private var notebookDisplayName: String {
        if let name = appState.activeProfile?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let host = appState.activeProfile.flatMap({ URL(string: $0.baseURL)?.host() }), !host.isEmpty {
            return host
        }
        return String(localized: "Notes", comment: "Root notebook screen title")
    }

    /// Placeholder for the Trilium `root` note when presenting “new child” flows from the root tree.
    private func syntheticRootNoteItem() -> NoteItem {
        NoteItem(
            noteId: "root",
            title: String(localized: "Notes", comment: "Root notebook screen title"),
            type: .text,
            mime: "text/html",
            isProtected: false,
            dateCreated: "",
            dateModified: "",
            parentNoteIds: [],
            childNoteIds: [],
            parentBranchIds: [],
            childBranchIds: [],
            attributes: []
        )
    }

    private func openSharedImportNote(
        noteId: String,
        title: String,
        attachmentIdToInsert: String? = nil,
        attachmentTitleToInsert: String? = nil
    ) {
        viewModel?.reloadFromCache()
        let route = NoteRoute.note(NoteDestination(
            noteId: noteId,
            title: title,
            startInEditMode: true,
            attachmentIdToInsert: attachmentIdToInsert,
            attachmentTitleToInsert: attachmentTitleToInsert
        ))
        // Pop any open note / subtree / tab destination first, then push on the next turn.
        // Swapping in one step leaves the user on the old note.
        let hadExistingDestination = stack.hasDestination(aboveLevel: level)
        stack.popToLevel(level)
        if hadExistingDestination {
            DispatchQueue.main.async {
                stack.push(route, fromLevel: level)
            }
        } else {
            stack.push(route, fromLevel: level)
        }
    }

    private func treeList(_ vm: TreeViewModel) -> some View {
        ScrollViewReader { proxy in
            List {
                // Header and banners sit on the ground, outside the card.
                Section {
                    if parentNoteId != "root" {
                        folderHeaderRow(viewModel: vm)
                            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    if parentNoteId == "root", showsRootNotebookHeader {
                        rootNotebookHeaderRow(viewModel: vm)
                            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    if isLocalTransferUIHost, appState.localTransfer.receiveModeEnabled {
                        localTransferReceiveBanner
                    }
                    if let error = vm.error, !vm.rootChildren.isEmpty {
                        // Banners draw their own rounded card: between the clear header rows the
                        // list would give them square corners.
                        errorBanner(error)
                            .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 20))
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    // Full sync, incremental progress and the server's own pull. Its own view: progress
                    // ticks then redraw only this row, not the whole list.
                    TreeSyncStatusRows(sync: appState.syncManager)
                }
                // The tree: one grouped card (§4.1).
                Section {
                    ForEach(vm.visibleNodes) { flat in
                        treeNodeRow(flat: flat, vm: vm, favoriteNoteIds: favoriteNoteIds, onFavoriteChanged: loadFavoriteIds)
                            .id(flat.node.branch.branchId)
                    }
                    .if(onPickParent == nil && !isSelectMode) { view in
                        view.onMove(perform: vm.handleMove)
                    }
                }
                // Where the notes live and when they last synced, with Sync now, under the list. A
                // row of its own (not a section footer) so it uses the rows' insets and its icon sits
                // in the same column as theirs on every device.
                if parentNoteId == "root", onPickParent == nil, !isSelectMode {
                    Section {
                        TreeStorageFooter(isSyncEnabled: canTriggerRefresh) { triggerSyncAndReload() }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            // The large folder title sits right under the toolbar, not a grouped list's top inset below it.
            .contentMargins(.top, 0, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 46)
            .scrollContentBackground(.hidden)
            .refreshable { await refreshWithSync() }
            .background(treeChromeBackground)
            .onChange(of: pendingScrollBranchId) { _, branchId in
                guard let branchId else { return }
                // Jump in place after unanimated expand — animated scrollTo fights List restore and
                // reads as bottom → top → bottom.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(branchId, anchor: .center)
                }
                pendingScrollBranchId = nil
            }
        }
    }

    /// After popping a **note** destination, expands ancestors toward that note (or the active tab)
    /// and centers it. Not used when popping a nested tree — that should leave scroll/expand alone.
    private func revealPreviousNoteAfterPop(fallbackNoteId: String) {
        guard onPickParent == nil else { return }
        Task { @MainActor in
            // Destination swaps clear then push on the next turn; skip if something was pushed.
            await Task.yield()
            guard !stack.hasDestination(aboveLevel: level) else { return }

            let noteId = resolveNoteIdForTreeReveal(fallbackNoteId: fallbackNoteId)
            await revealNoteInTree(noteId, collapsingOthers: true)
        }
    }

    /// Expands ancestors toward `noteId`, highlights the deepest visible row on its path and centers it.
    private func revealNoteInTree(_ noteId: String, collapsingOthers: Bool) async {
        guard let vm = viewModel else { return }
        if let target = await vm.expandAncestorsTowardNote(noteId, collapsingOthers: collapsingOthers) {
            highlightedNoteId = target.noteId
            // Let the list apply the unanimated expansion before scrolling.
            await Task.yield()
            pendingScrollBranchId = target.branchId
        } else {
            highlightedNoteId = nil
        }
    }

    private func resolveNoteIdForTreeReveal(fallbackNoteId: String) -> String {
        guard showNoteTabsBar, showsNoteTabsBarInset,
              let profileId = appState.activeProfile?.id
        else {
            return fallbackNoteId
        }
        let tabId = LastActiveOpenTabStore.get(profileId: profileId)
        guard !tabId.isEmpty,
              let tab = try? PersistenceManager.shared.fetchOpenNoteTab(id: tabId, serverProfileId: profileId)
        else {
            return fallbackNoteId
        }
        return tab.noteId
    }

    /// Defers past UIKit context-menu dismissal and cold-launch window timing (`TrinoteDeferredSystemShareSheet`).
    private func scheduleTreeShareSheet(url: URL) {
        TrinoteDeferredSystemShareSheet.schedulePresentation {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                treeShareSheetPayload = TreeShareSheetPayload(url: url)
            }
        }
    }

    /// Parent/move pickers keep year/month/day notes visible so notes can still be filed under a day.
    private func applyCalendarTreePreference(to vm: TreeViewModel) {
        vm.hidesCalendarRootChildrenInTree = onPickParent == nil && hideCalendarChildNotesInTree
        // Trilium's "Hide child notes in tree"; pickers still show those children so they can be chosen.
        vm.hidesSubtreeHiddenChildren = onPickParent == nil
    }

    private func buildTreeNodeRow(node: TreeNode, depth: Int, vm: TreeViewModel, isActive: Bool = false) -> TreeNodeRow {
        let noteId = node.note.noteId
        return TreeNodeRow(
            node: node,
            depth: depth,
            viewModel: vm,
            resolvedTitleColor: resolvedTreeTitleColor(for: node.note),
            resolvedIconColor: noteColor(for: node.note) ?? treeTextColor ?? .trinoteIcon,
            isActive: isActive,
            isSelectMode: isSelectMode,
            isSelected: selectedIds.contains(noteId),
            forceInlineExpand: isSelectMode,
            onSelect: { note, parentBranchId in
                if isSelectMode {
                    toggleNoteSelection(note.noteId)
                } else if let pick = onPickParent {
                    pick(note.noteId, note.uiTitle(forProtectedSessionActive: appState.protectedSessionActive), parentBranchId)
                } else {
                    openNote(note)
                }
            },
            onDrillDown: { noteId, title in
                stack.push(.subtree(noteId: noteId, title: title, level: level + 1), fromLevel: level)
            }
        )
    }

    private func treeRowContextMenuModel(
        flat: FlatTreeNode,
        vm: TreeViewModel,
        isFav: Bool,
        onFavoriteChanged: @escaping () -> Void
    ) -> TreeListRowContextMenuModel {
        TreeListRowContextMenuModel(
            note: flat.node.note,
            vm: vm,
            isFavorite: isFav,
            duplicateParentNoteId: flat.node.branch.parentNoteId,
            isRootRow: flat.node.note.noteId == "root",
            client: appState.client,
            onNewNote: {
                createSheetContext = CreateNoteSheetContext(parentNote: flat.node.note, viewModel: vm)
            },
            onDuplicateSuccess: { openNote($0) },
            onFavoriteToggle: {
                toggleFavorite(flat.node.note, isFav: isFav, onFavoriteChanged: onFavoriteChanged)
            },
            onDelete: {
                eraseNotesOnDelete = false
                noteToDelete = (flat.node.note, vm)
            },
            onPresentShareSheet: { scheduleTreeShareSheet(url: $0) },
            onSharingError: { treeSharingError = $0 },
            onShareLocally: {
                shareLocallySheetContext = ShareLocallySheetContext(note: flat.node.note)
            },
            onCopyToAnotherInstance: {
                copyToInstanceSheetContext = CopyToInstanceSheetContext(note: flat.node.note)
            },
            showsCopyToAnotherInstance: CrossInstanceCopyAvailability.shouldShowMenuItem(
                noteId: flat.node.note.noteId
            ),
            onMove: {
                moveNoteSheetContext = MoveNoteSheetContext(
                    sourceBranchId: flat.node.branch.branchId,
                    sourceNoteId: flat.node.note.noteId,
                    sourceTitle: flat.node.displayTitle(protectedSessionActive: appState.protectedSessionActive),
                    oldParentNoteId: flat.node.branch.parentNoteId
                )
            },
            onOpenInNewTab: nil,
            onAppearance: flat.node.note.noteId == "root" ? nil : { tab in
                let note = flat.node.note
                appearanceTarget = NoteAppearanceTarget(
                    noteId: note.noteId,
                    title: flat.node.displayTitle(protectedSessionActive: appState.protectedSessionActive),
                    iconClass: note.iconClass,
                    colorLabel: note.colorLabelValue,
                    initialTab: tab
                )
            },
            isOnline: appState.isOnline
        )
    }

    private func setAppearance(_ change: () async throws -> Void) async {
        do {
            try await change()
        } catch {
            appearanceError = APIError.from(error).localizedDescription
        }
    }

    private func treeNodeRow(flat: FlatTreeNode, vm: TreeViewModel, favoriteNoteIds: Set<String>, onFavoriteChanged: @escaping () -> Void) -> some View {
        // 22pt per level (§4.1).
        let leading = CGFloat(flat.depth) * 22 + 14
        let isFav = favoriteNoteIds.contains(flat.node.note.noteId)
        let isHighlighted = highlightCurrentNoteInTree
            && highlightedNoteId == flat.node.note.noteId
        let row = buildTreeNodeRow(node: flat.node, depth: flat.depth, vm: vm, isActive: isHighlighted)

        return Group {
            if onPickParent == nil, !isSelectMode {
                TreeListRowUIKitContextMenu(
                    model: treeRowContextMenuModel(flat: flat, vm: vm, isFav: isFav, onFavoriteChanged: onFavoriteChanged)
                ) {
                    row
                }
            } else {
                row
            }
        }
        // Separators span the card (§4.1), not just the indented content.
        .alignmentGuide(.listRowSeparatorLeading) { _ in -leading }
        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width + 12 }
        .listRowInsets(EdgeInsets(top: 0, leading: leading, bottom: 0, trailing: 12))
        .listRowBackground(treeRowBackground(isHighlighted: isHighlighted))
        .listRowSeparatorTint(Color.trinoteSeparator)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    private func treeNoteDrag(for flat: FlatTreeNode) -> TreeNoteDrag {
        TreeNoteDrag(
            noteId: flat.node.note.noteId,
            branchId: flat.node.branch.branchId,
            parentNoteId: flat.node.branch.parentNoteId,
            title: flat.node.displayTitle(protectedSessionActive: appState.protectedSessionActive)
        )
    }

    private func treeRowBackground(isHighlighted: Bool) -> some View {
        ZStack {
            treeBgColor ?? Color.trinoteCard
            if isHighlighted {
                treeSelectedNoteColor ?? accent.tint
            }
        }
    }
}

@MainActor
extension TreeViewModel {
    /// Handles List row reordering (any depth; see `reorderNodes`).
    func handleMove(_ source: IndexSet, _ destination: Int) {
        reorderNodes(from: source, to: destination)
    }
}

// MARK: - Tree Node Row

struct TreeNodeRow: View {
    private static let badgeTrayHeight: CGFloat = 18

    @Environment(AppState.self) private var appState

    let node: TreeNode
    let depth: Int
    let viewModel: TreeViewModel
    var resolvedTitleColor: Color
    /// Glyph color: the note's own color when it has one, otherwise the neutral icon gray.
    var resolvedIconColor: Color = .trinoteIcon
    /// The note shown beside or last returned from: accent text on the accent tint.
    var isActive: Bool = false
    var isSelectMode: Bool = false
    var isSelected: Bool = false
    /// When true, expand/collapse inline even past `TriliumTreeConstants.maxInlineDepth` (used by tree multi-select).
    var forceInlineExpand: Bool = false
    let onSelect: (NoteItem, String) -> Void
    let onDrillDown: (String, String) -> Void

    private var isExpanded: Bool { node.children != nil }
    private var shouldDrillDown: Bool { !forceInlineExpand && depth >= TriliumTreeConstants.maxInlineDepth }
    private var isLocked: Bool { node.note.isProtected && !appState.protectedSessionActive }
    private var titleForegroundColor: Color {
        if isLocked { return .trinoteTextSecondary }
        if isActive { return .accentColor }
        return resolvedTitleColor
    }

    var body: some View {
        HStack(spacing: 0) {
            if isSelectMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.trinoteTextSecondary)
                    .font(.body)
                    .frame(width: 30, alignment: .leading)
                    .accessibilityHidden(true)
            }

            noteLabel

            disclosure
        }
        .frame(minHeight: 46)
    }

    /// Trailing disclosure (§4.1): down when expanded, right when collapsed or when it opens a nested tree.
    @ViewBuilder
    private var disclosure: some View {
        if viewModel.showsExpandChevron(for: node.note) {
            Button {
                if shouldDrillDown {
                    onDrillDown(node.note.noteId, node.displayTitle(protectedSessionActive: appState.protectedSessionActive))
                } else {
                    Task { await viewModel.toggleExpand(node) }
                }
            } label: {
                Group {
                    if node.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: isExpanded && !shouldDrillDown ? "chevron.down" : "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.trinoteTextTertiary)
                    }
                }
                // A separate target of at least 44pt, so a tap on the row still opens the note (§4.1).
                .frame(width: 44, height: 44, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(shouldDrillDown ? "Open sub-notes" : (isExpanded ? "Collapse" : "Expand"))
        } else {
            Color.clear
                .frame(width: 44, height: 1)
                .accessibilityHidden(true)
        }
    }

    private var displayTitle: String {
        node.displayTitle(protectedSessionActive: appState.protectedSessionActive)
    }

    /// Folder or document for plain text notes (§4.1); a note's own Trilium icon or its type glyph otherwise.
    @ViewBuilder
    private var icon: some View {
        let iconColor = isActive ? Color.accentColor : resolvedIconColor
        if let custom = viewModel.effectiveIconClass(for: node.note) {
            NoteIconView(iconClass: custom, fallbackNoteType: node.note.iconFallbackNoteType, size: .compact, foregroundStyle: iconColor)
        } else if node.note.iconFallbackNoteType == .text {
            Image(systemName: viewModel.showsExpandChevron(for: node.note) ? "folder" : "doc")
                .font(.body)
                .foregroundStyle(iconColor)
        } else {
            NoteIconView(iconClass: nil, fallbackNoteType: node.note.iconFallbackNoteType, size: .compact, foregroundStyle: iconColor)
        }
    }

    private var childCount: Int? {
        guard viewModel.showsExpandChevron(for: node.note) else { return nil }
        let count = node.note.childBranchIds.count
        return count > 0 ? count : nil
    }

    private var noteLabel: some View {
        Button {
            onSelect(node.note, node.branch.branchId)
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    icon
                        .frame(width: 22)
                        .accessibilityHidden(true)

                    if node.note.isProtected {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                            .offset(x: 4, y: 2)
                    }
                }

                // Dynamic Type, like the rows in Recents, Favorites and Settings.
                Text(displayTitle)
                    .font(.body.weight(isActive ? .semibold : .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(titleForegroundColor)

                // Children hidden by "Hide child notes in tree": their count, as Trilium's tree shows it.
                if viewModel.isSubtreeHidden(node.note) {
                    Text("\(node.note.childNoteIds.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                        .accessibilityLabel(String(
                            format: String(localized: "%lld hidden child notes", comment: "Tree row: children hidden by Hide child notes in tree"),
                            node.note.childNoteIds.count
                        ))
                }

                Spacer(minLength: 4)

                badges

                if let childCount {
                    Text(childCount, format: .number)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(Color.trinoteTextTertiary)
                        .accessibilityLabel(String(localized: "\(childCount) notes", comment: "Tree row: number of child notes"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .hoverEffect(.highlight)
        .accessibilityLabel(
            isSelectMode
                ? "\(displayTitle), \(isSelected ? "selected" : "not selected")"
                : "\(displayTitle), \(node.note.uiNoteTypeDisplayName) note"
        )
    }

    @ViewBuilder
    private var badges: some View {
        let both = node.note.isSharedWithMultipleTreePlacements
        let shared = both || node.note.showsSharingBadge
        let cloned = both || (!node.note.showsSharingBadge && node.note.showsMultiCloneBadge)
        if shared || cloned {
            HStack(spacing: 4) {
                if shared {
                    Image(systemName: "scale.3d")
                        .font(.caption2)
                        .foregroundStyle(Color.trinoteSyncOK)
                        .accessibilityLabel(String(localized: "Shared note", comment: "Tree row: note has public share link"))
                }
                if cloned {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel(String(localized: "Cloned note", comment: "Tree row: note has multiple parents"))
                }
            }
            .accessibilityElement(children: .combine)
            .frame(height: Self.badgeTrayHeight)
        }
    }
}

// MARK: - Create Child Note Sheet (from Tree)

private struct CreateChildNoteFromTreeSheet: View {
    let parentNote: NoteItem
    let viewModel: TreeViewModel
    let onDismiss: () -> Void
    var onNoteCreated: ((String, String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var newNoteTitle = ""
    @State private var newNoteType: NoteType = .text
    @State private var isCreating = false
    @State private var templateChoice = NewNoteTemplateChoice()

    private var supportsSpreadsheetNoteType: Bool {
        TriliumServerCompatibility.supportsSpreadsheetNotes(appState.serverAppInfo)
    }

    private var supportsKanbanNoteType: Bool {
        TriliumServerCompatibility.supportsKanbanNotes(appState.serverAppInfo)
    }

    private var supportsPresentationNoteType: Bool {
        TriliumServerCompatibility.supportsPresentationNotes(appState.serverAppInfo)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(
                    String(localized: "Note Title (leave blank for default)", comment: "New note from tree"),
                    text: $newNoteTitle
                )
                    .textInputAutocapitalization(.sentences)

                if templateChoice.template == nil {
                    NewNoteTypePicker(
                        selection: $newNoteType,
                        supportsSpreadsheet: supportsSpreadsheetNoteType,
                        supportsKanban: supportsKanbanNoteType,
                        supportsPresentation: supportsPresentationNoteType
                    )
                }

                NewNoteTemplateSection(choice: $templateChoice)
            }

            .navigationTitle(String(localized: "New Note", comment: "New child sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", comment: "New note sheet")) {
                        onDismiss()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Create", comment: "New note sheet")) {
                        Task { await createAndDismiss() }
                    }
                    .disabled(isCreating)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func createAndDismiss() async {
        isCreating = true
        defer { isCreating = false }

        let title = NoteCreationTitle.resolved(from: newNoteTitle)
        let noteId: String?
        if let template = templateChoice.template {
            noteId = await viewModel.createNoteFromTemplate(
                template,
                parentNoteId: templateChoice.parentNoteId(defaultParentNoteId: parentNote.noteId),
                title: newNoteTitle
            )
            let clones = templateChoice.cloneParentNoteIds
            if let noteId, !clones.isEmpty {
                Task { await NoteTemplates.cloneNewNote(noteId, into: clones, appState: appState) }
            }
        } else {
            noteId = await viewModel.createChildNote(
                parentNoteId: parentNote.noteId,
                title: title,
                type: newNoteType
            )
        }
        onDismiss()
        dismiss()
        if let noteId {
            onNoteCreated?(noteId, title)
        }
    }
}

/// Applies tree-local navigation titles without clearing an embedded picker sheet title at root.
private struct TreeNavigationTitleModifier: ViewModifier {
    let parentNoteId: String
    let parentTitle: String
    let showsRootNotebookHeader: Bool

    func body(content: Content) -> some View {
        if parentNoteId == "root", !showsRootNotebookHeader {
            content
        } else {
            // The list shows the title (large at the root, folder name and count below it);
            // the navigation title still names the back button one level down ("‹ All notes").
            content
                .navigationTitle(parentNoteId == "root" ? String(localized: "All notes", comment: "Tree: section header above the note list") : parentTitle)
                .toolbarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
        }
    }
}

/// The tree's sync button. Tap syncs; outside pickers a dot flags an error (red) or being offline
/// (gray), and a long press shows "Synced · 2 min ago" with the sync details.
private struct TreeSyncButton: View {
    @Environment(AppState.self) private var appState
    let isEnabled: Bool
    let showsStatus: Bool
    let action: () -> Void
    @State private var showsDetails = false

    var body: some View {
        let summary = SyncStatusSummary(appState: appState)
        Button(action: action) {
            SyncToolbarIcon(isSyncing: appState.syncManager.isSyncing)
                .overlay(alignment: .topTrailing) {
                    if showsStatus, let dot = statusDotColor {
                        Circle().fill(dot).frame(width: 7, height: 7).offset(x: 3, y: -2)
                    }
                }
        }
        .disabled(!isEnabled)
        .accessibilityLabel(
            appState.syncManager.isSyncing
                ? String(localized: "Syncing…", comment: "Accessibility: tree sync in progress")
                : String(localized: "Sync now", comment: "Sync bar button")
        )
        .accessibilityValue(showsStatus ? summary.summary : "")
        .contextMenu(showsStatus ? ContextMenu {
            Text(summary.summary)
            Button {
                showsDetails = true
            } label: {
                Label(String(localized: "Sync details", comment: "Sync button menu"), systemImage: "info.circle")
            }
        } : nil)
        .sheet(isPresented: $showsDetails) {
            SyncDetailsView()
                .environment(appState)
                .presentationDetents([.medium, .large])
        }
    }

    /// Only states worth noticing get a dot; a healthy sync shows the plain arrow.
    private var statusDotColor: Color? {
        if !appState.isOnline { return .trinoteTextTertiary }
        if appState.syncManager.syncError != nil || appState.connectionError != nil { return .trinoteDestructive }
        return nil
    }
}

/// Under the note list: "Stored on this device" for a local notebook, otherwise when the notes last
/// synced (or that they are offline or failed), with a sync button beside it.
private struct TreeStorageFooter: View {
    @Environment(AppState.self) private var appState
    let isSyncEnabled: Bool
    let onSync: () -> Void
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 10) {
            if appState.activeProfile?.isLocal == true {
                Image(systemName: "iphone")
                    .frame(width: 22)
                Text(String(localized: "Stored on this device", comment: "Tree footer: local notebook"))
                Spacer(minLength: 0)
            } else {
                // With a server only: the button first, then when it last synced.
                Button(action: onSync) {
                    SyncToolbarIcon(isSyncing: appState.syncManager.isSyncing)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 32, height: 32)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(!isSyncEnabled)
                .accessibilityLabel(String(localized: "Sync now", comment: "Sync bar button"))
                // Centered on the rows' 22 pt icon column; the round button is wider than it.
                .frame(width: 22)
                Button { showsDetails = true } label: {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(SyncStatusSummary(appState: appState).summary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .font(.footnote)
        .foregroundStyle(Color.trinoteTextSecondary)
        .textCase(nil)
        .sheet(isPresented: $showsDetails) {
            SyncDetailsView()
                .environment(appState)
                .presentationDetents([.medium, .large])
        }
    }
}

/// Spinning sync arrow in the nav bar while `SyncManager` is syncing (replaces the former blue list banner).
private struct SyncToolbarIcon: View {
    let isSyncing: Bool

    var body: some View {
        if isSyncing {
            TimelineView(.animation(minimumInterval: 1 / 45.0, paused: false)) { context in
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 320))
            }
        } else {
            Image(systemName: "arrow.trianglehead.2.clockwise")
        }
    }
}

#Preview {
    NoteStackHost(stack: NoteStack()) {
        TreeView()
    }
    .environment(AppState())
    .modelContainer(PersistenceManager.shared.container)
}

/// The tree's sync banner and progress bars. A separate view so only it reads `SyncManager`'s progress, and a progress
/// tick redraws this row instead of every tree row.
private struct TreeSyncStatusRows: View {
    let sync: SyncManager

    var body: some View {
        if sync.isSyncing, !sync.hasCompletedFullSync {
            fullSyncBanner
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.accentColor.opacity(0.08))
        } else if sync.showsIncrementalProgress {
            syncProgressBar(
                title: sync.phase == .downloadingContent
                    ? String(localized: "Downloading notes", comment: "Tree sync progress: note bodies")
                    : String(localized: "Syncing changes", comment: "Tree sync progress: entity changes"),
                done: sync.syncedNoteCount,
                total: sync.totalNoteCount,
                fraction: sync.syncProgress
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.accentColor.opacity(0.06))
        } else if sync.hasCompletedFullSync, let server = sync.serverPullProgress {
            syncProgressBar(
                title: String(localized: "Server is syncing", comment: "Tree progress: the server pulls from its own sync server"),
                done: server.pulled,
                total: server.total,
                fraction: server.fraction
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.accentColor.opacity(0.06))
        }
    }

    private var fullSyncBanner: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fullSyncPhaseLabel)
                        .font(.subheadline.weight(.medium))
                    Text("Please keep the app open while syncing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if sync.totalNoteCount > 0 {
                    Text("\(sync.syncedNoteCount)/\(sync.totalNoteCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if sync.totalNoteCount > 0 {
                ProgressView(value: sync.syncProgress)
                    .tint(.accentColor)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// Slim bar for a large quick sync (or the server's own sync); small ones keep to the toolbar spinner.
    private func syncProgressBar(title: String, done: Int, total: Int, fraction: Double) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(String(
                    format: String(localized: "%1$@ of %2$@", comment: "Tree sync progress count"),
                    done.formatted(),
                    total.formatted()
                ))
                .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            ProgressView(value: min(max(fraction, 0), 1))
                .tint(.accentColor)
                .animation(.easeOut(duration: 0.25), value: fraction)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var fullSyncPhaseLabel: String {
        switch sync.phase {
        case .walkingTree:       String(localized: "Building note tree…", comment: "Full sync phase")
        case .downloadingContent: String(localized: "Downloading notes…", comment: "Full sync phase")
        case .cleaningUp:        String(localized: "Finishing up…", comment: "Full sync phase")
        default:                 String(localized: "Syncing…", comment: "Full sync phase")
        }
    }
}
