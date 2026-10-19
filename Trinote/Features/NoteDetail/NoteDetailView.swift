import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

/// Which ⋯ menu command to mirror on the trailing toolbar; stored in `UserDefaults` via `@AppStorage`.

/// Tracked ⋯ menu actions mirrored on the trailing toolbar (delete, edit, rename, and cancel editing are never tracked).
private enum NoteDetailToolbarQuickAction: String, CaseIterable {
    case cancelEditing
    case newChild
    case duplicate
    case noteDetails
    case favorite
    case findOnPage
}

/// Tabs of the iPad note inspector (Trilium's right pane).
private enum NoteInspectorTab: String {
    case contents
    case info
}

private enum EditorFullscreenCover: String, Identifiable {
    case photoLibrary
    case camera
    var id: String { rawValue }
}

private struct NoteDetailShareSheetItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct MoveNoteDetailConfirm {
    let targetParentNoteId: String
    let targetTitle: String
    let targetParentBranchId: String
}

private struct NoteEditTarget: Hashable {
    let noteId: String
    let title: String
}

private struct EditorAttachmentRenameContext {
    let attachmentId: String
    let nodePos: Int
    let fileExtension: String
}

struct NoteDetailView: View {
    @Environment(\.appFont) private var appFont
    let noteId: String
    let title: String
    /// Populated when opening from the tree so sub-notes match expanded in-memory children offline.
    var seedChildSummaries: [ChildNoteSummary]? = nil
    var startInEditMode: Bool = false
    /// When set (e.g. from search), opens find-on-page after content loads and jumps to this 1-based match.
    var pendingFindQuery: String? = nil
    var pendingFindMatchIndex: Int? = nil
    /// When set (e.g. open tabs bar), which `OpenNoteTab` row to restore scroll for.
    var openTabId: String? = nil
    /// When `true` (default), the **last active** open tab (or a chosen row) is retargeted to the note you navigated to from the tree, search, etc. Set `false` for pushed in-note link destinations so the tab strip is not remapped.
    var retargetActiveOpenTab: Bool = true
    /// Share-import file attachment to insert once the rich-text editor is ready (toolbar-equivalent chip).
    var attachmentIdToInsert: String? = nil
    var attachmentTitleToInsert: String? = nil
    /// Set when pushed through a `NoteStack` path; in-place note switches are reported back to that route.
    var routeId: UUID? = nil

    init(
        noteId: String,
        title: String,
        routeId: UUID? = nil,
        seedChildSummaries: [ChildNoteSummary]? = nil,
        startInEditMode: Bool = false,
        pendingFindQuery: String? = nil,
        pendingFindMatchIndex: Int? = nil,
        openTabId: String? = nil,
        retargetActiveOpenTab: Bool = true,
        attachmentIdToInsert: String? = nil,
        attachmentTitleToInsert: String? = nil
    ) {
        self.noteId = noteId
        self.title = title
        self.routeId = routeId
        self.seedChildSummaries = seedChildSummaries
        self.startInEditMode = startInEditMode
        self.pendingFindQuery = pendingFindQuery
        self.pendingFindMatchIndex = pendingFindMatchIndex
        self.openTabId = openTabId
        self.retargetActiveOpenTab = retargetActiveOpenTab
        self.attachmentIdToInsert = attachmentIdToInsert
        self.attachmentTitleToInsert = attachmentTitleToInsert
        _activeNoteId = State(initialValue: noteId)
        _activeOpenTabId = State(initialValue: openTabId)

        if let aid = attachmentIdToInsert, !aid.isEmpty {
            let titleForInsert = (attachmentTitleToInsert?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? attachmentTitleToInsert!
                : "attachment"
            _attachmentToInsert = State(initialValue: EditorAttachmentInsert(
                noteId: noteId,
                attachmentId: aid,
                title: titleForInsert
            ))
        }

        // Seed scroll restoration before the first read-only render (avoids top-then-jump on launch / tab bar).
        if let id = openTabId, let f = OpenTabSessionStore.readReadScrollFraction(for: id) {
            let offset = OpenTabSessionStore.readReadScrollOffset(for: id)
            _scrollTracking = State(initialValue: ReadOnlyScrollTracking(fraction: f, offset: offset))
            _readOnlyScrollFractionPendingRestore = State(initialValue: f)
            _readOnlyScrollOffsetPendingRestore = State(initialValue: offset.map { PendingReadScrollOffset(fraction: f, offset: $0) })
            _isReadOnlyScrollRevealPending = State(initialValue: f > Self.readOnlyScrollRevealMaskThreshold)
            _lastAppliedReadScrollTabId = State(initialValue: id)
        } else {
            _lastAppliedReadScrollTabId = State(initialValue: openTabId)
        }
    }

    @Environment(AppState.self) private var appState
    /// The stack this view was pushed on, if any (absent in sheets and previews).
    @Environment(NoteStack.self) private var noteStack: NoteStack?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    /// Pushed on a stack (a phone, or over a list): back pops it. As a column's root it only leaves the editor.
    @Environment(\.isPresented) private var isPresentedInStack
    /// Back while editing without Autosave or Back Button Saves: ask whether to save.
    @State private var showSaveOnLeave = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.postureMonitor) private var postureMonitor
    /// The software keyboard covers the lower half in tabletop posture; the deck steps aside for it.
    @State private var isSoftwareKeyboardVisible = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var activeNoteId: String
    @State private var favoriteError: String?
    /// Native format bar (redesign screen 2): formatting at the cursor, the Aa panel, and the classic
    /// HTML toolbar for tools the panel does not cover.
    @State private var editorFormatState: [String: Bool] = [:]
    @State private var showEditorFormatPanel = false
    @State private var showNoteLinkPicker = false
    @State private var showsClassicEditorToolbar = false
    /// Note header (redesign screen 2): label chips and the save status in the meta line.
    @State private var showAddLabelPrompt = false
    @State private var newLabelText = ""
    @State private var labelError: String?
    /// Apple Intelligence label suggestions for the open note.
    @State private var labelSuggestions: [LabelSuggestion] = []
    /// The Apple Intelligence button in the editor's format bar shows its three actions.
    @State private var isNoteAIMenuOpen = false
    @FocusState private var isTitleFieldFocused: Bool
    @Namespace private var labelChipNamespace
    /// Apple Intelligence summary of the open note (overflow › Summarize).
    @State private var summaryModel = NoteSummaryModel()
    /// Overflow › Export as Markdown: the bundle waiting for the file exporter, and its result.
    @State private var markdownExport: MarkdownBundleDocument?
    @State private var markdownExportFilename = ""
    @State private var markdownExportMessage: String?
    @State private var pendingMarkdownExportSummary = ""
    /// Something from another app is being dragged over the note (Split View, Stage Manager).
    @State private var isNoteDropTargeted = false
    /// Notes about the same thing (`RelatedNotesIndex`), shown under the sub-notes.
    @State private var relatedNotes: [RelatedNotesIndex.Match] = []
    @State private var isSuggestingLabels = false
    @State private var noteHasPendingUpload = false
    @State private var viewModel: NoteDetailViewModel?
    @State private var navigateToNoteId: String?
    @State private var navigateToNoteForEdit: NoteEditTarget?

    // Inline image insertion state
    @State private var showEditorImageSourceDialog = false
    @State private var editorFullscreenCover: EditorFullscreenCover?
    @State private var showEditorFilePicker = false
    @State private var imageToInsert: String?
    @State private var attachmentToInsert: EditorAttachmentInsert?
    @State private var attachmentRenameContext: EditorAttachmentRenameContext?
    @State private var attachmentRenameBasename = ""
    @State private var pendingAttachmentUpload: PendingAttachmentUpload?
    @State private var pendingAttachmentUploadBasename = ""
    @State private var showDeleteAllAttachmentsConfirm = false
    @State private var protectedDocumentPassword = ""
    @State private var favoriteNoteIds: Set<String> = []
    /// Long-press menu on a sub-note row: the row asked to delete, and the appearance sheet's target.
    @State private var childPendingDelete: ChildNoteSummary?
    @State private var eraseChildOnDelete = false
    @State private var childAppearanceTarget: NoteAppearanceTarget?
    @State private var childActionError: String?
    @State private var childMoveRequest: NoteMoveRequest?
    @State private var findControl = FindOnPageControl()
    @State private var findDeepLinkConsumed = false
    @State private var noteDetailShareSheetItem: NoteDetailShareSheetItem?
    @State private var showMoveParentPicker = false
    @State private var showAppearancePicker = false
    @State private var showCopyToInstance = false
    @State private var showNoteOverflowMenu = false
    @State private var showCalendarJournalSettings = false
    @State private var eraseNotesOnDelete = false
    @State private var moveNoteDetailConfirm: MoveNoteDetailConfirm?
    /// Last note menu action repeated on the trailing toolbar (persists across notes and launches).
    @AppStorage("noteDetailLastToolbarMenuAction") private var lastToolbarQuickActionRaw: String = NoteDetailToolbarQuickAction.noteDetails.rawValue
    @AppStorage("showNoteTabsBar") private var showNoteTabsBar: Bool = false
    @AppStorage("useCustomTreeColors") private var useCustomTreeColors: Bool = false
    @AppStorage("useTriliumNoteColors") private var useTriliumNoteColors: Bool = true
    @AppStorage("treeLightTextColor") private var treeLightTextColor: String = "#1c1c1e"
    @AppStorage("treeDarkTextColor") private var treeDarkTextColor: String = "#e5e5e7"
    /// When `true`, hide the floating edit FAB and instead require a 1.5-second hold on the read-only view to start editing. Mirrors `SettingsView`'s toggle of the same key.
    @AppStorage("noteEditorLongPressToEdit") private var noteEditorLongPressToEdit: Bool = false
    /// When `true`, Image–Code block tools appear in a top toolbar below the nav header instead of the bottom bar.
    @AppStorage("noteEditorInsertToolsAtTop") private var noteEditorInsertToolsAtTop: Bool = false
    @AppStorage(NoteContentWidth.storageKey) private var noteMaxContentWidth: Int = 0
    /// Journal day notes: “Notes edited on that day” pill row starts collapsed.
    @AppStorage("journalNotesEditedOnDayExpanded") private var notesEditedOnDayExpanded: Bool = false
    @State private var activeOpenTabId: String?
    @State private var openNoteTabListNonEmpty: Bool = false
    /// Identifies this screen as `NoteWorkspace.visibleNoteInstanceId` so iPad keyboard commands reach
    /// only the note on screen.
    /// iPad note inspector (Trilium's right pane). Stays open across notes and launches, like Trilium's.
    @AppStorage("noteInspectorVisible") private var showsNoteInspector = false
    @AppStorage("noteInspectorTab") private var noteInspectorTabRaw = NoteInspectorTab.contents.rawValue
    /// Headings of the note on screen, for the inspector's table of contents.
    @State private var tocHeadings: [NoteHeading] = []
    /// A file is being dragged over the note (iPad layout); dropping it adds an attachment.
    @State private var isFileDropTargeted = false
    @State private var isTabBarReordering = false

    private var persistedLastActiveOpenTabId: String {
        LastActiveOpenTabStore.get(profileId: appState.activeProfile?.id)
    }

    /// Aligns “Copy share link” / “Share link…” with the Share/Sharing title (after `scale.3d` column).

    /// Floating Edit chip: shown when opening an editable note; hides on scroll **up**, shows on scroll **down**.
    @State private var showFloatingEditButton = false
    /// Values the read-only scroll updates every frame. A plain reference so writing them doesn't
    /// invalidate this view while scrolling; nothing on screen reads them.
    @State private var scrollTracking = ReadOnlyScrollTracking()
    /// Reading progress for the tabletop deck (`scrollTracking` is deliberately not view state).
    @State private var tabletopReadProgress: CGFloat = 0
    @State private var floatingEditScrollBaselineReady = false
    /// While true, ignore scroll-direction hide/show (layout + scroll restoration during note open).
    @State private var floatingEditIgnoreDirectionalScroll = true
    @State private var floatingEditSettlingEndWorkItem: DispatchWorkItem?
    /// After save leaves the rich-text editor, applied once to the read-only `ScrollView` (same fraction as the web editor).
    @State private var readOnlyScrollFractionPendingRestore: CGFloat?
    /// The pending restore's position in points, tagged with the fraction it was saved with so a later fraction-only
    /// restore (after leaving the editor) never picks it up.
    @State private var readOnlyScrollOffsetPendingRestore: PendingReadScrollOffset?
    /// Hides read-only content until tab scroll restoration settles (avoids top-then-jump).
    @State private var isReadOnlyScrollRevealPending = false
    /// Dedupes `applyReadScrollStateFromStoreForOpenTabId` when the same tab is applied twice after load.
    @State private var lastAppliedReadScrollTabId: String?

    /// Saved scroll fractions at or below this count as "top of note" and skip the reveal mask.
    private static let readOnlyScrollRevealMaskThreshold: CGFloat = 0.01

    /// Save/cancel chip while editing: hide on scroll up, show on scroll down (same rules as read-mode edit FAB).
    @State private var showEditorSaveCancelChip = true
    @State private var lastEditorScrollOffsetY: CGFloat = 0
    @State private var editorSaveCancelScrollBaselineReady = false
    /// True while the table context toolbar is visible in the editor.
    @State private var editorTableToolsVisible = false
    /// After typing activity, show the save chip again after this delay (unless scroll/table logic overrides).
    @State private var editorSaveChipIdleWorkItem: DispatchWorkItem?
    /// Ignore `editorTypingActivity` until this time (avoids hiding the chip from ProseMirror init updates).
    @State private var editorSaveChipIgnoreTypingUntil: Date = .distantPast
    /// Latest editor scroll `y` / `scrollTop` (for gating typing-hide vs. “at top, always show”).
    @State private var lastSaveChipEditorScrollY: CGFloat = 0
    @State private var lastSaveChipEditorVerticallyScrollable: Bool = true
    /// Reference to the rich-text editor WKWebView so the save button can call JS `getContent()`.
    @State private var editorWebView: WKWebView?

    // Autosave and Back saving (issue #26); see `NoteEditorSaving`.
    @AppStorage(NoteEditorSaving.autosaveKey) private var noteEditorAutosave = false
    @AppStorage(NoteEditorSaving.autosaveDelayKey) private var noteEditorAutosaveDelay = NoteEditorSaving.defaultAutosaveDelay
    @AppStorage(NoteEditorSaving.hideSaveButtonKey) private var noteEditorHideSaveButton = false
    @AppStorage(NoteEditorSaving.backButtonSavesKey) private var noteEditorBackButtonSaves = false
    /// The pending autosave; every edit restarts it.
    @State private var autosaveTask: Task<Void, Never>?
    /// Back is saving before it leaves; blocks another tap.
    @State private var isLeavingEditor = false
    /// Back was tapped while photos were uploading; leave once they're in.
    @State private var leaveEditorAfterMediaUpload = false
    /// Cancel Editing would put back the note from before editing (an autosave already saved part of it).
    @State private var showCancelEditingConfirm = false
    /// Created empty to be written in now (see `FreshEmptyNotes`): Don't Save deletes it.
    @State private var isFreshEmptyNote = false
    /// The same question over the iPhone spreadsheet editor, which is a full-screen cover.
    @State private var showSpreadsheetCancelEditingConfirm = false
    @State private var showIncludeNotePicker = false
    @State private var showInlineIconPicker = false

    /// Bridge to communicate with the canvas editor WKWebView (call getSceneData on save).
    @StateObject private var canvasEditorBridge = CanvasEditorBridge()
    @State private var canvasHasUnsavedChanges = false

    /// Bridge to communicate with the spreadsheet editor WKWebView (call getWorkbook on save).
    @StateObject private var spreadsheetEditorBridge = SpreadsheetEditorBridge()
    @State private var spreadsheetHasUnsavedChanges = false
    @State private var isExportingSpreadsheetXlsx = false
    @State private var spreadsheetXlsxExportError: String?

    /// Bridge to communicate with the mind map editor WKWebView (call getMapData on save).
    @StateObject private var mindMapEditorBridge = MindMapEditorBridge()
    @State private var mindMapHasUnsavedChanges = false

    /// Bridge to communicate with the geo map editor WKWebView.
    @StateObject private var geoMapEditorBridge = GeoMapEditorBridge()
    @State private var geoMapPins: [GeoMapPin] = []
    @State private var geoMapTracks: [GeoMapTrack] = []
    @State private var geoMapShapes: [GeoMapShape] = []
    @State private var geoMapDisplaySettings = GeoMapDisplaySettings()
    @State private var geoMapCachedSettingsJSON = GeoMapDisplaySettings().bridgeJSON()
    @State private var geoMapInitialViewportJSON = ""
    @State private var geoMapViewportSaveTask: Task<Void, Never>?
    @State private var geoMapSelection: GeoMapSelection?
    @State private var geoMapShowSettings = false
    @State private var geoMapShowGpxImporter = false
    @State private var geoMapLocator = GeoMapLocator()
    /// Why the Locate button could not show a position (`nil` while there is nothing to say).
    @State private var geoMapLocateFailure: GeoMapLocator.Failure?
    /// The place search sheet, with the area the map showed when it opened.
    @State private var geoMapSearchViewport: GeoMapSearchRequest?
    @State private var geoMapDetailHTML: String?
    @State private var geoMapDetailGPXStats: GeoMapGPXParser.Stats?
    @State private var geoMapFocusedMarkId: String?
    @State private var geoMapLastScrolledMarkId: String?
    @State private var geoMapLastFeatureSelectTime: Date?
    @State private var geoMapLastLoadNoteId: String?
    @State private var geoMapLastLoadAt = Date.distantPast

    private var noteDetailTreeTextColor: Color? {
        guard useCustomTreeColors else { return nil }
        return colorScheme == .dark ? Color(hex: treeDarkTextColor) : Color(hex: treeLightTextColor)
    }

    /// Same rules as `TreeView.resolvedTreeTitleColor`: Trilium `#color`, else custom tree text, else primary.
    private func resolvedNoteDetailTriliumOrThemeTitleColor(for note: NoteItem) -> Color {
        if useTriliumNoteColors, let c = TriliumNoteColorMapper.swiftUIColor(for: note.colorLabelValue) {
            return c
        }
        return noteDetailTreeTextColor ?? .primary
    }

    private func noteDetailTitleForegroundColor(for note: NoteItem) -> Color {
        if note.isProtected, !appState.protectedSessionActive { return .secondary }
        return resolvedNoteDetailTriliumOrThemeTitleColor(for: note)
    }

    private func uiTitle(for note: NoteItem) -> String {
        note.uiTitle(forProtectedSessionActive: appState.protectedSessionActive)
    }

    /// "Text · Edited 2 min ago · Saved to server" with a status dot (redesign screen 2).
    @ViewBuilder
    private func noteMetaLine(vm: NoteDetailViewModel, note: NoteItem) -> some View {
        // Only a state worth knowing gets a word and a dot; a note in sync just says where it lives.
        let status: (String, Color)? = {
            if vm.isSaving { return (String(localized: "Saving…", comment: "Note meta line: save in progress"), .orange) }
            if vm.saveError != nil { return (String(localized: "Not saved", comment: "Note meta line: last save failed"), .trinoteDestructive) }
            if noteHasPendingUpload { return (String(localized: "Saved on this device", comment: "Note meta line: waiting to upload"), .orange) }
            return nil
        }()
        // The server's date when the note came from it, else the cached copy's.
        let modified = note.dateModified.triliumDate()
            ?? appState.activeProfile.flatMap { try? PersistenceManager.shared.fetchCachedNote(id: note.noteId, serverProfileId: $0.id)?.utcDateModified }
                .flatMap(SpotlightIndexer.parseTriliumDate)
        let edited: String? = modified.map {
            String(localized: "Edited \($0.formatted(.relative(presentation: .named)))", comment: "Note meta line: last edit, relative")
        }
        HStack(spacing: 6) {
            if let status {
                Circle().fill(status.1).frame(width: 7, height: 7)
            }
            Text([parentTitle(for: note) ?? note.uiNoteTypeDisplayName, edited, status?.0].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(Color.trinoteTextTertiary)
                .lineLimit(2)
        }
        .task(id: vm.isSaving) {
            guard let profileId = appState.activeProfile?.id else { return }
            let pending = (try? PersistenceManager.shared.fetchPendingNoteBodyUploads(serverProfileId: profileId)) ?? []
            noteHasPendingUpload = pending.contains { $0.noteId == note.noteId }
        }
    }

    /// The notebook a note sits in (its first parent), for the meta line: "Homelab · Edited just now".
    private func parentTitle(for note: NoteItem) -> String? {
        guard let parentId = note.parentNoteIds.first(where: { $0 != "root" }),
              let profileId = appState.activeProfile?.id,
              let parent = try? PersistenceManager.shared.fetchCachedNote(id: parentId, serverProfileId: profileId)
        else { return nil }
        return parent.title
    }

    /// Labels that carry meaning for the reader; Trilium's own bookkeeping labels stay hidden.
    private func visibleLabels(for note: NoteItem) -> [AttributeItem] {
        note.attributes.filter { $0.type == .label && NoteLabelVisibility.isVisible($0.name) }
    }

    /// `#label` chips and "+ Label" (redesign screen 2). Suggestions sit on their own row below,
    /// drawn neutral, and glide into the applied chips when tapped.
    @ViewBuilder
    private func noteLabelChips(vm: NoteDetailViewModel, note: NoteItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Wraps onto new lines instead of running off the edge (wide Mac windows, long labels).
            FlowLayout(spacing: 6) {
                ForEach(visibleLabels(for: note)) { label in
                    let text = NoteLabelVisibility.friendlyText(name: label.name, value: label.value)
                    Menu {
                        Button(role: .destructive) {
                            removeLabel(vm: vm, noteId: note.noteId, label: label)
                        } label: {
                            Label(String(localized: "Remove Label", comment: "Label chip menu"), systemImage: "minus.circle")
                        }
                    } label: {
                        TagChip(text: text, kind: .applied, appliedFill: accentTint)
                    }
                    .matchedGeometryEffect(id: "label-\(text)", in: labelChipNamespace)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                if note.type.isEditable, vm.isOnline {
                    Button {
                        newLabelText = ""
                        showAddLabelPrompt = true
                    } label: {
                        Text(String(localized: "+ Label", comment: "Note header: add a label"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            // Actions are outlined in the accent: neither filled (applied) nor dashed (suggested).
                            .overlay(Capsule().strokeBorder(.tint.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    if LabelSuggester.isAvailable, labelSuggestions.isEmpty {
                        suggestLabelsButton(vm: vm, note: note)
                    }
                }
            }
            if note.type.isEditable, vm.isOnline, !labelSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SuggestedLabelsHeader {
                        withAnimation(.snappy) { labelSuggestions = [] }
                    }
                    FlowLayout(spacing: 6) {
                        ForEach(labelSuggestions, id: \.self) { suggestion in
                            Button {
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                                    labelSuggestions.removeAll { $0 == suggestion }
                                    addLabel(vm: vm, noteId: note.noteId, text: suggestion.value.isEmpty ? suggestion.name : "\(suggestion.name)=\(suggestion.value)")
                                }
                            } label: {
                                TagChip(text: suggestion.friendly, kind: .suggested)
                            }
                            .buttonStyle(.plain)
                            .matchedGeometryEffect(id: "label-\(suggestion.friendly)", in: labelChipNamespace)
                            .accessibilityLabel(String(localized: "Add suggested label \(suggestion.friendly)", comment: "VoiceOver: add an Apple Intelligence label suggestion"))
                        }
                    }
                }
                .padding(10)
                // Ground in light mode, card in dark: the note canvas is white in light and ground in dark.
                .background(Color(light: "#F6F5F2", dark: "#22211F"), in: .rect(cornerRadius: 14))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: visibleLabels(for: note).map(\.id))
        .animation(.snappy, value: labelSuggestions)
        .task(id: note.noteId) {
            #if DEBUG
            // `-TrinoteDebugSummarize YES` (or `todos` / `title`): run that Apple Intelligence action on open.
            if let action = UserDefaults.standard.string(forKey: "TrinoteDebugSummarize") {
                try? await Task.sleep(for: .seconds(1.5))
                runNoteAI(action == "todos" ? .todos : action == "title" ? .title : .summary, vm: vm, note: note)
            }
            // `-TrinoteDebugEdit YES`: open the editor, for screenshots of the editing toolbar.
            if UserDefaults.standard.bool(forKey: "TrinoteDebugEdit") {
                try? await Task.sleep(for: .seconds(1.5))
                vm.startEditing()
            }
            #endif
            labelSuggestions = []
            // A scan's note suggests labels from its recognized text the first time it opens.
            guard LabelSuggester.isAvailable, LabelSuggester.takeSuggestOnOpen(noteId: note.noteId) else { return }
            for _ in 0..<10 where (vm.contentString ?? "").isEmpty {
                try? await Task.sleep(for: .milliseconds(300))
            }
            await suggestLabels(vm: vm, note: note)
        }
        .alert(String(localized: "Add Label", comment: "Add label prompt title"), isPresented: $showAddLabelPrompt) {
            TextField(String(localized: "name or name=value", comment: "Add label prompt placeholder"), text: $newLabelText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(String(localized: "Cancel", comment: "Alert dismiss"), role: .cancel) {}
            Button(String(localized: "Add", comment: "Add label prompt confirm")) {
                addLabel(vm: vm, noteId: note.noteId, text: newLabelText)
            }
        }
        .alert(
            String(localized: "Label Not Changed", comment: "Label change error title"),
            isPresented: Binding(get: { labelError != nil }, set: { if !$0 { labelError = nil } }),
            actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
            message: { Text(labelError ?? "") }
        )
    }

    /// ✨ Suggest: asks Apple Intelligence for labels; they appear on their own row below.
    private func suggestLabelsButton(vm: NoteDetailViewModel, note: NoteItem) -> some View {
        Button {
            Task { await suggestLabels(vm: vm, note: note) }
        } label: {
            HStack(spacing: 4) {
                if isSuggestingLabels {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(String(localized: "Suggest", comment: "Note header: suggest labels with Apple Intelligence"))
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.tint)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .overlay(Capsule().strokeBorder(.tint.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isSuggestingLabels)
        .accessibilityLabel(String(localized: "Suggest labels", comment: "VoiceOver: suggest labels with Apple Intelligence"))
    }

    private func suggestLabels(vm: NoteDetailViewModel, note: NoteItem) async {
        guard !isSuggestingLabels, let profileId = appState.activeProfile?.id else { return }
        isSuggestingLabels = true
        defer { isSuggestingLabels = false }
        let current = visibleLabels(for: note).map { LabelSuggestion(name: $0.name, value: $0.value) }
        let vocabulary = LabelSuggester.vocabulary(serverProfileId: profileId, context: PersistenceManager.shared.context)
        do {
            // A ticket or scanned letter has little text of its own: what its PDF or image says counts.
            let text = await NoteVisualText.text(
                for: note,
                viewModel: vm,
                ownText: LabelSuggester.plainText(fromHTML: vm.contentString ?? "")
            )
            labelSuggestions = try await LabelSuggester.suggest(
                title: note.title,
                text: text,
                vocabulary: vocabulary,
                current: current
            )
        } catch {
            labelError = error.localizedDescription
        }
    }

    private var accentTint: Color {
        AppAccent.resolve(
            stored: UserDefaults.standard.string(forKey: AppAccent.storageKey) ?? "",
            legacyTheme: UserDefaults.standard.string(forKey: "colorTheme") ?? ""
        ).tint
    }

    /// Accepts "name", "#name" or "name=value".
    private func addLabel(vm: NoteDetailViewModel, noteId: String, text: String) {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        let parts = raw.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let name = parts.first, !name.isEmpty, !name.contains(" ") else { return }
        let value = parts.count > 1 ? parts[1] : ""
        Task {
            do {
                guard let client = vm.client else { return }
                try await client.createAttribute(CreateAttributeRequest(
                    noteId: noteId, type: "label", name: name, value: value, isInheritable: false, position: nil
                ))
                await vm.refresh(force: true)
            } catch {
                labelError = error.localizedDescription
            }
        }
    }

    private func removeLabel(vm: NoteDetailViewModel, noteId: String, label: AttributeItem) {
        Task {
            do {
                guard let client = vm.client else { return }
                try await client.deleteAttribute(noteId: noteId, attributeId: label.attributeId)
                await vm.refresh(force: true)
            } catch {
                labelError = error.localizedDescription
            }
        }
    }

    /// Shown under the note title (replaces duplicate full path).
    private func lastChangedCaption(for note: NoteItem) -> String? {
        guard !note.dateModified.isEmpty else { return nil }
        let formatted: String
        if let d = note.dateModified.triliumDate() {
            formatted = d.shortDisplay
        } else {
            formatted = note.dateModified
        }
        return String(localized: "Last changed \(formatted)", comment: "Subtitle under note title; formatted is date/time")
    }

    @ViewBuilder
    private func lastChangedCaptionRow(note: NoteItem, modified: String, leadingPadding: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(modified)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(String(localized: "Last changed \(modified)", comment: "Accessibility"))
            if note.isCalendarRoot {
                Button {
                    showCalendarJournalSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Calendar settings", comment: "Opens calendar journal settings"))
            }
        }
        .padding(.leading, leadingPadding)
    }

    /// `contentOffset` / `scrollTop` at or below this (including small negative bounce) counts as “at top of content” — always show the floating edit (read mode) and save (editing) chips; typing does not hide the save chip in this range.
    private static let noteDetailFloatingChipsAtTopY: CGFloat = 8
    /// Delay before treating scroll deltas as user-driven when no read-only scroll restoration runs.
    private static let floatingEditSettlingDuration: TimeInterval = 0.4

    private func floatingEditFABEligible(vm: NoteDetailViewModel, note: NoteItem) -> Bool {
        !noteEditorLongPressToEdit && note.type.isEditable && !vm.needsProtectedSession && !vm.isEditing
    }

    /// Always show the edit FAB when a note opens; suppress directional hide until layout / scroll restore settles.
    private func presentFloatingEditOnNoteOpen(vm: NoteDetailViewModel, note: NoteItem) {
        floatingEditSettlingEndWorkItem?.cancel()
        floatingEditSettlingEndWorkItem = nil
        floatingEditScrollBaselineReady = false
        scrollTracking.lastContentOffsetY = 0
        floatingEditIgnoreDirectionalScroll = true
        guard floatingEditFABEligible(vm: vm, note: note) else {
            if showFloatingEditButton {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    showFloatingEditButton = false
                }
            }
            return
        }
        if !showFloatingEditButton {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                showFloatingEditButton = true
            }
        }
    }

    private func scheduleFloatingEditScrollSettlingEndIfNeeded() {
        guard readOnlyScrollFractionPendingRestore == nil else { return }
        floatingEditSettlingEndWorkItem?.cancel()
        let work = DispatchWorkItem {
            floatingEditIgnoreDirectionalScroll = false
            floatingEditScrollBaselineReady = false
            floatingEditSettlingEndWorkItem = nil
        }
        floatingEditSettlingEndWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.floatingEditSettlingDuration, execute: work)
    }

    /// Same note, different open tab — `onAppear` does not run; reset FAB like a fresh open.
    private func presentFloatingEditOnOpenTabSwitch() {
        guard let vm = viewModel, let note = vm.note else { return }
        presentFloatingEditOnNoteOpen(vm: vm, note: note)
        scheduleFloatingEditScrollSettlingEndIfNeeded()
    }

    private func finishFloatingEditScrollSettling(vm: NoteDetailViewModel, note: NoteItem) {
        floatingEditSettlingEndWorkItem?.cancel()
        floatingEditSettlingEndWorkItem = nil
        floatingEditIgnoreDirectionalScroll = false
        floatingEditScrollBaselineReady = false
        scrollTracking.lastContentOffsetY = 0
        guard floatingEditFABEligible(vm: vm, note: note) else {
            if showFloatingEditButton {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    showFloatingEditButton = false
                }
            }
            return
        }
        if !showFloatingEditButton {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                showFloatingEditButton = true
            }
        }
    }

    /// Uses `UIScrollView.contentOffset.y` (via `NoteDetailScrollOffsetReader`): increases when scrolling **down**, decreases when scrolling **up**.
    private func updateFloatingEditVisibility(contentOffsetY: CGFloat, vm: NoteDetailViewModel, note: NoteItem) {
        guard !noteEditorLongPressToEdit, note.type.isEditable, !vm.needsProtectedSession, !vm.isEditing else {
            if showFloatingEditButton {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    showFloatingEditButton = false
                }
            }
            scrollTracking.lastContentOffsetY = contentOffsetY
            floatingEditScrollBaselineReady = false
            floatingEditIgnoreDirectionalScroll = true
            return
        }

        if floatingEditIgnoreDirectionalScroll {
            if !floatingEditScrollBaselineReady {
                floatingEditScrollBaselineReady = true
            }
            scrollTracking.lastContentOffsetY = contentOffsetY
            if !showFloatingEditButton {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    showFloatingEditButton = true
                }
            }
            return
        }

        if contentOffsetY <= Self.noteDetailFloatingChipsAtTopY {
            if !floatingEditScrollBaselineReady {
                floatingEditScrollBaselineReady = true
            }
            scrollTracking.lastContentOffsetY = contentOffsetY
            if !showFloatingEditButton {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    showFloatingEditButton = true
                }
            }
            return
        }

        if !floatingEditScrollBaselineReady {
            floatingEditScrollBaselineReady = true
            scrollTracking.lastContentOffsetY = contentOffsetY
            if !showFloatingEditButton {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    showFloatingEditButton = true
                }
            }
            return
        }

        let directionalThreshold: CGFloat = 10
        let delta = contentOffsetY - scrollTracking.lastContentOffsetY
        scrollTracking.lastContentOffsetY = contentOffsetY

        let nextVisible: Bool
        if delta < -directionalThreshold {
            // Offset decreased → user scrolled **up** → hide.
            nextVisible = false
        } else if delta > directionalThreshold {
            // User scrolled **down** → show again.
            nextVisible = true
        } else {
            return
        }

        if nextVisible != showFloatingEditButton {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                showFloatingEditButton = nextVisible
            }
        }
    }

    /// Save pill: show on scroll-down sooner than hide on scroll-up (asymmetric thresholds).
    /// When `verticallyScrollable` is false, the pill always stays visible (no scroll means no scroll events to recover from a hidden state).
    private func updateEditorSaveCancelChipVisibility(contentOffsetY: CGFloat, verticallyScrollable: Bool = true) {
        lastSaveChipEditorScrollY = contentOffsetY
        lastSaveChipEditorVerticallyScrollable = verticallyScrollable
        if !verticallyScrollable {
            lastEditorScrollOffsetY = contentOffsetY
            editorSaveCancelScrollBaselineReady = true
            if !showEditorSaveCancelChip {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                    showEditorSaveCancelChip = true
                }
            }
            return
        }

        if contentOffsetY <= Self.noteDetailFloatingChipsAtTopY {
            lastEditorScrollOffsetY = contentOffsetY
            editorSaveCancelScrollBaselineReady = true
            if !showEditorSaveCancelChip {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                    showEditorSaveCancelChip = true
                }
            }
            return
        }

        if !editorSaveCancelScrollBaselineReady {
            editorSaveCancelScrollBaselineReady = true
            lastEditorScrollOffsetY = contentOffsetY
            return
        }

        /// Minimum `contentOffset.y` change to count as scrolling **up** (hide pill). Slightly higher avoids jitter.
        let scrollUpThreshold: CGFloat = 10
        /// Lower than `scrollUpThreshold` so a small scroll **down** brings the save pill back quickly.
        let scrollDownThreshold: CGFloat = 3

        let delta = contentOffsetY - lastEditorScrollOffsetY
        lastEditorScrollOffsetY = contentOffsetY

        let nextVisible: Bool
        if delta < -scrollUpThreshold {
            nextVisible = false
        } else if delta > scrollDownThreshold {
            nextVisible = true
        } else {
            return
        }

        if nextVisible != showEditorSaveCancelChip {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                showEditorSaveCancelChip = nextVisible
            }
        }
    }

    /// Delay after last typing activity before the save chip fades back in (shorter = snappier; too low flickers on brief pauses).
    private static let editorSaveChipIdleDelay: TimeInterval = 0.75
    private static let editorSaveChipIgnoreTypingAfterAppear: TimeInterval = 0.5

    private func cancelEditorSaveChipIdleShowTask() {
        editorSaveChipIdleWorkItem?.cancel()
        editorSaveChipIdleWorkItem = nil
    }

    private func handleEditorSaveChipTypingActivity() {
        guard Date() >= editorSaveChipIgnoreTypingUntil else { return }
        if !lastSaveChipEditorVerticallyScrollable { return }
        if lastSaveChipEditorScrollY <= Self.noteDetailFloatingChipsAtTopY { return }
        cancelEditorSaveChipIdleShowTask()

        if showEditorSaveCancelChip {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                showEditorSaveCancelChip = false
            }
        }

        let work = DispatchWorkItem {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                showEditorSaveCancelChip = true
            }
        }
        editorSaveChipIdleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.editorSaveChipIdleDelay, execute: work)
    }

    /// Length of the long-press hold (in seconds) that activates editing when the FAB is replaced
    /// by gesture-based editing. Matches the description in `SettingsView`'s footer.
    private static let noteEditorLongPressToEditDuration: TimeInterval = 1.5

    /// Long-press gesture used when `noteEditorLongPressToEdit` is on. Runs as a
    /// `simultaneousGesture` so it doesn't block scrolling, link taps, or the WebView's own
    /// long-press for text selection — pressing-and-holding (without moving) for 1.5s simply
    /// starts editing on top of whatever the underlying view does.
    private func longPressToEditGesture(vm: NoteDetailViewModel, note: NoteItem) -> some Gesture {
        LongPressGesture(minimumDuration: Self.noteEditorLongPressToEditDuration)
            .onEnded { _ in
                guard noteEditorLongPressToEdit,
                      note.type.isEditable,
                      !vm.needsProtectedSession,
                      !vm.isEditing
                else { return }
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                vm.startEditing()
            }
    }

    /// Re-evaluates the FAB visibility after the long-press setting toggles or the note's
    /// editability changes. Keeps the FAB in sync when the user flips the toggle while a note
    /// is on screen, without waiting for the next scroll event.
    private func refreshFloatingEditVisibility(vm: NoteDetailViewModel, note: NoteItem) {
        if floatingEditFABEligible(vm: vm, note: note) {
            presentFloatingEditOnNoteOpen(vm: vm, note: note)
            scheduleFloatingEditScrollSettlingEndIfNeeded()
        } else if showFloatingEditButton {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                showFloatingEditButton = false
            }
            floatingEditScrollBaselineReady = false
            floatingEditIgnoreDirectionalScroll = true
        }
    }

    @ViewBuilder
    private func floatingEditFAB(vm: NoteDetailViewModel) -> some View {
        Button {
            vm.startEditing()
        } label: {
            Image("EditNoteFloating")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                // Liquid Glass tinted with the accent: it stands out on white pages and PDFs as well
                // as dark ones, and refracts what is under it like the other controls.
                .foregroundStyle(.trinoteOnAccent)
                .padding(12)
                .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Edit note", comment: "Floating scroll edit button"))
    }

    private static let richTextEditorScrollFractionScript = """
    (function(){
      try { return window.editorBridge.getScrollFraction(); } catch (e) { return 0; }
    })();
    """

    /// Fetches HTML + scroll fraction from `editor.html` in one round-trip (see `getScrollFraction` / `scrollToFraction`).
    private static let richTextEditorSavePayloadScript = """
    (function(){
      try {
        var html = window.editorBridge.getContent();
        var f = window.editorBridge.getScrollFraction();
        return JSON.stringify({ html: html, f: f });
      } catch (e) {
        return JSON.stringify({ html: null, f: 0 });
      }
    })();
    """

    /// WKWebView may return `JSON.stringify` as a `String` or as a bridged dictionary; the latter used to force a
    /// `saveContent()` fallback without `freshHTML`, losing editor-only state (e.g. math restored by undo).
    private static func parseRichTextEditorSavePayload(_ result: Any?) -> (html: String?, scrollFraction: CGFloat?) {
        if let obj = javaScriptResultAsStringKeyedDictionary(result) {
            return parseRichTextSavePayloadFromDictionary(obj)
        }
        guard let s = result as? String, !s.isEmpty else { return (nil, nil) }
        guard s.first == "{",
              let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (s, nil)
        }
        return parseRichTextSavePayloadFromDictionary(obj)
    }

    private static func javaScriptResultAsStringKeyedDictionary(_ result: Any?) -> [String: Any]? {
        if let d = result as? [String: Any] { return d }
        guard let raw = result as? [AnyHashable: Any] else { return nil }
        var out: [String: Any] = [:]
        for (k, v) in raw {
            if let ks = k as? String { out[ks] = v }
            else if let ks = k as? NSString { out[ks as String] = v }
        }
        return out.isEmpty ? nil : out
    }

    private static func parseRichTextSavePayloadFromDictionary(_ obj: [String: Any]) -> (html: String?, scrollFraction: CGFloat?) {
        let html: String?
        switch obj["html"] {
        case is NSNull, nil:
            html = nil
        case let str as String:
            html = str
        case let ns as NSString:
            html = ns as String
        default:
            html = nil
        }
        let f: CGFloat?
        if let n = obj["f"] as? NSNumber {
            f = CGFloat(truncating: n)
        } else if let d = obj["f"] as? Double {
            f = CGFloat(d)
        } else {
            f = nil
        }
        return (html, f)
    }

    private static func parseRichTextEditorScrollFraction(_ result: Any?) -> CGFloat? {
        if let n = result as? NSNumber { return CGFloat(truncating: n) }
        if let d = result as? Double { return CGFloat(d) }
        if let s = result as? String, let d = Double(s) { return CGFloat(d) }
        return nil
    }

    private func queueReadOnlyScrollRestoreAfterRichTextSave(fraction: CGFloat) {
        let f = min(max(fraction, 0), 1)
        scrollTracking.fraction = f
        scrollTracking.offset = nil
        readOnlyScrollFractionPendingRestore = f
        readOnlyScrollOffsetPendingRestore = nil
        isReadOnlyScrollRevealPending = f > Self.readOnlyScrollRevealMaskThreshold
    }

    /// Escape for use inside a JS template literal (same pattern as `RichTextEditorView.setContent`).
    private static func javaScriptTemplateLiteralContent(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
    }

    private static func insertIncludeNoteInEditor(webView: WKWebView?, noteId: String, title: String, boxSize: String) {
        guard let webView else { return }
        let idEsc = javaScriptTemplateLiteralContent(noteId)
        let titleEsc = javaScriptTemplateLiteralContent(title)
        let boxEsc = javaScriptTemplateLiteralContent(boxSize)
        let script = "window.editorBridge.insertIncludeNote(`\(idEsc)`, `\(boxEsc)`, `\(titleEsc)`);"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Inserts a Trilium inline icon at the editor's frozen caret, with that glyph's CSS (the editor only styles the icons
    /// the note had when it loaded).
    private static func insertInlineIconInEditor(webView: WKWebView?, iconClass: String) {
        guard let webView else { return }
        let classEsc = javaScriptTemplateLiteralContent(iconClass)
        let css = TriliumInlineIconStyles.css(forHTML: "<span class=\"tn-icon \(iconClass)\"></span>")
        let cssEsc = javaScriptTemplateLiteralContent(css)
        webView.evaluateJavaScript("window.editorBridge.insertInlineIcon(`\(classEsc)`, `\(cssEsc)`);", completionHandler: nil)
    }

    private static func pushIncludeNoteTitleToEditor(webView: WKWebView?, noteId: String, title: String) {
        guard let webView else { return }
        let idEsc = javaScriptTemplateLiteralContent(noteId)
        let titleEsc = javaScriptTemplateLiteralContent(title)
        webView.evaluateJavaScript("window.editorBridge.setIncludeNoteTitle(`\(idEsc)`, `\(titleEsc)`);", completionHandler: nil)
    }

    private static func pushIncludeNotePreviewToEditor(webView: WKWebView?, previewId: String, html: String) {
        guard let webView else { return }
        let payload: [String: String] = ["previewId": previewId, "html": html]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let escaped = javaScriptTemplateLiteralContent(json)
        webView.evaluateJavaScript("window.editorBridge.applyIncludeNotePreviewJSON(`\(escaped)`);", completionHandler: nil)
    }

    private static func insertAttachmentLinkInEditor(webView: WKWebView?, noteId: String, attachmentId: String, title: String) {
        guard let webView else { return }
        guard let noteIdData = try? JSONSerialization.data(withJSONObject: noteId, options: [.fragmentsAllowed]),
              let attachmentIdData = try? JSONSerialization.data(withJSONObject: attachmentId, options: [.fragmentsAllowed]),
              let titleData = try? JSONSerialization.data(withJSONObject: title, options: [.fragmentsAllowed]),
              let noteIdJSON = String(data: noteIdData, encoding: .utf8),
              let attachmentIdJSON = String(data: attachmentIdData, encoding: .utf8),
              let titleJSON = String(data: titleData, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.editorBridge.insertAttachmentLink(\(noteIdJSON), \(attachmentIdJSON), \(titleJSON));",
            completionHandler: nil
        )
    }

    private static func beginEditorImageBatch(webView: WKWebView?, count: Int) {
        webView?.evaluateJavaScript(
            "try{window.editorBridge.beginImageBatch(\(count))}catch(e){}",
            completionHandler: nil
        )
    }

    private static func insertBatchImageInEditor(webView: WKWebView?, insert: EditorImageInsert) {
        guard let webView else { return }
        var item = ["src": insert.src]
        if let originalSrc = insert.originalSrc {
            item["originalSrc"] = originalSrc
        }
        guard let data = try? JSONSerialization.data(withJSONObject: item),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.editorBridge.insertBatchImage(\(json));", completionHandler: nil)
    }

    private static func endEditorImageBatch(webView: WKWebView?) {
        webView?.evaluateJavaScript(
            "try{window.editorBridge.endImageBatch()}catch(e){}",
            completionHandler: nil
        )
    }

    private static func updateAttachmentReferenceTitleInEditor(webView: WKWebView?, pos: Int, title: String) {
        guard let webView else { return }
        guard let titleData = try? JSONSerialization.data(withJSONObject: title, options: [.fragmentsAllowed]),
              let titleJSON = String(data: titleData, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.editorBridge.updateAttachmentReferenceTitle(\(pos), \(titleJSON));",
            completionHandler: nil
        )
    }

    private func applyAttachmentRename() {
        guard let ctx = attachmentRenameContext else { return }
        let trimmed = attachmentRenameBasename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newTitle = AttachmentFilename.join(basename: trimmed, ext: ctx.fileExtension)
        attachmentRenameContext = nil
        Self.updateAttachmentReferenceTitleInEditor(webView: editorWebView, pos: ctx.nodePos, title: newTitle)
        Task { @MainActor in
            guard let vm = viewModel else { return }
            await vm.renameAttachmentTitle(attachmentId: ctx.attachmentId, title: newTitle)
        }
    }

    private func presentAttachmentUploadNamePrompt(data: Data, mime: String, filename: String) {
        let pending = PendingAttachmentUpload(data: data, mime: mime, filename: filename)
        pendingAttachmentUploadBasename = pending.suggestedBasename
        pendingAttachmentUpload = pending
    }

    private func confirmPendingAttachmentUpload(
        _ item: PendingAttachmentUpload,
        basename: String,
        vm: NoteDetailViewModel
    ) async {
        let filename = item.resolvedFilename(basename: basename)
        if let attachment = await vm.uploadAttachment(data: item.data, filename: filename, mime: item.mime) {
            Self.insertAttachmentLinkInEditor(
                webView: editorWebView,
                noteId: vm.noteId,
                attachmentId: attachment.attachmentId,
                title: attachment.title
            )
        }
    }

    /// Leaves the rich-text editor and restores read-only scroll to the editor's current position.
    private func cancelRichTextEditing(vm: NoteDetailViewModel) {
        if let wv = editorWebView {
            wv.evaluateJavaScript(Self.richTextEditorScrollFractionScript) { result, _ in
                DispatchQueue.main.async {
                    let frac = Self.parseRichTextEditorScrollFraction(result) ?? scrollTracking.fraction
                    queueReadOnlyScrollRestoreAfterRichTextSave(fraction: frac)
                    vm.cancelEditing()
                }
            }
        } else {
            vm.cancelEditing()
        }
    }

    /// Cancel Editing. After an autosave this puts back the note from before editing, so it asks first.
    private func cancelNoteEditing(vm: NoteDetailViewModel, note: NoteItem) {
        if vm.cancelEditingNeedsConfirmation {
            showCancelEditingConfirm = true
            return
        }
        discardNoteEditing(vm: vm, note: note)
    }

    private func discardNoteEditing(vm: NoteDetailViewModel, note: NoteItem) {
        cancelScheduledAutosave()
        if isFreshEmptyNote {
            // Nothing of it was kept: the note goes again rather than stay behind empty.
            isFreshEmptyNote = false
            Task {
                if await vm.deleteNote() { leaveDeletedNote() }
            }
            return
        }
        if note.type == .spreadsheet { spreadsheetHasUnsavedChanges = false }
        if vm.isEditing && note.type == .text {
            cancelRichTextEditing(vm: vm)
        } else {
            vm.cancelEditing()
        }
    }

    /// Fetches the latest HTML from the rich-text editor (including non-ProseMirror state like
    /// table captions) and then saves. Code, Markdown and Mermaid notes (and a text editor that
    /// isn't up yet) save `editableContent` directly.
    /// - Parameter completion: Gets whether the editor closed, i.e. the save worked.
    private func saveRichTextContent(vm: NoteDetailViewModel, completion: ((Bool) -> Void)? = nil) {
        // Only a text note's editor is TipTap; `editorWebView` can outlive the editor it came from.
        if vm.note?.type == .text, let wv = editorWebView {
            wv.evaluateJavaScript(Self.richTextEditorSavePayloadScript) { result, _ in
                DispatchQueue.main.async {
                    let (html, frac) = Self.parseRichTextEditorSavePayload(result)
                    if let frac {
                        queueReadOnlyScrollRestoreAfterRichTextSave(fraction: frac)
                    }
                    if let html {
                        vm.saveContent(freshHTML: html)
                    } else {
                        vm.saveContent()
                    }
                    completion?(!vm.isEditing)
                }
            }
        } else {
            vm.saveContent()
            completion?(!vm.isEditing)
        }
    }

    private func runEditorFormatCommand(_ command: EditorFormatCommand) {
        editorWebView?.evaluateJavaScript(command.javaScript, completionHandler: nil)
    }

    private func insertNoteLinkInEditor(noteId: String, title: String) {
        guard let args = try? String(data: JSONSerialization.data(withJSONObject: [noteId, title]), encoding: .utf8) else { return }
        editorWebView?.evaluateJavaScript(
            "try{window.editorBridge.insertNoteLink(...\(args))}catch(e){}",
            completionHandler: nil
        )
    }

    /// Save-only floating chip (cancel is in the note toolbar menu / quick action while editing).
    @ViewBuilder
    private func editorSaveChip(vm: NoteDetailViewModel) -> some View {
        Button {
            saveRichTextContent(vm: vm)
        } label: {
            ZStack {
                if vm.isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image("SaveNoteFloating")
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                }
            }
            .foregroundStyle(.primary)
            .frame(width: 48, height: 48)
            .background(.ultraThinMaterial, in: Circle())
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(vm.isSaving)
        .accessibilityLabel(String(localized: "Save", comment: "Editor save chip"))
    }

    private var hidesEditorSaveButton: Bool {
        NoteEditorSaving.hidesSaveButton(autosave: noteEditorAutosave, hideSaveButton: noteEditorHideSaveButton)
    }

    private var savesWhenLeavingEditor: Bool {
        NoteEditorSaving.savesWhenLeaving(autosave: noteEditorAutosave, backButtonSaves: noteEditorBackButtonSaves)
    }

    /// Interactive back-swipe fights pan/zoom on full-bleed canvases (mind map, geo map) and edit surfaces.
    private var shouldBlockNavigationPopGesture: Bool {
        if isTabBarReordering { return true }
        if viewModel?.isEditing == true { return true }
        if isGeoMapNote(viewModel?.note, contentString: viewModel?.contentString, vm: viewModel) { return true }
        // Mind map (read or edit): edge swipes are used to pan the diagram.
        if viewModel?.note?.type == .mindMap { return true }
        return false
    }

    /// Partially folded with the hinge across the screen: the note on the upright half, controls on
    /// the half on the table (`TabletopDeck`). Needs room for the deck and no software keyboard.
    private var isTabletopLayout: Bool {
        guard let postureMonitor, postureMonitor.posture == .tabletop else { return false }
        return postureMonitor.lowerSegmentHeight >= 180 && !isSoftwareKeyboardVisible
    }

    @ViewBuilder
    private func tabletopDeck(vm: NoteDetailViewModel, note: NoteItem) -> some View {
        let height = (postureMonitor?.lowerSegmentHeight ?? 0) + 24
        TabletopDeck(height: height) {
            if vm.isEditing, note.type == .text, !showsClassicEditorToolbar {
                TabletopFormatControls(
                    state: editorFormatState,
                    isSaving: vm.isSaving,
                    onCommand: { runEditorFormatCommand($0) },
                    onShowPanel: { showEditorFormatPanel = true },
                    onLinkToNote: { showNoteLinkPicker = true },
                    onDone: { saveRichTextContent(vm: vm) }
                )
            } else if !vm.isEditing {
                TabletopReaderControls(
                    title: note.title,
                    progress: tabletopReadProgress,
                    canEdit: note.type.isEditable && !vm.needsProtectedSession,
                    onFind: { findControl.isPresented = true },
                    onEdit: { vm.startEditing() }
                )
            }
        }
    }

    /// The open note's keyboard commands (`TrinoteCommands`); `nil` entries disable their menu item.
    private var openNoteActions: OpenNoteActions? {
        guard let vm = viewModel, let note = vm.note else { return nil }
        let readable = !vm.needsProtectedSession
        // Canvas, mind map and spreadsheet editors save through their own bridges; the shortcut
        // only finishes editors whose text lives in `editableContent`.
        let finishesWithShortcut: Set<NoteType> = [.text, .code, .markdown, .mermaid]
        let toggleEditing: (() -> Void)? = {
            guard note.type.isEditable, readable else { return nil }
            if vm.isEditing {
                guard finishesWithShortcut.contains(note.type) else { return nil }
                return { if note.type == .text { saveRichTextContent(vm: vm) } else { vm.saveContent() } }
            }
            return { vm.startEditing() }
        }()
        return OpenNoteActions(
            isEditing: vm.isEditing,
            toggleEditing: toggleEditing,
            find: !vm.isEditing && note.type.supportsReadOnlyOnPageFind ? { findControl.isPresented = true } : nil,
            exportMarkdown: !vm.isEditing && readable ? { exportMarkdown(note: note) } : nil,
            summarize: readable && NoteSummaryModel.isAvailable && Self.summarizableTypes.contains(note.type)
                ? { summarizeFinishingEdit(vm: vm, note: note) } : nil
        )
    }

    var body: some View {
        bodyWithLifecycle
            .focusedValue(\.openNoteActions, openNoteActions)
            .fileExporter(
                isPresented: Binding(get: { markdownExport != nil }, set: { if !$0 { markdownExport = nil } }),
                document: markdownExport,
                contentType: .folder,
                defaultFilename: markdownExportFilename
            ) { result in
                switch result {
                case .success:
                    markdownExportMessage = String(localized: "Exported \(pendingMarkdownExportSummary).", comment: "Markdown export done; argument lists what was saved")
                case .failure(let error):
                    markdownExportMessage = error.localizedDescription
                }
            }
            .alert(
                String(localized: "Export as Markdown", comment: "Markdown export alert title"),
                isPresented: Binding(get: { markdownExportMessage != nil }, set: { if !$0 { markdownExportMessage = nil } }),
                actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
                message: { Text(markdownExportMessage ?? "") }
            )
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                // A hardware keyboard reports a tiny or zero frame; only a real on-screen keyboard counts.
                let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
                isSoftwareKeyboardVisible = frame.height > 120
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isSoftwareKeyboardVisible = false
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: isTabletopLayout)
            .fullScreenCover(item: $editorFullscreenCover, onDismiss: {
                EditorCameraCapture.endPortraitSession()
            }) { cover in
                editorFullscreenCoverContent(cover)
            }
    }

    @ViewBuilder
    private func editorFullscreenCoverContent(_ cover: EditorFullscreenCover) -> some View {
        switch cover {
        case .photoLibrary:
            PhotoLibraryPickerView { images in
                editorFullscreenCover = nil
                Task { await handleEditorPhotoPicks(images) }
            } onCancel: {
                editorFullscreenCover = nil
                editorWebView?.evaluateJavaScript(
                    "try{window.editorBridge.clearPendingMediaInsert()}catch(e){}",
                    completionHandler: nil
                )
            }
        case .camera:
            CameraPickerView(imageToInsert: $imageToInsert) {
                editorFullscreenCover = nil
            }
            .ignoresSafeArea()
        }
    }

    private var bodyWithLifecycle: some View {
        bodyWithEditingLifecycle
    }

    /// Loading, navigation and the bottom inset (tabletop deck or open-tab bar).
    private var bodyNavigationLifecycle: some View {
        bodyCore
            // Full-size clear host — zero-frame backgrounds often never attach under NavigationStack.
            .background {
                NavigationPopGestureBlocker(blocked: shouldBlockNavigationPopGesture, label: "NoteDetail")
            }
            .onChange(of: shouldBlockNavigationPopGesture) { _, blocked in
                // TEMP: mind-map swipe-back diagnosis
                let type = viewModel?.note?.type.rawValue ?? "nil"
                Log.popGesture.info("NoteDetail shouldBlock=\(blocked) noteType=\(type, privacy: .public) editing=\(viewModel?.isEditing == true)")
            }
            .task(id: activeNoteId) { await initialLoad() }
            .alert(
                String(localized: "Favorite Not Changed", comment: "Favorite toggle error title"),
                isPresented: Binding(get: { favoriteError != nil }, set: { if !$0 { favoriteError = nil } }),
                actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
                message: { Text(favoriteError ?? "") }
            )
            .onChange(of: activeNoteId) { _, _ in
                recordShownNote()
                summaryModel.dismiss()
            }
            .onChange(of: activeOpenTabId) { _, _ in recordShownNote() }
            .navigationDestination(item: $navigateToNoteId) { linkedNoteId in
                NoteDetailView(noteId: linkedNoteId, title: "", startInEditMode: false)
            }
            .navigationDestination(item: $navigateToNoteForEdit) { target in
                NoteDetailView(noteId: target.noteId, title: target.title, startInEditMode: true)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isTabletopLayout, let vm = viewModel, let note = vm.note {
                    tabletopDeck(vm: vm, note: note)
                } else if showNoteTabsBar, openNoteTabListNonEmpty, viewModel?.isEditing != true {
                    NoteTabsBar(
                        currentOpenTabId: activeOpenTabId,
                        onSelect: { selectOpenNoteTab($0) },
                        onOpenTabRemoved: { handleOpenTabRemoved($0) },
                        onTabsBecameEmpty: {
                            LastActiveOpenTabStore.set("", profileId: appState.activeProfile?.id)
                        },
                        onReorderActiveChanged: { isTabBarReordering = $0 }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
    }

    /// Editing, autosave and open-tab bookkeeping; split from `bodyWithLifecycle` so the type checker copes.
    private var bodyWithEditingLifecycle: some View {
        bodyNavigationLifecycle
            .modifier(EditingToolbarCompression(isEditing: viewModel?.isEditing == true))
            // Redesign canvas: white in light mode, the ground color in dark mode.
            .background(Color(uiColor: .trinoteEditorCanvas).ignoresSafeArea())
            // Hidden while editing, and on phone whenever a note is open (redesign §3).
            .toolbar(viewModel?.isEditing == true || horizontalSizeClass == .compact ? .hidden : .visible, for: .tabBar)
            .onChange(of: viewModel?.isEditing == true, initial: true) { _, editing in
                if editing {
                    // A restored draft isn't saved yet, so autosave it like an edit.
                    if let vm = viewModel, vm.editSessionStartedFromDraft { scheduleAutosave(vm: vm) }
                } else {
                    // Saved (or dropped): from here on it is an ordinary note.
                    isFreshEmptyNote = false
                    cancelScheduledAutosave()
                    leaveEditorAfterMediaUpload = false
                    // The editor is gone; a later save mustn't read its web view.
                    editorWebView = nil
                }
            }
            .onChange(of: noteEditorAutosave) { _, on in
                if !on { cancelScheduledAutosave() }
            }
            .confirmationDialog(
                String(localized: "Save changes?", comment: "Back while editing: ask whether to save the note"),
                isPresented: $showSaveOnLeave,
                titleVisibility: .visible
            ) {
                if let vm = viewModel, let note = vm.note {
                    Button(String(localized: "Save", comment: "Save")) { saveAndLeave(vm: vm) }
                    Button(String(localized: "Don't Save", comment: "Back while editing: leave without saving"), role: .destructive) {
                        discardNoteEditing(vm: vm, note: note)
                        leaveNote()
                    }
                }
                Button(String(localized: "Cancel", comment: "Alert dismiss"), role: .cancel) {}
            }
            .onChange(of: viewModel?.mediaUploadStatus == nil) { _, uploadsDone in
                guard uploadsDone, let vm = viewModel, vm.isEditing else { return }
                if leaveEditorAfterMediaUpload {
                    leaveEditorAfterMediaUpload = false
                    leaveEditor(vm: vm)
                } else if vm.autosaveStatus == .edited {
                    // Autosave waits while photos upload.
                    scheduleAutosave(vm: vm)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel?.isEditing == true)
            .onChange(of: viewModel?.note?.noteId) { _, _ in refreshOpenNoteTabListNonEmpty() }
            .onChange(of: viewModel?.shouldDismissAfterServerDeletion) { _, shouldDismiss in
                if shouldDismiss == true { dismiss() }
            }
            .onChange(of: showNoteTabsBar) { _, _ in refreshOpenNoteTabListNonEmpty() }
            .onChange(of: activeOpenTabId) { _, newTab in
                if let newTab {
                    LastActiveOpenTabStore.set(newTab, profileId: appState.activeProfile?.id)
                } else {
                    LastActiveOpenTabStore.set("", profileId: appState.activeProfile?.id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openNoteTabsChanged)) { _ in
                refreshOpenNoteTabListNonEmpty()
                validateOrphanedActiveOpenTabId()
            }
            .onAppear {
                refreshOpenNoteTabListNonEmpty()
                if showNoteTabsBar, let t = activeOpenTabId { LastActiveOpenTabStore.set(t, profileId: appState.activeProfile?.id) }
                if showNoteTabsBar, retargetActiveOpenTab { restoreActiveOpenTabToCurrentNoteIfDrifted() }
            }
            .onDisappear {
                persistReadScrollFractionForActiveOpenTab()
                viewModel?.persistEditingDraftIfNeeded()
                if let vm = viewModel { autosaveNow(vm: vm) }
                ReviewPrompt.noteClosed()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background || phase == .inactive {
                    persistReadScrollFractionForActiveOpenTab()
                    viewModel?.persistEditingDraftIfNeeded()
                    if let vm = viewModel { autosaveNow(vm: vm) }
                }
            }
            .onChange(of: appState.activeProfile?.id) { _, _ in
                dismiss()
            }
            .onChange(of: navigateToNoteId) { oldValue, newValue in
                guard oldValue != nil, newValue == nil else { return }
                if showNoteTabsBar, retargetActiveOpenTab { restoreActiveOpenTabToCurrentNoteIfDrifted() }
            }
            .overlay { bodyChangeListeners }
    }

    /// Saves whichever editor is open, fetching the latest state from its web view first.
    /// - Parameter completion: `true` once the note is saved, or when there was nothing to save because the
    ///   editor hadn't loaded, so it's fine to leave; `false` when saving failed and the editor stays open.
    private func saveEditedContent(vm: NoteDetailViewModel, note: NoteItem, completion: ((Bool) -> Void)? = nil) {
        switch note.type {
        case .canvas:
            saveCanvasContent(vm: vm, completion: completion)
        case .spreadsheet:
            saveSpreadsheetContent(vm: vm, completion: completion)
        case .mindMap:
            saveMindMapContent(vm: vm, completion: completion)
        default:
            saveRichTextContent(vm: vm, completion: completion)
        }
    }

    // MARK: - Autosave and Back saving (issue #26)

    /// Restarts the countdown after an edit: the note saves once editing pauses for the chosen delay.
    private func scheduleAutosave(vm: NoteDetailViewModel) {
        guard noteEditorAutosave, vm.isEditing else { return }
        autosaveTask?.cancel()
        let delay = NoteEditorSaving.autosaveDelay(forStored: noteEditorAutosaveDelay)
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            autosaveEditedContent(vm: vm)
        }
    }

    private func cancelScheduledAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    /// Reads the open editor's latest content and saves it without leaving the editor.
    private func autosaveEditedContent(vm: NoteDetailViewModel) {
        guard vm.isEditing, let note = vm.note else { return }
        switch note.type {
        case .text:
            guard let wv = editorWebView else {
                vm.autosaveRichText(freshHTML: nil)
                return
            }
            wv.evaluateJavaScript(Self.richTextEditorSavePayloadScript) { result, _ in
                DispatchQueue.main.async {
                    vm.autosaveRichText(freshHTML: Self.parseRichTextEditorSavePayload(result).html)
                }
            }
        case .canvas:
            // The SVG preview uploads when the editor closes, not on every autosave.
            canvasEditorBridge.getSceneData { json, _ in
                DispatchQueue.main.async { vm.autosaveCanvas(json: json) }
            }
        case .mindMap:
            mindMapEditorBridge.getMapData { json in
                DispatchQueue.main.async { vm.autosaveMindMap(json: json) }
            }
        case .spreadsheet:
            spreadsheetEditorBridge.getWorkbook { json in
                DispatchQueue.main.async { vm.autosaveSpreadsheet(json: json) }
            }
        default:
            vm.autosaveEditedBody(vm.editableContent)
        }
    }

    /// The editor may be going away (or the app leaving the foreground): save now instead of waiting.
    private func autosaveNow(vm: NoteDetailViewModel) {
        guard noteEditorAutosave, vm.isEditing else { return }
        cancelScheduledAutosave()
        vm.autosaveLatestKnownContent()
        autosaveEditedContent(vm: vm)
    }

    /// Back (or ⌘[) while editing: saves first when Autosave or Back Button Saves is on, then leaves.
    private func leaveEditor(vm: NoteDetailViewModel) {
        guard vm.isEditing, vm.note != nil else {
            leaveNote()
            return
        }
        guard savesWhenLeavingEditor else {
            // Ask: save and go back, or go back without saving (TestFlight feedback).
            showSaveOnLeave = true
            return
        }
        saveAndLeave(vm: vm)
    }

    /// Pops the note when it was pushed; as a column's root there is nothing to pop.
    private func leaveNote() {
        if isPresentedInStack { dismiss() }
    }

    /// After a fresh empty note was dropped: off the screen, wherever it was shown.
    private func leaveDeletedNote() {
        if isPresentedInStack { dismiss() } else { noteStack?.closeNote() }
    }

    private func saveAndLeave(vm: NoteDetailViewModel) {
        guard let note = vm.note else { return }
        guard !isLeavingEditor else { return }
        if vm.mediaUploadStatus != nil {
            // Saving now would miss the photos still uploading.
            leaveEditorAfterMediaUpload = true
            return
        }
        cancelScheduledAutosave()
        isLeavingEditor = true
        saveEditedContent(vm: vm, note: note) { canLeave in
            isLeavingEditor = false
            if canLeave { leaveNote() }
        }
    }

    /// Under the title while editing with Autosave on.
    private func autosaveStatusText(_ vm: NoteDetailViewModel) -> String? {
        guard noteEditorAutosave, vm.isEditing else { return nil }
        switch vm.autosaveStatus {
        case .idle:
            return nil
        case .edited:
            return String(localized: "Edited", comment: "Editor status under the note title: changes not autosaved yet")
        case .saved:
            return vm.isOnline
                ? String(localized: "Saved", comment: "Editor status under the note title: changes autosaved")
                : String(localized: "Saved on this device", comment: "Editor status under the note title: autosaved while offline; uploads when back online")
        }
    }

    private func refreshOpenNoteTabListNonEmpty() {
        guard let p = appState.activeProfile?.id else {
            openNoteTabListNonEmpty = false
            return
        }
        let n = PersistenceManager.shared.openNoteTabCount(serverProfileId: p)
        openNoteTabListNonEmpty = n > 0
    }

    @ViewBuilder
    private var bodyCore: some View {
        let barsAtSide = postureMonitor?.geometry.barsAtSide == true
        Group {
            if let viewModel {
                noteContent(viewModel)
            } else {
                ProgressView()
            }
        }
        // The Duo's cover display puts the bar's buttons down the side and left an empty band
        // above the note (TestFlight feedback); there the note starts at the top instead.
        .padding(.top, barsAtSide ? 10 : 0)
        .ignoresSafeArea(.container, edges: barsAtSide ? .top : [])
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationBarBackButtonHidden(viewModel?.isEditing == true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The note buttons appear once it loads. Until then this keeps the bar filled, so
            // iOS does not show the large-title bar of Recents or Favorites for a moment.
            if viewModel?.note == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .toolbar {
            if viewModel?.isEditing == true {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if let vm = viewModel {
                            leaveEditor(vm: vm)
                        } else {
                            dismiss()
                        }
                    } label: {
                        if isLeavingEditor || leaveEditorAfterMediaUpload {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(String(localized: "Back", comment: "Back from note detail"), systemImage: "chevron.left")
                                .labelStyle(.iconOnly)
                        }
                    }
                    .disabled(isLeavingEditor || leaveEditorAfterMediaUpload)
                    .accessibilityLabel(String(localized: "Back", comment: "Back button on note detail"))
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        // Only once the server check is done: while it's still running the note isn't offline.
                        if let vm = viewModel, !vm.serverVerified, vm.serverCheckFinished, vm.note != nil {
                            Image(systemName: "icloud.slash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let vm = viewModel, let status = autosaveStatusText(vm) {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // The note header shows the title large, so the bar leaves it out. The item
                    // itself stays: removing the title (toolbar(removing: .title)) left the bar
                    // empty until the note's buttons loaded, and iOS briefly kept the tall bar of
                    // Recents or Favorites, so the note jumped up.
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
            }
        }
        .sheet(item: $noteDetailShareSheetItem) { item in
            ShareSheet(items: item.items)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private func initialLoad() async {
        if viewModel == nil {
            NoteOpenTrace.begin(
                noteId: activeNoteId,
                "initialLoad tabsBar=\(showNoteTabsBar) openTabId=\(openTabId ?? "nil") activeOpenTabId=\(activeOpenTabId ?? "nil") pendingRestore=\(readOnlyScrollFractionPendingRestore.map { "\($0)" } ?? "nil") coverPending=\(isReadOnlyScrollRevealPending)"
            )
            // Mask before the first content paint whenever we already know a mid-note scroll
            // restore is coming — otherwise cached HTML flashes, then the spinner covers it.
            seedReadScrollRevealBeforeContentPaint(for: activeNoteId)
            NoteOpenTrace.log("after seed pendingRestore=\(readOnlyScrollFractionPendingRestore.map { "\($0)" } ?? "nil") coverPending=\(isReadOnlyScrollRevealPending)")
            let vm = NoteDetailViewModel(noteId: activeNoteId, appState: appState, seedChildSummaries: seedChildSummaries)
            viewModel = vm
            if showNoteTabsBar, retargetActiveOpenTab { eagerRetargetActiveOpenTabFromCache() }
            async let loadTask: () = vm.load()
            async let contentTask: () = vm.loadContent()
            async let attachTask: () = vm.loadAttachments()
            async let childTask: () = vm.loadChildNotes()
            await loadTask
            NoteOpenTrace.log("vm.load done type=\(vm.note?.type.rawValue ?? "nil") isLoadingContent=\(vm.isLoadingContent)")
            // Flip into edit mode as soon as `note` is available so SwiftUI never renders the read
            // layout for a frame before the editor takes over. Only the new-note flow sets
            // `startInEditMode` (TreeView.noteEditDestination), so `editableContent` being empty at
            // this point is correct — there's no existing content to wait on.
            if startInEditMode, vm.note != nil {
                isFreshEmptyNote = FreshEmptyNotes.take(vm.noteId)
                vm.startEditing()
            }
            _ = await (contentTask, attachTask, childTask)
            NoteOpenTrace.log("content/attachments/children loaded contentUtf16=\(vm.contentString?.utf16.count ?? -1) isLoadingContent=\(vm.isLoadingContent)")
            await vm.prefetchChildNotesForGeoMapBookIfNeeded()
        }
        if showNoteTabsBar { reconcileOpenTabsAfterLoad() }
    }

    /// Resolves the open-tab scroll fraction for `noteId` and arms the reveal mask *before*
    /// `viewModel` publishes body HTML, so the first frame never paints mid-restore content.
    private func seedReadScrollRevealBeforeContentPaint(for noteId: String) {
        guard showNoteTabsBar, let p = appState.activeProfile?.id else { return }
        let pm = PersistenceManager.shared
        // A tab's saved position belongs to the note it shows. The last active tab usually shows the
        // previous note (it's retargeted to this one after load), so borrowing its position would mask
        // this note until the restore gave up.
        func tabShowingThisNote(_ id: String) -> String? {
            guard let tab = try? pm.fetchOpenNoteTab(id: id, serverProfileId: p) else { return nil }
            guard tab.noteId == noteId else {
                NoteOpenTrace.log("tab \(id) shows \(tab.noteId), not this note; not restoring its position")
                return nil
            }
            return id
        }
        let tabId: String? = {
            if let t = activeOpenTabId ?? openTabId, let id = tabShowingThisNote(t) {
                return id
            }
            if !persistedLastActiveOpenTabId.isEmpty, let id = tabShowingThisNote(persistedLastActiveOpenTabId) {
                return id
            }
            return try? pm.findPreferredOpenTabId(for: noteId, serverProfileId: p)
        }()
        guard let tabId else { return }
        applyReadScrollStateFromStoreForOpenTabId(tabId)
    }

    /// Synchronously retargets the active open tab to `activeNoteId` using cached metadata, so the tab strip updates immediately when navigating instead of waiting for the destination note's network/file load.
    private func eagerRetargetActiveOpenTabFromCache() {
        guard let p = appState.activeProfile?.id else { return }
        let pm = PersistenceManager.shared
        guard pm.openNoteTabCount(serverProfileId: p) > 0 else { return }

        var tabId: String? = activeOpenTabId
        if tabId == nil, let o = self.openTabId,
           (try? pm.fetchOpenNoteTab(id: o, serverProfileId: p)) != nil {
            tabId = o
        }
        if tabId == nil, !persistedLastActiveOpenTabId.isEmpty,
           (try? pm.fetchOpenNoteTab(id: persistedLastActiveOpenTabId, serverProfileId: p)) != nil {
            tabId = persistedLastActiveOpenTabId
        }
        if tabId == nil, let m = try? pm.mostRecentlyAddedOpenNoteTabId(serverProfileId: p) {
            tabId = m
        }

        guard let t = tabId,
              let row = try? pm.fetchOpenNoteTab(id: t, serverProfileId: p),
              row.noteId != activeNoteId else { return }

        let cached = try? pm.fetchCachedNote(id: activeNoteId, serverProfileId: p)
        let resolvedTitle: String = {
            if let c = cached, !c.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return c.title }
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? row.title : title
        }()
        let resolvedType = cached?.noteType ?? row.noteType

        do {
            try pm.retargetOpenNoteTab(
                id: t,
                to: activeNoteId,
                title: resolvedTitle,
                noteType: resolvedType,
                serverProfileId: p
            )
            // The saved position was the previous note's; applied after load it would open this note partway down
            // (or under the reveal cover until the restore gave up, when this note is shorter).
            OpenTabSessionStore.clearReadScrollState(for: t)
        } catch {}
        if activeOpenTabId == nil { activeOpenTabId = t }
    }

    private func reconcileOpenTabsAfterLoad() {
        guard showNoteTabsBar, let p = appState.activeProfile?.id, let n = viewModel?.note else { return }
        let pm = PersistenceManager.shared
        let count = pm.openNoteTabCount(serverProfileId: p)
        refreshOpenNoteTabListNonEmpty()

        if !retargetActiveOpenTab {
            if count == 0 {
                if let newId = try? pm.ensureFirstOpenNoteTabIfEmpty(
                    noteId: n.noteId, title: n.title, noteType: n.type.rawValue, serverProfileId: p
                ) { activeOpenTabId = newId }
            } else {
                if activeOpenTabId == nil, !persistedLastActiveOpenTabId.isEmpty,
                   (try? pm.fetchOpenNoteTab(id: persistedLastActiveOpenTabId, serverProfileId: p)) != nil {
                    activeOpenTabId = persistedLastActiveOpenTabId
                }
                if activeOpenTabId == nil, let t = try? pm.findPreferredOpenTabId(
                    for: n.noteId, serverProfileId: p
                ) { activeOpenTabId = t }
            }
            if let t = activeOpenTabId { applyReadScrollStateFromStoreForOpenTabId(t) }
            return
        }

        if count == 0 {
            if let newId = try? pm.ensureFirstOpenNoteTabIfEmpty(
                noteId: n.noteId, title: n.title, noteType: n.type.rawValue, serverProfileId: p
            ) { activeOpenTabId = newId }
            if let t = activeOpenTabId { applyReadScrollStateFromStoreForOpenTabId(t) }
            return
        }

        if let cur = activeOpenTabId, (try? pm.fetchOpenNoteTab(id: cur, serverProfileId: p)) != nil {
            resolveRetargetToCurrentNote(pm: pm, p: p, n: n, tabId: cur)
            return
        }

        if let o = self.openTabId, (try? pm.fetchOpenNoteTab(id: o, serverProfileId: p)) != nil {
            activeOpenTabId = o
            resolveRetargetToCurrentNote(pm: pm, p: p, n: n, tabId: o)
            return
        }

        if !persistedLastActiveOpenTabId.isEmpty,
           (try? pm.fetchOpenNoteTab(id: persistedLastActiveOpenTabId, serverProfileId: p)) != nil {
            activeOpenTabId = persistedLastActiveOpenTabId
        }
        if activeOpenTabId == nil, let m = try? pm.mostRecentlyAddedOpenNoteTabId(serverProfileId: p) {
            activeOpenTabId = m
        }
        if let t = activeOpenTabId { resolveRetargetToCurrentNote(pm: pm, p: p, n: n, tabId: t) }
    }

    /// Re-runs after popping back from a pushed sub-note so the active tab points at *this* view's note again. Skips work if the tab already matches; never moves this view's scroll position.
    private func restoreActiveOpenTabToCurrentNoteIfDrifted() {
        guard let p = appState.activeProfile?.id,
              let n = viewModel?.note,
              let t = activeOpenTabId else { return }
        let pm = PersistenceManager.shared
        guard let row = try? pm.fetchOpenNoteTab(id: t, serverProfileId: p) else { return }
        if row.noteId == n.noteId { return }
        do {
            try pm.retargetOpenNoteTab(
                id: t,
                to: n.noteId,
                title: n.title,
                noteType: n.type.rawValue,
                serverProfileId: p
            )
            // The tab still holds the pushed note's position; this view kept its own, so store that.
            persistReadScrollPosition(for: t)
        } catch {}
    }

    private func resolveRetargetToCurrentNote(
        pm: PersistenceManager, p: String, n: NoteItem, tabId: String
    ) {
        guard let row = try? pm.fetchOpenNoteTab(id: tabId, serverProfileId: p) else { return }
        if row.noteId == n.noteId {
            applyReadScrollStateFromStoreForOpenTabId(tabId)
            return
        }
        do {
            try pm.retargetOpenNoteTab(
                id: tabId,
                to: n.noteId,
                title: n.title,
                noteType: n.type.rawValue,
                serverProfileId: p
            )
        } catch {}
        OpenTabSessionStore.clearReadScrollState(for: tabId)
        scrollTracking.fraction = 0
        readOnlyScrollFractionPendingRestore = nil
        isReadOnlyScrollRevealPending = false
        lastAppliedReadScrollTabId = tabId
    }

    /// A tab's saved position belongs to the note it shows. Opening a note from the tree keeps the last active
    /// tab selected while it still shows the previous note, so its position must neither be applied to this
    /// note nor overwritten by it.
    private func openTab(_ id: String, shows noteId: String) -> Bool {
        guard let p = appState.activeProfile?.id,
              let tab = try? PersistenceManager.shared.fetchOpenNoteTab(id: id, serverProfileId: p)
        else { return false }
        return tab.noteId == noteId
    }

    /// - Parameter expectedNoteId: The note the tab should show; defaults to the note on screen.
    private func applyReadScrollStateFromStoreForOpenTabId(_ id: String, showing expectedNoteId: String? = nil) {
        if lastAppliedReadScrollTabId == id { return }
        guard openTab(id, shows: expectedNoteId ?? activeNoteId) else {
            NoteOpenTrace.log("tab \(id) doesn't show \(expectedNoteId ?? activeNoteId); not applying its position")
            return
        }

        // Opened from a search match: the tab's saved position would scroll away from it.
        let skipsRestore = opensAtFindMatch && activeNoteId == noteId
        if !skipsRestore, let f = OpenTabSessionStore.readReadScrollFraction(for: id) {
            let offset = OpenTabSessionStore.readReadScrollOffset(for: id)
            scrollTracking.fraction = f
            scrollTracking.offset = offset
            readOnlyScrollFractionPendingRestore = f
            readOnlyScrollOffsetPendingRestore = offset.map { PendingReadScrollOffset(fraction: f, offset: $0) }
            isReadOnlyScrollRevealPending = f > Self.readOnlyScrollRevealMaskThreshold
            NoteOpenTrace.log("tab \(id) saved fraction=\(f) → coverPending=\(isReadOnlyScrollRevealPending)")
        } else {
            NoteOpenTrace.log("tab \(id) no saved fraction (skipsRestore=\(skipsRestore))")
            scrollTracking.fraction = 0
            scrollTracking.offset = nil
            readOnlyScrollFractionPendingRestore = nil
            readOnlyScrollOffsetPendingRestore = nil
            isReadOnlyScrollRevealPending = false
        }
        lastAppliedReadScrollTabId = id
    }

    /// Fraction to persist: target restore position while layout is settling, else live scroll.
    private var readOnlyScrollFractionToPersist: CGFloat {
        readOnlyScrollFractionPendingRestore ?? scrollTracking.fraction
    }

    /// The pending restore's position in points, when it has one.
    private var pendingRestoreOffset: ReadScrollOffset? {
        guard let pending = readOnlyScrollOffsetPendingRestore,
              pending.fraction == readOnlyScrollFractionPendingRestore else { return nil }
        return pending.offset
    }

    /// Position in points to persist alongside `readOnlyScrollFractionToPersist` (same rule).
    private var readOnlyScrollOffsetToPersist: ReadScrollOffset? {
        readOnlyScrollFractionPendingRestore != nil ? pendingRestoreOffset : scrollTracking.offset
    }

    private func persistReadScrollPosition(for tabId: String) {
        OpenTabSessionStore.saveReadScrollFraction(readOnlyScrollFractionToPersist, for: tabId)
        OpenTabSessionStore.saveReadScrollOffset(readOnlyScrollOffsetToPersist, for: tabId)
    }

    /// Writes the current read-only scroll fraction for the active open tab (same store as tab switches).
    private func persistReadScrollFractionForActiveOpenTab() {
        guard let tabId = activeOpenTabId ?? openTabId, openTab(tabId, shows: activeNoteId) else { return }
        persistReadScrollPosition(for: tabId)
    }

    private func recordShownNote() {
        guard let routeId, let noteStack else { return }
        noteStack.recordShownNote(
            NoteStack.ShownNote(noteId: activeNoteId, openTabId: activeOpenTabId),
            forRoute: routeId
        )
    }

    private func selectOpenNoteTab(_ tab: OpenNoteTab) {
        guard appState.activeProfile?.id == tab.serverProfileId else { return }
        if let prev = activeOpenTabId, prev != tab.id {
            if openTab(prev, shows: activeNoteId) {
                persistReadScrollPosition(for: prev)
            }
            lastAppliedReadScrollTabId = prev
        }
        if tab.noteId == activeNoteId {
            if tab.id == activeOpenTabId { return }
            activeOpenTabId = tab.id
            applyReadScrollStateFromStoreForOpenTabId(tab.id)
            presentFloatingEditOnOpenTabSwitch()
            return
        }
        activeOpenTabId = tab.id
        applyReadScrollStateFromStoreForOpenTabId(tab.id, showing: tab.noteId)
        viewModel = nil
        // The next note mustn't save through this one's editor.
        editorWebView = nil
        activeNoteId = tab.noteId
    }

    private func handleOpenTabRemoved(_ removed: OpenNoteTab) {
        OpenTabSessionStore.clearReadScrollState(for: removed.id)
        guard removed.id == activeOpenTabId, let p = appState.activeProfile?.id else { return }
        activeOpenTabId = nil
        let all = (try? PersistenceManager.shared.fetchOpenNoteTabs(serverProfileId: p)) ?? []
        if all.isEmpty {
            LastActiveOpenTabStore.set("", profileId: appState.activeProfile?.id)
        } else if let n = viewModel?.note, let m = all.filter({ $0.noteId == n.noteId }).max(by: { $0.addedAt < $1.addedAt }) {
            selectOpenNoteTab(m)
        } else if let a = all.max(by: { $0.addedAt < $1.addedAt }) {
            selectOpenNoteTab(a)
        }
    }

    private func validateOrphanedActiveOpenTabId() {
        guard let p = appState.activeProfile?.id else { return }
        if PersistenceManager.shared.openNoteTabCount(serverProfileId: p) == 0 {
            activeOpenTabId = nil
            LastActiveOpenTabStore.set("", profileId: appState.activeProfile?.id)
            return
        }
        guard let t = activeOpenTabId else { return }
        if (try? PersistenceManager.shared.fetchOpenNoteTab(id: t, serverProfileId: p)) != nil { return }
        activeOpenTabId = nil
        guard let n = viewModel?.note else { return }
        if let u = try? PersistenceManager.shared.findPreferredOpenTabId(
            for: n.noteId, serverProfileId: p
        ), let row = try? PersistenceManager.shared.fetchOpenNoteTab(id: u, serverProfileId: p) {
            selectOpenNoteTab(row)
        } else {
            LastActiveOpenTabStore.set("", profileId: appState.activeProfile?.id)
        }
    }

    @ViewBuilder
    private var bodyChangeListeners: some View {
        let needsProtected: Bool? = viewModel?.needsProtectedSession
        let protectedActive: Bool = appState.protectedSessionActive
        let content: String? = viewModel?.contentString
        let loading: Bool? = viewModel?.isLoadingContent
        let editing: Bool? = viewModel?.isEditing

        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .trinoteOfflineNoteIdReplaced)) { notification in
                guard let from = notification.userInfo?["from"] as? String,
                      let to = notification.userInfo?["to"] as? String,
                      from == activeNoteId
                else { return }
                // Migrate the existing view model in place rather than tearing it down. Rebuilding
                // would unmount the (possibly already open) editor and re-run `initialLoad`, producing
                // the "detail → editor → detail → editor" flash users see right after creating a note.
                viewModel?.migrateAfterOfflineIdReplacement(to: to)
                activeNoteId = to
            }
            .onChange(of: needsProtected) { _, needs in
                if needs == false { protectedDocumentPassword = "" }
                if needs == false, pendingFindQuery != nil {
                    findDeepLinkConsumed = false
                    consumeFindDeepLinkIfNeeded()
                }
            }
            .onChange(of: protectedActive) { _, _ in
                guard let vm = viewModel else { return }
                Task { await vm.resyncNoteTitlesWithProtectedSession() }
            }
            .onChange(of: content) { _, _ in
                consumeFindDeepLinkIfNeeded()
            }
            .onChange(of: loading) { _, isLoading in
                if isLoading == false {
                    consumeFindDeepLinkIfNeeded()
                }
            }
            .onChange(of: editing) { _, isEditing in
                if isEditing == true {
                    findDeepLinkConsumed = true
                }
            }
            .onChange(of: appState.syncManager.phase) { _, phase in
                guard phase == .done else { return }
                guard let vm = viewModel else { return }
                Task {
                    await vm.loadChildNotes()
                    guard let n = vm.note,
                          isGeoMapNote(n, contentString: vm.contentString, vm: vm) else { return }
                    loadGeoMapPins(vm: vm, note: n)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .trinoteTreeShouldRefresh)) { notification in
                guard let vm = viewModel, let n = vm.note,
                      isGeoMapNote(n, contentString: vm.contentString, vm: vm) else { return }
                if let rid = notification.userInfo?["noteId"] as? String {
                    guard rid == n.noteId || vm.childNotes.contains(where: { $0.noteId == rid }) else { return }
                } else {
                    return
                }
                Task {
                    loadGeoMapPins(vm: vm, note: n)
                }
            }
    }

    /// Opens the find bar and jumps to a match after the note body is available (search → note deep link).
    private func consumeFindDeepLinkIfNeeded() {
        guard !findDeepLinkConsumed else { return }
        guard let q = pendingFindQuery, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let idx = pendingFindMatchIndex, idx >= 1,
              let vm = viewModel, let note = vm.note,
              note.type.supportsReadOnlyOnPageFind,
              !vm.isEditing,
              !vm.needsProtectedSession,
              !vm.isLoadingContent,
              vm.contentString != nil
        else { return }
        findDeepLinkConsumed = true
        // The match decides where the note scrolls, not the open tab's saved position.
        if readOnlyScrollFractionPendingRestore != nil || isReadOnlyScrollRevealPending {
            readOnlyScrollFractionPendingRestore = nil
            isReadOnlyScrollRevealPending = false
            finishFloatingEditScrollSettling(vm: vm, note: note)
        }
        findControl.prepareFindDeepLink(findQuery: q, matchIndex1Based: idx)
    }

    /// Opened from a search match (see `consumeFindDeepLinkIfNeeded`).
    private var opensAtFindMatch: Bool {
        pendingFindQuery != nil && pendingFindMatchIndex != nil
    }

    private var fileDropHint: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                Label(
                    String(localized: "Drop to Attach to This Note", comment: "iPad: file dragged over a note"),
                    systemImage: "paperclip"
                )
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
            }
            .padding(8)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// Maximum Content Width setting (iPad); the note column is centered within it.
    private var contentWidthLimit: CGFloat {
        NoteContentWidth.limit(forStored: noteMaxContentWidth)
    }

    @ViewBuilder
    private func readOnlyNoteSurface(_ vm: NoteDetailViewModel, note: NoteItem) -> some View {
        readOnlyNoteSurfaceContent(vm, note: note)
            .overlay { NoteDropHighlight(isTargeted: isNoteDropTargeted) }
            .animation(.snappy, value: isNoteDropTargeted)
            .dropDestination(for: NoteClip.self) { clips, _ in
                vm.appendClippedHTML(clips.map(\.html).joined())
            } isTargeted: { targeted in
                isNoteDropTargeted = targeted && vm.canAppendClip
            }
    }

    @ViewBuilder
    private func readOnlyNoteSurfaceContent(_ vm: NoteDetailViewModel, note: NoteItem) -> some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    editorStatusBanner(vm)
                    draftBanner(vm)
                    titleSection(vm, note: note)
                    if summaryModel.isVisible {
                        NoteSummaryCard(
                            model: summaryModel,
                            onRegenerate: { runNoteAI(summaryModel.kind, vm: vm, note: note) },
                            onAddToNote: noteAIApply(vm: vm)
                        )
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                            .transition(.asymmetric(insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity), removal: .opacity))
                    }
                    Divider()
                    notesEditedOnDaySection(vm)
                    noteBody(vm, note: note, findControl: findControl)
                    inlinePDFAttachments(vm, note: note)
                    childNotesSection(vm)
                    relatedNotesSection(note: note)

                    if vm.showDetails, !usesNoteInspector {
                        attachmentsSection(vm)
                        metadataSection(note)
                    }

                    if note.type.isEditable, !vm.needsProtectedSession, !noteEditorLongPressToEdit {
                        Color.clear.frame(
                            height: NoteDetailFloatingChipLayout.scrollClearance(
                                findBarPresented: findControl.isPresented,
                                editing: false
                            )
                        )
                    }
                }
                .background(
                    ZStack {
                        NoteDetailScrollOffsetReader { y, _, fraction, width in
                            if readOnlyScrollFractionPendingRestore == nil {
                                scrollTracking.fraction = fraction
                                scrollTracking.offset = ReadScrollOffset(offsetY: y, layoutWidth: width)
                                // Only the tabletop deck shows progress; elsewhere scrolling stays out of view state.
                                if isTabletopLayout { tabletopReadProgress = fraction }
                            }
                            updateFloatingEditVisibility(
                                contentOffsetY: y,
                                vm: vm,
                                note: note
                            )
                        }
                        NoteDetailReadOnlyScrollRestoration(
                            fraction: readOnlyScrollFractionPendingRestore,
                            offset: pendingRestoreOffset
                        ) { outcome in
                            NoteOpenTrace.log("restore onApplied pending=\(readOnlyScrollFractionPendingRestore.map { "\($0)" } ?? "nil") reached=\(outcome.reachedFraction.map { "\($0)" } ?? "nil") immediate=\(outcome.immediate) coverPending=\(isReadOnlyScrollRevealPending)")
                            // Where the note actually is: a restore that gave up must not save its target back
                            // to the tab, or the next open waits under the cover again.
                            if let position = outcome.reachedFraction ?? readOnlyScrollFractionPendingRestore {
                                scrollTracking.fraction = position
                            }
                            scrollTracking.offset = outcome.reachedOffset ?? pendingRestoreOffset
                            readOnlyScrollFractionPendingRestore = nil
                            readOnlyScrollOffsetPendingRestore = nil
                            if isReadOnlyScrollRevealPending {
                                if outcome.immediate {
                                    // Already at the saved position on the note's first layout: show it as is.
                                    isReadOnlyScrollRevealPending = false
                                } else {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        isReadOnlyScrollRevealPending = false
                                    }
                                }
                            }
                            finishFloatingEditScrollSettling(vm: vm, note: note)
                        }
                    }
                    .frame(width: 0, height: 0)
                )
                .frame(maxWidth: contentWidthLimit)
                .frame(maxWidth: .infinity)
            }
            .simultaneousGesture(longPressToEditGesture(vm: vm, note: note))
            .opacity(isReadOnlyScrollRevealPending ? 0 : 1)

            // Hidden while renaming: with the keyboard up it sat on top of Save.
            if showFloatingEditButton && !vm.editingTitle && !noteEditorLongPressToEdit && !isReadOnlyScrollRevealPending && !isTabletopLayout {
                floatingEditFAB(vm: vm)
                    .padding(.trailing, 16)
                    .padding(.bottom, findControl.isPresented ? 56 : 12)
                    .intoSideStrip(trailingPadding: 16, width: 48)
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .overlay {
            // Solid cover only — a ProgressView made opens feel like flash → spinner → content.
            if isReadOnlyScrollRevealPending {
                Color(uiColor: .trinoteEditorCanvas)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .onAppear { NoteOpenTrace.log("COVER shown (solid systemBackground over the note)") }
                    .onDisappear { NoteOpenTrace.log("COVER hidden") }
            }
        }
        .onDrop(
            of: [.data],
            delegate: NoteFileDropDelegate(
                isEnabled: !vm.needsProtectedSession,
                isTargeted: $isFileDropTargeted,
                onFile: { data, mime, filename in
                    presentAttachmentUploadNamePrompt(data: data, mime: mime, filename: filename)
                }
            )
        )
        .overlay {
            if isFileDropTargeted {
                fileDropHint
            }
        }
        .animation(.easeInOut(duration: 0.22), value: findControl.isPresented)
        .refreshable { await vm.refresh(force: true) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if findControl.isPresented {
                FindOnPageBar(control: findControl)
            }
        }
        .onAppear {
            NoteOpenTrace.log("read surface appeared type=\(note.type.rawValue) isLoadingContent=\(vm.isLoadingContent) hasContent=\(vm.contentString != nil)")
            presentFloatingEditOnNoteOpen(vm: vm, note: note)
            scheduleFloatingEditScrollSettlingEndIfNeeded()
        }
        .onChange(of: note.noteId) { _, _ in
            presentFloatingEditOnNoteOpen(vm: vm, note: note)
            scheduleFloatingEditScrollSettlingEndIfNeeded()
        }
        .onChange(of: vm.isEditing) { _, editing in
            if editing {
                readOnlyScrollFractionPendingRestore = nil
                isReadOnlyScrollRevealPending = false
                findControl.close()
                floatingEditSettlingEndWorkItem?.cancel()
                floatingEditSettlingEndWorkItem = nil
                floatingEditScrollBaselineReady = false
                floatingEditIgnoreDirectionalScroll = true
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    showFloatingEditButton = false
                }
            } else if floatingEditFABEligible(vm: vm, note: note) {
                presentFloatingEditOnNoteOpen(vm: vm, note: note)
                scheduleFloatingEditScrollSettlingEndIfNeeded()
            }
        }
        .onChange(of: vm.needsProtectedSession) { _, needs in
            if needs {
                floatingEditSettlingEndWorkItem?.cancel()
                floatingEditSettlingEndWorkItem = nil
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    showFloatingEditButton = false
                }
                floatingEditScrollBaselineReady = false
                floatingEditIgnoreDirectionalScroll = true
            } else if floatingEditFABEligible(vm: vm, note: note) {
                presentFloatingEditOnNoteOpen(vm: vm, note: note)
                scheduleFloatingEditScrollSettlingEndIfNeeded()
            }
        }
        .onChange(of: noteEditorLongPressToEdit) { _, _ in
            refreshFloatingEditVisibility(vm: vm, note: note)
        }
        .onDisappear {
            findControl.unregisterAll()
        }
    }

    @ViewBuilder
    private func noteContent(_ vm: NoteDetailViewModel) -> some View {
        @Bindable var vm = vm
        if vm.isLoading && vm.note == nil {
            ProgressView(String(localized: "Loading note…", comment: "Note detail loading"))
        } else if let error = vm.error, vm.note == nil {
            ContentUnavailableView {
                Label(String(localized: "Error", comment: "Generic error title"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(String(localized: "Retry", comment: "Retry load")) { Task { await vm.load() } }
                    .buttonStyle(.bordered)
            }
        } else if let note = vm.note {
            let _ = vm.geoMapDetectionTick
            VStack(spacing: 0) {
                // Each branch is type-erased: without AnyView the runtime has to demangle
                // every note mode's view type as one nested generic, which overflows the
                // main thread stack while instantiating the metadata.
                if vm.needsProtectedSession {
                    AnyView(protectedNoteOverlay(vm, note: note))
                } else if note.isCalendarRoot {
                    AnyView(calendarDetailView(vm, note: note))
                } else if isPresentationNote(note) {
                    // Check presentation before kanban: both are book collections; viewType must win.
                    AnyView(presentationDetailView(vm, note: note))
                } else if isKanbanNote(note) {
                    AnyView(kanbanDetailView(vm, note: note))
                } else if isGeoMapNote(note, contentString: vm.contentString, vm: vm) {
                    AnyView(geoMapDetailView(vm, note: note))
                } else if vm.isEditing && note.type == .text {
                    AnyView(
                        VStack(spacing: 0) {
                            editorStatusBanner(vm)
                            // Title, path, last edit and labels stay above the editor (TestFlight feedback).
                            titleSection(vm, note: note)
                            Divider()
                            notesEditedOnDaySection(vm, compact: true)
                            richTextEditingView(vm)
                                .frame(maxWidth: contentWidthLimit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                        .background(Color(uiColor: .trinoteEditorCanvas).ignoresSafeArea(edges: [.bottom, .horizontal]))
                    )
                } else if vm.isEditing && (note.type == .code || note.type == .markdown) {
                    AnyView(
                        VStack(spacing: 0) {
                            editorStatusBanner(vm)
                            // Title, path, last edit and labels stay above the editor (TestFlight feedback).
                            titleSection(vm, note: note)
                            Divider()
                            notesEditedOnDaySection(vm, compact: true)
                            codeEditingView(vm)
                                .frame(maxWidth: contentWidthLimit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                        .background(Color(uiColor: .trinoteEditorCanvas).ignoresSafeArea(edges: [.bottom, .horizontal]))
                    )
                } else if vm.isEditing && note.type == .mermaid {
                    AnyView(mermaidEditingView(vm))
                } else if vm.isEditing && note.type == .mindMap {
                    AnyView(mindMapEditingView(vm))
                } else if vm.isEditing && note.type == .canvas {
                    AnyView(canvasEditingView(vm))
                } else if vm.isEditing && note.type == .spreadsheet && horizontalSizeClass == .regular {
                    AnyView(spreadsheetEditingView(vm))
                } else if note.type == .mindMap {
                    AnyView(mindMapReadOnlyView(vm, note: note))
                } else {
                    AnyView(readOnlyNoteSurface(vm, note: note))
                }
            }
            .toolbar { noteToolbar(vm, note: note) }
            // Only the iPad split layout shows the panel. Anywhere else `.inspector` would still wrap the note,
            // and its container keeps the open-note tabs bar's `safeAreaInset` from reaching it, which put the
            // floating edit button behind that bar.
            .notePanelInspector(enabled: usesNoteInspector, isPresented: noteInspectorBinding) {
                noteInspector(vm, note: note)
                    .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
            }
            .onAppear { loadFavoriteNoteIds() }
            .onChange(of: appState.activeProfile?.id) { _, _ in loadFavoriteNoteIds() }
            .onReceive(NotificationCenter.default.publisher(for: .trinoteTreeShouldRefresh)) { _ in
                guard let vm = viewModel else { return }
                Task {
                    await vm.refreshDirectChildrenMetadataFromServer()
                    guard let n = vm.note else { return }
                    if isGeoMapNote(n, contentString: vm.contentString, vm: vm) {
                        loadGeoMapPins(vm: vm, note: n)
                    }
                }
            }
            .alert(String(localized: "Error", comment: "Save error alert"), isPresented: $vm.showSaveError) {
                Button(String(localized: "OK", comment: "Alert dismiss")) { vm.showSaveError = false }
            } message: {
                Text(vm.saveError ?? String(localized: "An unknown error occurred.", comment: "Generic error"))
            }
            .cancelEditingConfirmation(isPresented: $showCancelEditingConfirm) {
                discardNoteEditing(vm: vm, note: note)
            }
            .alert(
                String(localized: "Export Failed", comment: "Spreadsheet .xlsx export error title"),
                isPresented: Binding(
                    get: { spreadsheetXlsxExportError != nil },
                    set: { if !$0 { spreadsheetXlsxExportError = nil } }
                )
            ) {
                Button(String(localized: "OK", comment: "Alert dismiss")) { spreadsheetXlsxExportError = nil }
            } message: {
                Text(spreadsheetXlsxExportError ?? "")
            }
            .overlay(alignment: .top) {
                if isExportingSpreadsheetXlsx {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Exporting to Excel…", comment: "Spreadsheet .xlsx export in progress"))
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .alert(
                String(localized: "Rename Attachment", comment: "Rename attachment alert title"),
                isPresented: Binding(
                    get: { attachmentRenameContext != nil },
                    set: { if !$0 { attachmentRenameContext = nil } }
                )
            ) {
                TextField(
                    String(localized: "Filename", comment: "Attachment rename basename field"),
                    text: $attachmentRenameBasename
                )
                Button(String(localized: "Cancel", comment: "Cancel"), role: .cancel) {
                    attachmentRenameContext = nil
                }
                Button(String(localized: "Rename", comment: "Rename attachment confirm")) {
                    applyAttachmentRename()
                }
                .disabled(attachmentRenameBasename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                if let ext = attachmentRenameContext?.fileExtension, !ext.isEmpty {
                    Text(String(localized: "Extension: .\(ext)", comment: "Attachment rename extension hint"))
                }
            }
            .attachmentUploadNamePrompt(
                pending: $pendingAttachmentUpload,
                basename: $pendingAttachmentUploadBasename
            ) { item, basename in
                guard let vm = viewModel else { return }
                Task { @MainActor in
                    await confirmPendingAttachmentUpload(item, basename: basename, vm: vm)
                }
            }
            .sheet(isPresented: $vm.showCreateChild) {
                CreateChildNoteSheet(viewModel: vm) { noteId, title in
                    navigateToNoteForEdit = NoteEditTarget(noteId: noteId, title: title)
                }
            }
            .sheet(isPresented: $showAppearancePicker) {
                NoteAppearancePickerSheet(
                    currentIconClass: note.iconClass,
                    currentColorLabel: note.colorLabelValue,
                    onSelectIcon: { iconClass in
                        Task { await vm.setNoteIconClass(iconClass) }
                    },
                    onSelectColor: { colorLabel in
                        Task { await vm.setNoteColor(colorLabel) }
                    }
                )
            }
            .sheet(isPresented: $showCalendarJournalSettings) {
                CalendarJournalSettingsSheet()
                    .presentationDetents([.medium])
            }
            .fullScreenCover(isPresented: Binding(
                get: { vm.isEditing && note.type == .spreadsheet && horizontalSizeClass != .regular },
                set: { newValue in
                    // Cover dismissal (programmatic only — no swipe-down) returns control
                    // to read-only mode. Cancel/Save buttons inside the cover already
                    // toggle vm.isEditing; this setter mainly catches edge cases.
                    if !newValue && vm.isEditing && note.type == .spreadsheet {
                        spreadsheetHasUnsavedChanges = false
                        vm.cancelEditing()
                    }
                }
            )) {
                spreadsheetEditorCover(vm: vm)
            }
            .sheet(isPresented: $showMoveParentPicker) {
                ParentPickerSheet(
                    navigationTitle: String(localized: "Move to…", comment: "Sheet title: pick parent for move"),
                    instruction: String(
                        localized: "Choose where to move the note. Open folders, then tap a note to select it as the new parent.",
                        comment: "Instructions for move note parent picker"
                    ),
                    topLevelButtonTitle: String(localized: "Top level (under Notes)", comment: "Move under root"),
                    onPick: { parentNoteId, title, parentBranchId in
                        if parentNoteId == activeNoteId {
                            vm.saveError = String(localized: "A note cannot be moved under itself.", comment: "Move validation")
                            vm.showSaveError = true
                            showMoveParentPicker = false
                            return
                        }
                        moveNoteDetailConfirm = MoveNoteDetailConfirm(
                            targetParentNoteId: parentNoteId,
                            targetTitle: title,
                            targetParentBranchId: parentBranchId
                        )
                        showMoveParentPicker = false
                    }
                )
                .environment(appState)
            }
            .sheet(isPresented: $showCopyToInstance) {
                if let note = vm.note {
                    CopyToInstanceSheet(note: note, sourceClient: vm.client)
                        .environment(appState)
                }
            }
            .sheet(isPresented: noteOverflowPresentationBinding(asPopover: false)) {
                noteOverflowActionsSheet(vm: vm, note: note)
            }
            .alert(
                String(localized: "Move Note", comment: "Move confirmation title"),
                isPresented: Binding(
                    get: { moveNoteDetailConfirm != nil },
                    set: { if !$0 { moveNoteDetailConfirm = nil } }
                )
            ) {
                Button(String(localized: "Cancel", comment: "Dismiss move confirm"), role: .cancel) {
                    moveNoteDetailConfirm = nil
                }
                Button(String(localized: "Move", comment: "Confirm move note")) {
                    guard let c = moveNoteDetailConfirm else { return }
                    moveNoteDetailConfirm = nil
                    Task {
                        await vm.moveNoteToParent(
                            targetParentNoteId: c.targetParentNoteId,
                            targetParentBranchId: c.targetParentBranchId
                        )
                    }
                }
            } message: {
                if let c = moveNoteDetailConfirm {
                    Text(
                        String(
                            localized: "Move “\(uiTitle(for: note))” under “\(c.targetTitle)”? The note will appear in the new location in the tree.",
                            comment: "Move confirmation from note detail"
                        )
                    )
                }
            }
            .noteDeleteConfirmationAlert(
                isPresented: $vm.showDeleteConfirm,
                title: String(localized: "Delete Note?", comment: "Delete confirm title"),
                message: NoteDeleteConfirmationCopy.singleNoteMessage(title: uiTitle(for: note)),
                erasePermanently: $eraseNotesOnDelete,
                onConfirm: {
                    let erase = eraseNotesOnDelete
                    Task {
                        if await vm.deleteNote(eraseNotes: erase) { dismiss() }
                    }
                },
                onCancel: { eraseNotesOnDelete = false }
            )
            .confirmationDialog(String(localized: "Unsaved Draft", comment: "Draft dialog title"), isPresented: $vm.showDiscardDraft) {
                Button(String(localized: "Restore Draft", comment: "Draft dialog")) { vm.restoreDraft() }
                Button(String(localized: "Discard Draft", comment: "Draft dialog"), role: .destructive) { vm.discardDraft() }
                Button(String(localized: "Cancel", comment: "Draft dialog"), role: .cancel) {}
            } message: {
                Text(String(localized: "You have an unsaved draft for this note. Would you like to restore it?", comment: "Draft dialog message"))
            }
        }
    }

    @ViewBuilder
    private func protectedNoteOverlay(_ vm: NoteDetailViewModel, note: NoteItem) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text(String(localized: "Protected Note", comment: "Protected note gate title"))
                .font(.title2.bold())

            Text(String(localized: "Enter the same document password you use in Trilium for protected notes. It stays active until you sign out or the server ends the session.", comment: "Protected note gate"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            SecureField(String(localized: "Document password", comment: "Protected note placeholder"), text: $protectedDocumentPassword)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 32)

            if let err = vm.protectedUnlockError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button {
                let pwd = protectedDocumentPassword
                Task { await vm.unlockProtectedNote(documentPassword: pwd) }
            } label: {
                Group {
                    if vm.isUnlockingProtected {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(String(localized: "Unlock", comment: "Protected note button"))
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 10)
                .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isUnlockingProtected)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Type-erased: the note page stacks many sections, and their combined SwiftUI type got deep
    /// enough to overflow the main thread's stack when the runtime resolved it (build 42).
    private func editorStatusBanner(_ vm: NoteDetailViewModel) -> AnyView {
        AnyView(editorStatusBannerContent(vm))
    }

    @ViewBuilder
    private func editorStatusBannerContent(_ vm: NoteDetailViewModel) -> some View {
        if let msg = vm.mediaUploadStatus ?? vm.transientEditorMessage {
            HStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.caption)
                Text(msg)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    private func draftBanner(_ vm: NoteDetailViewModel) -> AnyView {
        AnyView(draftBannerContent(vm))
    }

    @ViewBuilder
    private func draftBannerContent(_ vm: NoteDetailViewModel) -> some View {
        if vm.hasDraft && !vm.isEditing {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.clock")
                    .font(.caption)
                Text(String(localized: "Unsaved draft available", comment: "Draft banner"))
                    .font(.caption.weight(.medium))
                Spacer()
                Button(String(localized: "Restore", comment: "Draft banner")) { vm.restoreDraft() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                Button(String(localized: "Discard", comment: "Draft banner")) { vm.discardDraft() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.red)
            }
            .foregroundStyle(.blue)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.blue.opacity(0.08))
        }
    }

    /// PDFs attached to a text note (a scan, an imported document) read in place under the text.
    private func inlinePDFAttachments(_ vm: NoteDetailViewModel, note: NoteItem) -> AnyView {
        AnyView(inlinePDFAttachmentsContent(vm, note: note))
    }

    @ViewBuilder
    private func inlinePDFAttachmentsContent(_ vm: NoteDetailViewModel, note: NoteItem) -> some View {
        let pdfs = vm.attachments.filter { $0.role == "file" && InlinePDFCard.isPDF(mime: $0.mime, title: $0.title) }
        VStack(spacing: 0) {
            ForEach(pdfs) { attachment in
                InlinePDFCard(attachment: attachment, viewModel: vm)
            }
        }
        .task(id: note.noteId) {
            // Attachments otherwise load only with the details; the list is small.
            guard note.type == .text, vm.attachments.isEmpty else { return }
            if vm.isOnline {
                await vm.loadAttachments()
            }
            vm.loadCachedAttachmentsIfNeeded()
        }
    }

    @ViewBuilder
    private func noteTitleIconButton(vm: NoteDetailViewModel, note: NoteItem, width: CGFloat) -> some View {
        let canChange = canChangeNoteAppearance(note)
        Button {
            showAppearancePicker = true
        } label: {
            NoteIconView(
                iconClass: vm.effectiveIconClass(for: note),
                fallbackNoteType: note.iconFallbackNoteType,
                size: .title,
                foregroundStyle: noteDetailTitleForegroundColor(for: note)
            )
            .frame(width: width, alignment: .center)
        }
        .buttonStyle(.plain)
        .disabled(!canChange || vm.isSaving)
        .accessibilityLabel(String(localized: "Change note appearance", comment: "VoiceOver"))
        .accessibilityHidden(!canChange)
    }

    private func canChangeNoteAppearance(_ note: NoteItem) -> Bool {
        guard note.noteId != TriliumTreeConstants.rootNoteId else { return false }
        if note.isProtected, !appState.protectedSessionActive { return false }
        return true
    }

    /// Renaming: the title at its own size, wrapping over as many lines as it needs, with Cancel and
    /// Save on a row below so they never run off the screen (TestFlight feedback).
    @ViewBuilder
    private func titleEditor(_ vm: NoteDetailViewModel, note: NoteItem) -> some View {
        @Bindable var vm = vm
        VStack(alignment: .trailing, spacing: 10) {
            TextField(String(localized: "Title", comment: "Note title field"), text: $vm.editedTitle, axis: .vertical)
                .headingFont(30)
                .foregroundStyle(noteDetailTitleForegroundColor(for: note))
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .submitLabel(.done)
                .focused($isTitleFieldFocused)
                .onSubmit { Task { await vm.renameNote() } }
                // The vertical axis turns Return into a new line; a title has none, so Return saves.
                .onChange(of: vm.editedTitle) { _, title in
                    guard title.contains("\n") else { return }
                    vm.editedTitle = title.replacingOccurrences(of: "\n", with: "")
                    Task { await vm.renameNote() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.trinoteFill, in: .rect(cornerRadius: 12))
                .onAppear { isTitleFieldFocused = true }
            titleEditButtons(vm)
        }
    }

    /// Cancel and Save below the title field. Save is the accent with dark ink on it, so it reads
    /// in both themes (the system style put light text on the light dark-mode accent).
    private func titleEditButtons(_ vm: NoteDetailViewModel) -> some View {
        HStack(spacing: 8) {
            Button {
                vm.editingTitle = false
            } label: {
                Text(String(localized: "Cancel", comment: "Cancel title edit"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.trinoteTextPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Color.trinoteFill, in: .capsule)
            }
            .buttonStyle(.plain)
            Button {
                Task { await vm.renameNote() }
            } label: {
                Text(String(localized: "Save", comment: "Save title"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.trinoteOnAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Color.accentColor, in: .capsule)
                    .opacity(vm.isSaving ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(vm.isSaving)
        }
    }

    private func titleSection(_ vm: NoteDetailViewModel, note: NoteItem) -> AnyView {
        AnyView(titleSectionContent(vm, note: note))
    }

    @ViewBuilder
    private func titleSectionContent(_ vm: NoteDetailViewModel, note: NoteItem) -> some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 4) {
            /// Keeps the path aligned with the title text (same inset as the note icon column).
            let titleIconColumnWidth: CGFloat = 24
            let titleIconSpacing: CGFloat = 8

            if vm.editingTitle {
                HStack(alignment: .top, spacing: titleIconSpacing) {
                    Color.clear
                        .frame(width: titleIconColumnWidth)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        titleEditor(vm, note: note)
                        if let modified = lastChangedCaption(for: note) {
                            lastChangedCaptionRow(note: note, modified: modified, leadingPadding: 0)
                        }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        let titleRow = HStack(alignment: .firstTextBaseline, spacing: titleIconSpacing) {
                            noteTitleIconButton(vm: vm, note: note, width: titleIconColumnWidth)
                            WrappingHeading(text: uiTitle(for: note), size: 30, color: noteDetailTitleForegroundColor(for: note))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // Long-press the title for the note's own actions, Apple Intelligence first.
                        if note.isCalendarRoot {
                            titleRow.onTapGesture {
                                vm.editedTitle = note.title
                                vm.editingTitle = true
                            }
                            .contextMenu { noteTitleMenu(vm: vm, note: note) }
                        } else {
                            // The tap sits on the row itself: under the long-press menu, a tap
                            // further out no longer reached the title.
                            titleRow
                                .contentShape(.rect)
                                .onTapGesture {
                                    vm.editedTitle = note.title
                                    vm.editingTitle = true
                                }
                                .contextMenu { noteTitleMenu(vm: vm, note: note) }
                        }
                        if note.isCalendarRoot, let modified = lastChangedCaption(for: note) {
                            lastChangedCaptionRow(
                                note: note,
                                modified: modified,
                                leadingPadding: titleIconColumnWidth + titleIconSpacing
                            )
                        } else {
                            noteMetaLine(vm: vm, note: note)
                                .padding(.leading, titleIconColumnWidth + titleIconSpacing)
                        }
                        noteLabelChips(vm: vm, note: note)
                            .padding(.leading, titleIconColumnWidth + titleIconSpacing)
                            .padding(.top, 4)
                    }
                    // The full width for the title: a spacer beside it took half, so short words
                    // wrapped onto a second line with room to spare (TestFlight feedback).
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .if(!note.isCalendarRoot) { view in
                    view.onTapGesture {
                        vm.editedTitle = note.title
                        vm.editingTitle = true
                    }
                }
                .accessibilityLabel(String(localized: "Note title: \(uiTitle(for: note)). Tap to edit.", comment: "VoiceOver note title"))
            }

            HStack(spacing: 12) {
                // Label(note.type.displayName, systemImage: note.type.iconName)
                //     .font(.caption)
                //     .foregroundStyle(.secondary)

                if note.isSharedWithMultipleTreePlacements {
                    Label(String(localized: "Sharing", comment: "Note badge"), systemImage: "scale.3d")
                        .font(.caption)
                        .foregroundStyle(Color.green)
                    Label(String(localized: "Cloned (\(note.parentNoteIds.count) parents)", comment: "Note badge clone count"), systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if note.showsSharingBadge {
                    Label(String(localized: "Sharing", comment: "Note badge"), systemImage: "scale.3d")
                        .font(.caption)
                        .foregroundStyle(Color.green)
                } else if note.showsMultiCloneBadge {
                    Label(String(localized: "Cloned (\(note.parentNoteIds.count) parents)", comment: "Note badge clone count"), systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if note.isProtected {
                    Label(String(localized: "Protected", comment: "Note badge"), systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.leading, titleIconColumnWidth + titleIconSpacing)
        }
        .padding()
    }

    private func noteBody(_ vm: NoteDetailViewModel, note: NoteItem, findControl: FindOnPageControl) -> AnyView {
        AnyView(noteBodyContent(vm, note: note, findControl: findControl))
    }

    @ViewBuilder
    private func noteBodyContent(_ vm: NoteDetailViewModel, note: NoteItem, findControl: FindOnPageControl) -> some View {
        if vm.isLoadingContent {
            ProgressView(String(localized: "Loading content…", comment: "Note body loading"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .onAppear { NoteOpenTrace.log("body spinner shown") }
                .onDisappear { NoteOpenTrace.log("body spinner hidden") }
        } else {
            readingView(vm, note: note, findControl: findControl)
        }
    }

    @ViewBuilder
    private func readingView(_ vm: NoteDetailViewModel, note: NoteItem, findControl: FindOnPageControl) -> some View {
        switch note.type {
        case .text:
            if let html = vm.contentString {
                HTMLNoteView(
                    html: html,
                    baseURL: vm.serverBaseURL,
                    checkboxOnlyRevision: vm.checkboxOnlyContentRevision,
                    onNoteLinkTapped: { linkedNoteId in
                        navigateToNoteId = linkedNoteId
                    },
                    onCheckboxToggled: { index, checked in
                        vm.toggleCheckbox(index: index, checked: checked)
                    },
                    onCheckboxReordered: { fromIndex, beforeIndex in
                        vm.reorderListItem(fromIndex: fromIndex, beforeIndex: beforeIndex)
                    },
                    onCollapsibleReordered: { fromIndex, beforeChildIndex in
                        vm.reorderCollapsible(fromIndex: fromIndex, beforeChildIndex: beforeChildIndex)
                    },
                    onCollapsibleToggled: { index, open in
                        vm.setCollapsibleOpen(index: index, open: open)
                    },
                    loadAttachmentPreview: { attachmentId in
                        if let attachment = vm.attachments.first(where: { $0.attachmentId == attachmentId }) {
                            return await vm.prepareAttachmentPreview(for: attachment)
                        }
                        return await vm.prepareAttachmentPreview(attachmentId: attachmentId)
                    },
                    imageBytes: { routeType, entityId in
                        await vm.loadImageBytes(routeType: routeType, entityId: entityId)
                    },
                    findControl: findControl,
                    layoutCacheKey: vm.serverProfileId.map { "\($0)/\(note.noteId)" }
                )
            }
        case .mermaid:
            if let source = vm.contentString {
                MermaidNoteView(source: source)
            }
        case .code, .markdown:
            if let code = vm.contentString {
                CodeNoteView(
                    content: code,
                    mime: note.mime,
                    baseURL: vm.serverBaseURL,
                    findControl: findControl,
                    onNoteLinkTapped: { linkedNoteId in
                        navigateToNoteId = linkedNoteId
                    },
                    loadAttachmentPreview: { attachmentId in
                        if let attachment = vm.attachments.first(where: { $0.attachmentId == attachmentId }) {
                            return await vm.prepareAttachmentPreview(for: attachment)
                        }
                        return await vm.prepareAttachmentPreview(attachmentId: attachmentId)
                    },
                    onMimeSelected: { mime in
                        Task { await vm.updateCodeNoteMime(mime) }
                    },
                    onTaskStateCycled: { index in
                        vm.cycleMarkdownTaskState(index: index)
                    },
                    checkboxOnlyRevision: vm.checkboxOnlyContentRevision
                )
            }
        case .image:
            if let data = vm.content {
                ImageNoteView(data: data, title: uiTitle(for: note))
            }
        case .file:
            FileNoteView(note: note, attachments: vm.attachments, viewModel: vm) { noteId, _ in
                navigateToNoteId = noteId
            }
        case .canvas:
            CanvasNoteView(noteId: note.noteId, attachments: vm.attachments, client: vm.client, excalidrawJSON: vm.contentString)
        case .mindMap:
            if let json = vm.contentString {
                MindMapNoteView(
                    json: json,
                    imageBytes: { routeType, entityId in
                        await vm.loadImageBytes(routeType: routeType, entityId: entityId)
                    }
                )
            }
        case .spreadsheet:
            SpreadsheetNoteView(
                json: vm.contentString,
                imageBytes: { routeType, entityId in
                    await vm.loadImageBytes(routeType: routeType, entityId: entityId)
                }
            )
        case .geoMap:
            GeoMapNoteView(
                viewportJSON: geoMapInitialViewportJSON.isEmpty
                    ? effectiveGeoMapViewportJSONForDisplay(vm.contentString)
                    : geoMapInitialViewportJSON,
                markers: geoMapPins,
                tracks: geoMapTracks,
                shapes: geoMapShapes,
                settingsJSON: geoMapCachedSettingsJSON,
                onOpenPinNote: { navigateToNoteId = $0 }
            )
            .onAppear { loadGeoMapData(vm: vm, note: note) }
        case .kanban:
            KanbanBoardView(viewModel: vm, note: note) { navigateToNoteId = $0 }
                .frame(minHeight: 420)
        case .presentation:
            PresentationNoteView(viewModel: vm, note: note) { navigateToNoteId = $0 }
                .frame(minHeight: 420)
        case .book, .collection:
            if isGeoMapNote(note, contentString: vm.contentString, vm: vm) {
                GeoMapNoteView(
                    viewportJSON: geoMapInitialViewportJSON.isEmpty
                    ? effectiveGeoMapViewportJSONForDisplay(vm.contentString)
                    : geoMapInitialViewportJSON,
                    markers: geoMapPins,
                    tracks: geoMapTracks,
                    shapes: geoMapShapes,
                    settingsJSON: geoMapCachedSettingsJSON,
                    onOpenPinNote: { navigateToNoteId = $0 }
                )
                .onAppear { loadGeoMapData(vm: vm, note: note) }
            } else if isPresentationNote(note) {
                PresentationNoteView(viewModel: vm, note: note) { navigateToNoteId = $0 }
                    .frame(minHeight: 420)
            } else if isKanbanNote(note) {
                KanbanBoardView(viewModel: vm, note: note) { navigateToNoteId = $0 }
                    .frame(minHeight: 420)
            } else if note.isTriliumCollectionNote || note.type == .collection {
                CollectionNoteLimitedSupportBanner(
                    noteId: note.noteId,
                    serverURL: appState.activeProfile?.normalizedBaseURL
                )
            } else {
                BookNoteView(note: note)
            }
        default:
            UnsupportedNoteView(note: note, serverURL: appState.activeProfile?.normalizedBaseURL)
        }
    }

    private func notesEditedOnDaySection(_ vm: NoteDetailViewModel, compact: Bool = false) -> AnyView {
        AnyView(notesEditedOnDaySectionContent(vm, compact: compact))
    }

    @ViewBuilder
    private func notesEditedOnDaySectionContent(_ vm: NoteDetailViewModel, compact: Bool) -> some View {
        if !vm.notesEditedOnDay.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        notesEditedOnDayExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(notesEditedOnDayExpanded ? 90 : 0))
                        Text(String(localized: "Notes edited on that day", comment: "Journal day note: notes last modified on this calendar day"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        if !notesEditedOnDayExpanded {
                            Text("\(vm.notesEditedOnDay.count)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Notes edited on that day", comment: "Journal day note: notes last modified on this calendar day"))
                .accessibilityValue(
                    notesEditedOnDayExpanded
                        ? String(localized: "Expanded", comment: "Journal edited-notes section is expanded")
                        : String(localized: "Collapsed", comment: "Journal edited-notes section is collapsed")
                )
                .accessibilityHint(
                    notesEditedOnDayExpanded
                        ? String(localized: "Collapses the list", comment: "Journal edited-notes section collapse hint")
                        : String(localized: "Expands the list", comment: "Journal edited-notes section expand hint")
                )

                if notesEditedOnDayExpanded {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(vm.notesEditedOnDay) { edited in
                                Button {
                                    navigateToNoteId = edited.noteId
                                } label: {
                                    Text(
                                        NoteItem.maskedStoredTitle(
                                            edited.title,
                                            isProtected: edited.isProtected,
                                            protectedSessionActive: appState.protectedSessionActive
                                        )
                                    )
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color.blue.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.primary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    NoteItem.maskedStoredTitle(
                                        edited.title,
                                        isProtected: edited.isProtected,
                                        protectedSessionActive: appState.protectedSessionActive
                                    )
                                )
                                .accessibilityHint(String(localized: "Opens this note", comment: "Journal day edited-note pill hint"))
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.top, compact ? 8 : 12)
            .padding(.bottom, compact ? 8 : 10)

            if notesEditedOnDayExpanded {
                Divider()
            }
        }
    }

    /// - Parameters:
    ///   - mapFeature: Under a geo map, what each child is on the map (nil when it isn't). Those rows end in a pin
    ///     that moves the map to it (`onShowOnMap`) instead of a chevron; the rest of the row still opens the note.
    private func childNotesSection(
        _ vm: NoteDetailViewModel,
        mapFeature: ((String) -> GeoMapFeatureKind?)? = nil,
        onShowOnMap: ((String, GeoMapFeatureKind) -> Void)? = nil
    ) -> AnyView {
        AnyView(childNotesSectionContent(vm, mapFeature: mapFeature, onShowOnMap: onShowOnMap))
    }

    @ViewBuilder
    private func childNotesSectionContent(
        _ vm: NoteDetailViewModel,
        mapFeature: ((String) -> GeoMapFeatureKind?)?,
        onShowOnMap: ((String, GeoMapFeatureKind) -> Void)?
    ) -> some View {
        if !vm.childNotes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                Text(String(localized: "Sub-notes", comment: "Child notes section header"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                ForEach(vm.childNotes) { child in
                    let feature = mapFeature?(child.noteId)
                    HStack(spacing: 0) {
                        Button {
                            navigateToNoteId = child.noteId
                        } label: {
                            HStack(spacing: 10) {
                                NoteIconView(
                                    iconClass: child.iconClass,
                                    fallbackNoteType: child.iconFallbackNoteType,
                                    size: .regular,
                                    foregroundStyle: .secondary
                                )
                                .frame(width: 22)
                                Text(NoteItem.maskedStoredTitle(child.title, isProtected: child.isProtected, protectedSessionActive: appState.protectedSessionActive))
                                    .font(.body)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                if child.childCount > 0 {
                                    Text("\(child.childCount)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                if feature == nil {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.leading)
                            .padding(.trailing, feature == nil ? 16 : 4)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // The same long-press menu as rows in lists and the sidebar.
                        .contextMenu { childNoteMenu(child, vm: vm) }

                        if let feature, let onShowOnMap {
                            Button {
                                onShowOnMap(child.noteId, feature)
                            } label: {
                                Image(systemName: "mappin.circle")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 8)
                            .accessibilityLabel(String(localized: "Show on map", comment: "Geo map sub-note row: move the map to this note's location"))
                        }
                    }

                    if child.id != vm.childNotes.last?.id {
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .padding(.bottom, 8)
            .noteDeleteConfirmationAlert(
                isPresented: Binding(get: { childPendingDelete != nil }, set: { if !$0 { childPendingDelete = nil } }),
                title: String(localized: "Delete Note?", comment: "Delete confirm title"),
                message: NoteDeleteConfirmationCopy.singleNoteMessage(title: childPendingDelete?.title ?? ""),
                erasePermanently: $eraseChildOnDelete,
                onConfirm: {
                    guard let child = childPendingDelete else { return }
                    let erase = eraseChildOnDelete
                    Task { await deleteChild(child, erase: erase, vm: vm) }
                },
                onCancel: { eraseChildOnDelete = false }
            )
            .noteMoveFlow($childMoveRequest) { Task { await vm.loadChildNotes() } }
            .sheet(item: $childAppearanceTarget) { target in
                NoteAppearancePickerSheet(
                    title: target.title,
                    initialTab: target.initialTab,
                    currentIconClass: target.iconClass,
                    currentColorLabel: target.colorLabel,
                    onSelectIcon: { icon in
                        Task { await changeChild(vm: vm) { try await NoteAppearanceUpdater.setIconClass(icon, noteId: target.noteId, appState: appState) } }
                    },
                    onSelectColor: { color in
                        Task { await changeChild(vm: vm) { try await NoteAppearanceUpdater.setColor(color, noteId: target.noteId, appState: appState) } }
                    }
                )
            }
            .alert(
                String(localized: "Error", comment: "Generic error title"),
                isPresented: Binding(get: { childActionError != nil }, set: { if !$0 { childActionError = nil } }),
                actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
                message: { Text(childActionError ?? "") }
            )
        } else if vm.isLoadingChildren {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .padding()
        }
    }

    @ViewBuilder
    private func richTextEditingView(_ vm: NoteDetailViewModel) -> some View {
        // `editorDisplayContent` is the decorated copy of `editableContent` (image refs → `trinote-img://`,
        // canvas/mermaid imageLinks → include cards), populated asynchronously by `prepareEditorDisplayContent`.
        // While that's in flight we show a brief spinner so the editor never mounts with broken
        // `<img src="api/images/…">` references.
        if let displayHTML = vm.editorDisplayContent {
            richTextEditingViewBody(vm, displayHTML: displayHTML)
        } else {
            ZStack {
                Color(uiColor: .trinoteEditorCanvas).ignoresSafeArea(edges: [.bottom, .horizontal])
                ProgressView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .task {
                // Defensive: `startEditing` already kicks this off; this `.task` only ever fires if the view appeared
                // before the model could schedule the prep (e.g. state restoration paths).
                await vm.prepareEditorDisplayContent()
            }
        }
    }

    @ViewBuilder
    private func richTextEditingViewBody(_ vm: NoteDetailViewModel, displayHTML: String) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RichTextEditorView(
                initialHTML: displayHTML,
                onContentChanged: { html in
                    if vm.receiveEditorUpdate(html) { scheduleAutosave(vm: vm) }
                },
                onPickImage: { showEditorImageSourceDialog = true },
                onEditorScroll: { y, verticallyScrollable in
                    updateEditorSaveCancelChipVisibility(contentOffsetY: y, verticallyScrollable: verticallyScrollable)
                },
                onTypingActivity: {
                    handleEditorSaveChipTypingActivity()
                },
                onTableToolsVisibilityChanged: { visible in
                    editorTableToolsVisible = visible
                    if visible {
                        cancelEditorSaveChipIdleShowTask()
                    } else {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                            showEditorSaveCancelChip = true
                        }
                    }
                },
                onRequestSave: { html, scrollFraction in
                    queueReadOnlyScrollRestoreAfterRichTextSave(fraction: scrollFraction)
                    if let html {
                        vm.saveContent(freshHTML: html)
                    } else {
                        vm.saveContent()
                    }
                },
                onEditorBridgeRequest: { req in
                    switch req {
                    case .pickIncludeNote:
                        showIncludeNotePicker = true
                    case .pickInlineIcon:
                        showInlineIconPicker = true
                    case .resolveNoteTitle(let nid):
                        Task { @MainActor in
                            let t = await vm.resolveDisplayTitle(forReferencedNoteId: nid)
                            Self.pushIncludeNoteTitleToEditor(webView: editorWebView, noteId: nid, title: t)
                        }
                    case .openNote(let nid):
                        navigateToNoteId = nid
                    case .includePreview(let previewId, let nid, let box):
                        Task { @MainActor in
                            let html = await vm.resolvedIncludePreviewHTML(noteId: nid, boxSize: box)
                            Self.pushIncludeNotePreviewToEditor(webView: editorWebView, previewId: previewId, html: html)
                        }
                    case .renameAttachment(let attachmentId, _, let title, let pos):
                        let split = AttachmentFilename.split(title)
                        attachmentRenameBasename = split.basename
                        attachmentRenameContext = EditorAttachmentRenameContext(
                            attachmentId: attachmentId,
                            nodePos: pos,
                            fileExtension: split.ext
                        )
                    }
                },
                onPasteFile: { data, filename, mime in
                    presentAttachmentUploadNamePrompt(data: data, mime: mime, filename: filename)
                },
                imageBytes: { routeType, entityId in
                    await vm.loadImageBytes(routeType: routeType, entityId: entityId)
                },
                imageToInsert: $imageToInsert,
                attachmentToInsert: $attachmentToInsert,
                webViewBinding: $editorWebView,
                initialScrollFraction: scrollTracking.fraction,
                insertToolsAtTop: noteEditorInsertToolsAtTop,
                onInsertToolsAtTopChanged: { noteEditorInsertToolsAtTop = $0 },
                onFormatStateChanged: { editorFormatState = $0 },
                usesNativeToolbar: !showsClassicEditorToolbar,
                onContentLoaded: { vm.setAutosaveBaselineFromEditor($0) },
                hidesSaveButton: hidesEditorSaveButton
            )
            // Fill remaining height so the WKWebView isn’t vertically compressed in a way that clips
            // the HTML toolbar when the keyboard steals space (minHeight: 400 overflowed the layout).
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)

            if !showsClassicEditorToolbar, !isTabletopLayout {
                VStack(spacing: 10) {
                    // An Apple Intelligence result while editing sits above the bar; Add puts it in
                    // the editor, saved with the rest on Done.
                    if summaryModel.isVisible {
                        NoteSummaryCard(
                            model: summaryModel,
                            onRegenerate: { runNoteAIInEditor(summaryModel.kind, vm: vm) },
                            onAddToNote: noteAIApply(vm: vm)
                        )
                        .frame(maxHeight: 320)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    NoteFormatBar(
                        state: editorFormatState,
                        isSaving: vm.isSaving,
                        onCommand: { runEditorFormatCommand($0) },
                        onShowPanel: { showEditorFormatPanel = true },
                        onLinkToNote: { showNoteLinkPicker = true },
                        onDone: { saveRichTextContent(vm: vm) },
                        aiActions: editorAIAvailable(vm: vm) ? { runNoteAIInEditor($0.kind, vm: vm) } : nil,
                        isAIMenuOpen: $isNoteAIMenuOpen
                    )
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .zIndex(3)
            }

            if showsClassicEditorToolbar && showEditorSaveCancelChip && !editorTableToolsVisible && !hidesEditorSaveButton {
                editorSaveChip(vm: vm)
                    .padding(.trailing, 16)
                    .padding(.bottom, 62)
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                    .zIndex(2)
            }

            if showEditorImageSourceDialog {
                EditorInsertMediaDialog(
                    showsCamera: UIImagePickerController.isSourceTypeAvailable(.camera),
                    onPhotoLibrary: {
                        showEditorImageSourceDialog = false
                        editorFullscreenCover = .photoLibrary
                    },
                    onCamera: {
                        showEditorImageSourceDialog = false
                        // Lock portrait first so the system camera gets upright bounds; present
                        // via fullScreenCover (not UIKit present) so note @State survives.
                        EditorCameraCapture.preparePortraitSession {
                            editorFullscreenCover = .camera
                        }
                    },
                    onChooseFile: {
                        showEditorImageSourceDialog = false
                        showEditorFilePicker = true
                    },
                    onCancel: {
                        showEditorImageSourceDialog = false
                        editorWebView?.evaluateJavaScript(
                            "try{window.editorBridge.clearPendingMediaInsert()}catch(e){}",
                            completionHandler: nil
                        )
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(50)
            }
        }
        .animation(.easeOut(duration: 0.2), value: showEditorImageSourceDialog)
        .sheet(isPresented: $showEditorFormatPanel) {
            EditorFormatPanel(
                state: editorFormatState,
                onCommand: { runEditorFormatCommand($0) },
                onShowAllTools: {
                    showEditorFormatPanel = false
                    showsClassicEditorToolbar = true
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showNoteLinkPicker) {
            NotePickerSheet(
                excludeNoteId: vm.note?.noteId,
                navigationTitleOverride: String(localized: "Link to note", comment: "Format bar")
            ) { noteId, title in
                insertNoteLinkInEditor(noteId: noteId, title: title)
            }
            .environment(appState)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .trinoteEditorCanvas).ignoresSafeArea(edges: [.bottom, .horizontal]))
        .animation(.easeInOut(duration: 0.15), value: editorTableToolsVisible)
        .onAppear {
            editorSaveCancelScrollBaselineReady = false
            lastEditorScrollOffsetY = 0
            cancelEditorSaveChipIdleShowTask()
            editorSaveChipIgnoreTypingUntil = Date().addingTimeInterval(Self.editorSaveChipIgnoreTypingAfterAppear)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                showEditorSaveCancelChip = true
            }
        }
        .onDisappear {
            cancelEditorSaveChipIdleShowTask()
        }
        .fileImporter(
            isPresented: $showEditorFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleEditorFilePick(result) }
        }
        .sheet(isPresented: $showInlineIconPicker) {
            InlineIconPickerSheet { iconClass in
                Self.insertInlineIconInEditor(webView: editorWebView, iconClass: iconClass)
            }
        }
        .sheet(isPresented: $showIncludeNotePicker) {
            NotePickerSheet(
                excludeNoteId: activeNoteId,
                navigationTitleOverride: String(
                    localized: "Select a note to link to this note",
                    comment: "Include/link note picker title"
                ),
                hidesEmbeddedTreeToolbar: true,
                hidesEmbeddedTreeRootHeader: true,
                hidesEmbeddedTreeTabsBar: true
            ) { pickedId, pickedTitle in
                Self.insertIncludeNoteInEditor(webView: editorWebView, noteId: pickedId, title: pickedTitle, boxSize: "medium")
            }
            .environment(appState)
        }
    }

    // MARK: - Mermaid editing

    @ViewBuilder
    private func mermaidEditingView(_ vm: NoteDetailViewModel) -> some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            editorStatusBanner(vm)
            MermaidEditorView(
                editableContent: $vm.editableContent,
                onSave: { vm.saveContent() },
                isSaving: vm.isSaving,
                showsSaveButton: !hidesEditorSaveButton
            )
        }
        .onChange(of: vm.editableContent) { _, body in
            if vm.noteEditedBody(body) { scheduleAutosave(vm: vm) }
        }
    }

    // MARK: - Canvas editing

    @ViewBuilder
    private func canvasEditingView(_ vm: NoteDetailViewModel) -> some View {
        ZStack(alignment: .bottomTrailing) {
            CanvasEditorView(
                initialJSON: vm.editableContent,
                bridge: canvasEditorBridge,
                onSceneChanged: {
                    canvasHasUnsavedChanges = true
                    vm.noteEditorChanged()
                    scheduleAutosave(vm: vm)
                }
            )
            .onAppear {
                canvasHasUnsavedChanges = false
            }

            if !hidesEditorSaveButton {
                canvasSaveChip(vm: vm)
                    .padding(.trailing, 16)
                    .padding(.bottom, 72)
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .trinoteCanvasBackground).ignoresSafeArea(edges: [.bottom, .horizontal]))
    }

    @ViewBuilder
    private func canvasSaveChip(vm: NoteDetailViewModel) -> some View {
        Button {
            saveCanvasContent(vm: vm)
        } label: {
            ZStack {
                if vm.isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image("SaveNoteFloating")
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                }
            }
            .foregroundStyle(.primary)
            .frame(width: 48, height: 48)
            .background(.ultraThinMaterial, in: Circle())
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(vm.isSaving)
        .accessibilityLabel(String(localized: "Save", comment: "Canvas save chip"))
    }

    private func saveCanvasContent(vm: NoteDetailViewModel, completion: ((Bool) -> Void)? = nil) {
        canvasEditorBridge.getSceneData { json, svg in
            DispatchQueue.main.async {
                // `{}` means the canvas hasn't loaded: nothing to save (and saving it would erase the drawing).
                guard NoteEditorSaving.isUsableCanvasJSON(json) else {
                    completion?(true)
                    return
                }
                vm.saveCanvasContent(json: json, svg: svg)
                canvasHasUnsavedChanges = false
                completion?(!vm.isEditing)
            }
        }
    }

    // MARK: - Spreadsheet editing

    /// iPad/regular-size-class inline editor. Mirrors `canvasEditingView` so the
    /// floating save chip + WKWebView host fill the note pane.
    @ViewBuilder
    private func spreadsheetEditingView(_ vm: NoteDetailViewModel) -> some View {
        ZStack(alignment: .bottomTrailing) {
            SpreadsheetEditorView(
                initialJSON: vm.editableContent,
                bridge: spreadsheetEditorBridge,
                colorScheme: colorScheme,
                imageBytes: { routeType, entityId in
                    await vm.loadImageBytes(routeType: routeType, entityId: entityId)
                },
                onWorkbookChanged: {
                    spreadsheetHasUnsavedChanges = true
                    vm.noteEditorChanged()
                    scheduleAutosave(vm: vm)
                }
            )
            .onAppear {
                spreadsheetHasUnsavedChanges = false
            }

            if !hidesEditorSaveButton {
                spreadsheetSaveChip(vm: vm)
                    .padding(.trailing, 16)
                    .padding(.bottom, 72)
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .trinoteSpreadsheetBackground).ignoresSafeArea(edges: [.bottom, .horizontal]))
    }

    @ViewBuilder
    private func spreadsheetSaveChip(vm: NoteDetailViewModel) -> some View {
        Button {
            saveSpreadsheetContent(vm: vm)
        } label: {
            ZStack {
                if vm.isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image("SaveNoteFloating")
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                }
            }
            .foregroundStyle(.primary)
            .frame(width: 48, height: 48)
            .background(.ultraThinMaterial, in: Circle())
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(vm.isSaving)
        .accessibilityLabel(String(localized: "Save", comment: "Spreadsheet save chip"))
    }

    /// Saves an open edit first (Trilium exports the stored workbook), then shares the downloaded file.
    private func exportSpreadsheetToXlsx(vm: NoteDetailViewModel) {
        guard !isExportingSpreadsheetXlsx else { return }
        withAnimation { isExportingSpreadsheetXlsx = true }
        Task {
            defer { withAnimation { isExportingSpreadsheetXlsx = false } }
            if vm.isEditing, spreadsheetHasUnsavedChanges {
                let json = await withCheckedContinuation { continuation in
                    spreadsheetEditorBridge.getWorkbook { continuation.resume(returning: $0) }
                }
                vm.saveSpreadsheetContent(json: json)
                spreadsheetHasUnsavedChanges = false
                // The save explains its own failure.
                guard !vm.showSaveError else { return }
            }
            do {
                let url = try await vm.exportSpreadsheetToXlsx()
                scheduleNoteDetailShareURLSheet(url: url)
            } catch {
                spreadsheetXlsxExportError = error.localizedDescription
            }
        }
    }

    private func saveSpreadsheetContent(vm: NoteDetailViewModel, completion: ((Bool) -> Void)? = nil) {
        spreadsheetEditorBridge.getWorkbook { json in
            DispatchQueue.main.async {
                // Leaving before the sheet loaded: nothing to save. (Save itself says the editor wasn't ready.)
                if completion != nil, !NoteEditorSaving.isUsableSpreadsheetJSON(json) {
                    completion?(true)
                    return
                }
                vm.saveSpreadsheetContent(json: json)
                spreadsheetHasUnsavedChanges = false
                completion?(!vm.isEditing)
            }
        }
    }

    /// iPhone/compact-size-class modal editor — Univer's chrome (formula bar +
    /// toolbar) is cramped at 390 pt inline, so we present it full-screen with a
    /// native nav bar that hosts Cancel/Save.
    @ViewBuilder
    private func spreadsheetEditorCover(vm: NoteDetailViewModel) -> some View {
        NavigationStack {
            SpreadsheetEditorView(
                initialJSON: vm.editableContent,
                bridge: spreadsheetEditorBridge,
                colorScheme: colorScheme,
                imageBytes: { routeType, entityId in
                    await vm.loadImageBytes(routeType: routeType, entityId: entityId)
                },
                onWorkbookChanged: {
                    spreadsheetHasUnsavedChanges = true
                    vm.noteEditorChanged()
                    scheduleAutosave(vm: vm)
                }
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(vm.note?.uiTitle(forProtectedSessionActive: appState.protectedSessionActive) ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .cancelEditingConfirmation(isPresented: $showSpreadsheetCancelEditingConfirm) {
                if let note = vm.note { discardNoteEditing(vm: vm, note: note) }
            }
            .toolbar {
                if let status = autosaveStatusText(vm) {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(vm.note?.uiTitle(forProtectedSessionActive: appState.protectedSessionActive) ?? "")
                                .font(.headline)
                                .lineLimit(1)
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if vm.cancelEditingNeedsConfirmation {
                            showSpreadsheetCancelEditingConfirm = true
                        } else if let note = vm.note {
                            discardNoteEditing(vm: vm, note: note)
                        }
                    } label: {
                        Text(String(localized: "Cancel", comment: "Spreadsheet editor cancel button"))
                    }
                    .disabled(vm.isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        saveSpreadsheetContent(vm: vm)
                    } label: {
                        if vm.isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(String(localized: "Save", comment: "Spreadsheet editor save button"))
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(vm.isSaving)
                }
            }
            .onAppear {
                spreadsheetHasUnsavedChanges = false
            }
        }
    }

    // MARK: - Mind Map read-only

    @ViewBuilder
    private func mindMapReadOnlyView(_ vm: NoteDetailViewModel, note: NoteItem) -> some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                editorStatusBanner(vm)
                draftBanner(vm)
                titleSection(vm, note: note)
                Divider()

                if let json = vm.contentString {
                    MindMapNoteView(
                        json: json,
                        imageBytes: { routeType, entityId in
                            await vm.loadImageBytes(routeType: routeType, entityId: entityId)
                        }
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                }
            }
            .simultaneousGesture(longPressToEditGesture(vm: vm, note: note))

            if showFloatingEditButton && !noteEditorLongPressToEdit && !isTabletopLayout {
                floatingEditFAB(vm: vm)
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .intoSideStrip(trailingPadding: 16, width: 48)
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .onAppear {
            presentFloatingEditOnNoteOpen(vm: vm, note: note)
            scheduleFloatingEditScrollSettlingEndIfNeeded()
        }
        .onChange(of: vm.isEditing) { _, editing in
            if editing {
                floatingEditSettlingEndWorkItem?.cancel()
                floatingEditSettlingEndWorkItem = nil
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    showFloatingEditButton = false
                }
            } else if floatingEditFABEligible(vm: vm, note: note) {
                presentFloatingEditOnNoteOpen(vm: vm, note: note)
                scheduleFloatingEditScrollSettlingEndIfNeeded()
            }
        }
        .onChange(of: noteEditorLongPressToEdit) { _, _ in
            refreshFloatingEditVisibility(vm: vm, note: note)
        }
    }

    // MARK: - Mind Map editing

    @ViewBuilder
    private func mindMapEditingView(_ vm: NoteDetailViewModel) -> some View {
        ZStack(alignment: .bottomTrailing) {
            MindMapEditorView(
                initialJSON: vm.editableContent,
                bridge: mindMapEditorBridge,
                onMapChanged: {
                    mindMapHasUnsavedChanges = true
                    vm.noteEditorChanged()
                    scheduleAutosave(vm: vm)
                },
                imageBytes: { routeType, entityId in
                    await vm.loadImageBytes(routeType: routeType, entityId: entityId)
                }
            )
            .onAppear {
                mindMapHasUnsavedChanges = false
            }

            if !hidesEditorSaveButton {
                mindMapSaveChip(vm: vm)
                    .padding(.trailing, 16)
                    .padding(.bottom, 72)
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func mindMapSaveChip(vm: NoteDetailViewModel) -> some View {
        Button {
            saveMindMapContent(vm: vm)
        } label: {
            ZStack {
                if vm.isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image("SaveNoteFloating")
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                }
            }
            .foregroundStyle(.primary)
            .frame(width: 48, height: 48)
            .background(.ultraThinMaterial, in: Circle())
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(vm.isSaving)
        .accessibilityLabel(String(localized: "Save", comment: "Mind map save chip"))
    }

    private func saveMindMapContent(vm: NoteDetailViewModel, completion: ((Bool) -> Void)? = nil) {
        mindMapEditorBridge.getMapData { json in
            DispatchQueue.main.async {
                // `{}` means the map hasn't loaded: nothing to save (and saving it would erase the map).
                guard NoteEditorSaving.isUsableMindMapJSON(json) else {
                    completion?(true)
                    return
                }
                vm.editableContent = json
                vm.saveContent()
                mindMapHasUnsavedChanges = false
                completion?(!vm.isEditing)
            }
        }
    }

    // MARK: - Calendar (own layout to avoid nested ScrollViews)

    @ViewBuilder
    private func calendarDetailView(_ vm: NoteDetailViewModel, note: NoteItem) -> some View {
        VStack(spacing: 0) {
            editorStatusBanner(vm)
            draftBanner(vm)
            titleSection(vm, note: note)
            Divider()
            CalendarNoteView(calendarRootNote: note)
        }
    }

    // MARK: - Kanban Board

    private func isKanbanNote(_ note: NoteItem?) -> Bool {
        guard let note else { return false }
        if note.isCalendarRoot { return false }
        return note.isSemanticKanban
    }

    @ViewBuilder
    private func kanbanDetailView(_ vm: NoteDetailViewModel, note: NoteItem) -> some View {
        VStack(spacing: 0) {
            editorStatusBanner(vm)
            draftBanner(vm)
            titleSection(vm, note: note)
            Divider()
            KanbanBoardView(viewModel: vm, note: note) { navigateToNoteId = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Presentation

    private func isPresentationNote(_ note: NoteItem?) -> Bool {
        guard let note else { return false }
        if note.isCalendarRoot { return false }
        return note.isSemanticPresentation
    }

    @ViewBuilder
    private func presentationDetailView(_ vm: NoteDetailViewModel, note: NoteItem) -> some View {
        VStack(spacing: 0) {
            editorStatusBanner(vm)
            draftBanner(vm)
            titleSection(vm, note: note)
            Divider()
            PresentationNoteView(viewModel: vm, note: note) { navigateToNoteId = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Geo Map (map + scrollable sub-notes; long-press map to add pins)

    /// Fixed band height for the map editor. A `GeometryReader` wrapping the whole column (including a flexible `ScrollView`) often collapses the WKWebView in navigation, so Leaflet sees 0×0 and shows nothing.
    private static func geoMapEditorBandHeight() -> CGFloat {
        let screenH = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .map { $0.screen.bounds.height }
            .max() ?? 736
        return min(460, max(280, screenH * 0.38))
    }

    @ViewBuilder
    private func geoMapDetailView(_ vm: NoteDetailViewModel, note: NoteItem) -> some View {
        VStack(spacing: 0) {
            editorStatusBanner(vm)
            draftBanner(vm)
            geoMapTitleSection(vm, note: note)
            Divider()

            GeoMapEditorView(
                viewportJSON: geoMapInitialViewportJSON.isEmpty
                    ? effectiveGeoMapViewportJSONForDisplay(vm.contentString)
                    : geoMapInitialViewportJSON,
                markers: geoMapPins,
                tracks: geoMapTracks,
                shapes: geoMapShapes,
                settingsJSON: geoMapCachedSettingsJSON,
                bridge: geoMapEditorBridge,
                onCreatePin: { lat, lng in
                    handleGeoMapCreatePin(vm: vm, note: note, lat: lat, lng: lng)
                },
                onMovePin: { noteId, lat, lng in
                    handleGeoMapMovePin(vm: vm, noteId: noteId, lat: lat, lng: lng)
                },
                onRemovePin: { noteId in
                    handleGeoMapRemovePin(vm: vm, noteId: noteId)
                },
                onViewportChanged: { json in
                    geoMapViewportSaveTask?.cancel()
                    geoMapViewportSaveTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard !Task.isCancelled else { return }
                        let canon = Self.canonicalGeoMapViewportJSONForTriliumDesktop(json)
                        let trimmed = (vm.contentString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard canon != trimmed else { return }
                        vm.editableContent = canon
                        vm.saveContent()
                    }
                },
                onOpenPinNote: { pinNoteId in
                    navigateToNoteId = pinNoteId
                },
                onFeatureSelected: { noteId, kind, markFocus in
                    geoMapLastFeatureSelectTime = Date()
                    handleGeoMapFeatureSelected(vm: vm, noteId: noteId, kind: kind, markFocus: markFocus)
                },
                onSelectionCleared: {
                    if let selectedAt = geoMapLastFeatureSelectTime,
                       Date().timeIntervalSince(selectedAt) < 0.25 {
                        Log.geoMap.info("[geo-map-debug] selectionCleared ignored (recent feature select)")
                        return
                    }
                    clearGeoMapSelection()
                },
                onImportGpxRequested: {
                    geoMapShowGpxImporter = true
                },
                onLocateRequested: {
                    Task { @MainActor in
                        switch await geoMapLocator.currentLocation() {
                        case .success(let location):
                            geoMapEditorBridge.showUserLocation(
                                lat: location.coordinate.latitude,
                                lng: location.coordinate.longitude,
                                accuracyMeters: max(0, location.horizontalAccuracy)
                            )
                        case .failure(let failure):
                            geoMapEditorBridge.stopLocating()
                            geoMapLocateFailure = failure
                        }
                    }
                },
                onSearchRequested: { viewport in
                    geoMapSearchViewport = GeoMapSearchRequest(viewport: viewport)
                },
                onShapeDrawn: { kind, coordinates, radius in
                    handleGeoMapShapeDrawn(vm: vm, note: note, kind: kind, coordinates: coordinates, radiusMeters: radius)
                }
            )
            .equatable()
            .frame(height: Self.geoMapEditorBandHeight())
            .frame(maxWidth: .infinity)
            .clipped()

            geoMapSubnotesScrollArea(vm: vm, mapParentNote: note)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            geoMapDisplaySettings = GeoMapDisplaySettings(from: note, defaultStyle: GeoMapStyleID.triliumDefault(for: appState.serverAppInfo))
            geoMapCachedSettingsJSON = geoMapDisplaySettings.bridgeJSON()
            geoMapInitialViewportJSON = effectiveGeoMapViewportJSONForDisplay(vm.contentString)
            if !vm.hasDraft {
                vm.editableContent = vm.contentString ?? ""
            }
            loadGeoMapData(vm: vm, note: note)
        }
        .onChange(of: note.noteId) { _, _ in
            geoMapPins = []
            geoMapTracks = []
            geoMapShapes = []
            clearGeoMapSelection()
            geoMapDisplaySettings = GeoMapDisplaySettings(from: note, defaultStyle: GeoMapStyleID.triliumDefault(for: appState.serverAppInfo))
            geoMapCachedSettingsJSON = geoMapDisplaySettings.bridgeJSON()
            geoMapInitialViewportJSON = effectiveGeoMapViewportJSONForDisplay(vm.contentString)
            if !vm.hasDraft {
                vm.editableContent = vm.contentString ?? ""
            }
            loadGeoMapData(vm: vm, note: note)
        }
        .onChange(of: geoMapDisplaySettings) { _, newSettings in
            geoMapCachedSettingsJSON = newSettings.bridgeJSON()
        }
        .alert(
            geoMapLocateFailure == .denied
                ? String(localized: "Location Is Off", comment: "Geo map locate: permission denied title")
                : String(localized: "Location Unavailable", comment: "Geo map locate: no fix title"),
            isPresented: Binding(get: { geoMapLocateFailure != nil }, set: { if !$0 { geoMapLocateFailure = nil } })
        ) {
            if geoMapLocateFailure == .denied, let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Button(String(localized: "Open Settings", comment: "Geo map locate: open app settings")) {
                    UIApplication.shared.open(settingsURL)
                }
            }
            Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {}
        } message: {
            Text(geoMapLocateFailure == .denied
                ? String(localized: "Allow Triquid Notes to use your location in Settings to show where you are on the map.", comment: "Geo map locate: permission denied")
                : String(localized: "Your location couldn't be found right now. Try again in a moment.", comment: "Geo map locate: no fix"))
        }
        .sheet(item: $geoMapSearchViewport) { request in
            GeoMapPlaceSearchSheet(viewport: request.viewport) { place in
                geoMapEditorBridge.showPlace(place)
            } onAddPin: { place in
                geoMapEditorBridge.showPlace(place)
                handleGeoMapCreatePin(vm: vm, note: note, lat: place.lat, lng: place.lng, title: place.isUnnamed ? nil : place.name)
            }
        }
        .sheet(isPresented: $geoMapShowSettings) {
            GeoMapSettingsSheet(
                settings: $geoMapDisplaySettings,
                styles: GeoMapStyleID.available(for: appState.serverAppInfo)
            ) {
                saveGeoMapSettings(vm: vm, note: note)
            }
        }
        .fileImporter(
            isPresented: $geoMapShowGpxImporter,
            allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml],
            allowsMultipleSelection: false
        ) { result in
            handleGeoMapGpxImport(result: result, vm: vm, note: note)
        }
    }

    @ViewBuilder
    private func geoMapTitleSection(_ vm: NoteDetailViewModel, note: NoteItem) -> some View {
        @Bindable var vm = vm
        let titleIconColumnWidth: CGFloat = 24
        let titleIconSpacing: CGFloat = 8

        VStack(alignment: .leading, spacing: 4) {
            if vm.editingTitle {
                HStack(alignment: .top, spacing: titleIconSpacing) {
                    Color.clear.frame(width: titleIconColumnWidth).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        titleEditor(vm, note: note)
                        geoMapLastChangedRow(note: note)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: titleIconSpacing) {
                            noteTitleIconButton(vm: vm, note: note, width: titleIconColumnWidth)
                            Text(uiTitle(for: note))
                                .font(.title2.bold())
                                .foregroundStyle(noteDetailTitleForegroundColor(for: note))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        geoMapLastChangedRow(note: note)
                            .padding(.leading, titleIconColumnWidth + titleIconSpacing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onTapGesture {
                    vm.editedTitle = note.title
                    vm.editingTitle = true
                }
                .accessibilityLabel(String(localized: "Note title: \(uiTitle(for: note)). Tap to edit.", comment: "VoiceOver note title"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func geoMapLastChangedRow(note: NoteItem) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if let modified = lastChangedCaption(for: note) {
                Text(modified)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(String(localized: "Last changed \(modified)", comment: "Accessibility"))
            } else {
                Spacer(minLength: 0)
            }
            Button {
                geoMapShowSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Map settings", comment: "Geo map settings gear"))
        }
    }

    @ViewBuilder
    private func geoMapSubnotesScrollArea(vm: NoteDetailViewModel, mapParentNote: NoteItem) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 8).id("geoMapDetailTop")
                    if let selection = geoMapSelection {
                        GeoMapDetailPanel(
                            selection: selection,
                            pin: geoMapPins.first(where: { $0.noteId == selection.noteId }),
                            track: geoMapTracks.first(where: { $0.noteId == selection.noteId }),
                            shape: geoMapShapes.first(where: { $0.noteId == selection.noteId }),
                            pinHTML: geoMapDetailHTML,
                            gpxStats: geoMapDetailGPXStats,
                            onClose: { clearGeoMapSelection() },
                            onOpenNote: { navigateToNoteId = selection.noteId },
                            onMovePin: selection.kind == .pin ? {
                                geoMapEditorBridge.beginMovePin(noteId: selection.noteId)
                            } : nil,
                            onDelete: {
                                if selection.kind == .pin {
                                    handleGeoMapRemovePin(vm: vm, noteId: selection.noteId)
                                } else {
                                    handleGeoMapRemoveTrack(vm: vm, noteId: selection.noteId, mapParentNote: mapParentNote)
                                }
                            },
                            onNoteLinkTapped: { navigateToNoteId = $0 },
                            onFocusMark: { focus in
                                geoMapFocusedMarkId = focus.markId
                                geoMapEditorBridge.focusTrackMark(focus)
                            },
                            focusedMarkId: $geoMapFocusedMarkId
                        )
                    } else {
                        if vm.childNotes.isEmpty && !vm.isLoadingChildren {
                            Text(
                                String(
                                    localized: "Sub-notes appear here. Long-press the map to add a location.",
                                    comment: "Geo map: empty sub-note list hint below map"
                                )
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                        }
                        childNotesSection(
                            vm,
                            mapFeature: { geoMapFeatureKind(forNoteId: $0) },
                            onShowOnMap: { noteId, kind in
                                geoMapEditorBridge.focusFeature(noteId: noteId, kind: kind)
                            }
                        )
                    }
                    Color.clear.frame(minHeight: 80)
                }
                .frame(maxWidth: .infinity)
            }
            .onChange(of: geoMapSelection?.id) { _, newId in
                guard newId != nil else { return }
                if geoMapFocusedMarkId == nil {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("geoMapDetailTop", anchor: .top)
                    }
                }
            }
            .onChange(of: geoMapFocusedMarkId) { _, markId in
                scrollGeoMapDetailToMark(markId, proxy: proxy)
            }
            .onChange(of: geoMapDetailGPXStats?.pointCount) { _, _ in
                scrollGeoMapDetailToMark(geoMapFocusedMarkId, proxy: proxy)
            }
        }
        .refreshable {
            await vm.refresh(force: true)
            loadGeoMapData(vm: vm, note: mapParentNote, force: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadGeoMapData(vm: NoteDetailViewModel, note: NoteItem, force: Bool = false) {
        let now = Date()
        if !force,
           note.noteId == geoMapLastLoadNoteId,
           now.timeIntervalSince(geoMapLastLoadAt) < 10 {
            return
        }
        geoMapLastLoadNoteId = note.noteId
        geoMapLastLoadAt = now
        let newSettings = GeoMapDisplaySettings(from: note, defaultStyle: GeoMapStyleID.triliumDefault(for: appState.serverAppInfo))
        if newSettings != geoMapDisplaySettings {
            geoMapDisplaySettings = newSettings
            geoMapCachedSettingsJSON = newSettings.bridgeJSON()
        }
        Task { @MainActor in
            let pins: [GeoMapPin]
            let tracks: [GeoMapTrack]
            let shapes: [GeoMapShape]
            if vm.client != nil, vm.isOnline {
                (pins, shapes, tracks) = await vm.fetchGeoMapLayersFromServer(note: note)
            } else {
                pins = vm.geoMapPinsFromCache()
                tracks = vm.geoMapTracksFromCache()
                shapes = vm.geoMapShapesFromCache()
            }
            if pins == geoMapPins, tracks == geoMapTracks, shapes == geoMapShapes {
                return
            }
            geoMapPins = pins
            geoMapTracks = tracks
            geoMapShapes = shapes
            Log.geoMap.info(
                "[geo-map-debug] loadGeoMapData pins=\(pins.count) tracks=\(tracks.count) shapes=\(shapes.count) online=\(vm.isOnline)"
            )
        }
    }

    private func loadGeoMapPins(vm: NoteDetailViewModel, note: NoteItem) {
        loadGeoMapData(vm: vm, note: note)
    }

    /// What a note is on this map: a pin, a GPX track or a drawn shape (nil when it isn't on it).
    private func geoMapFeatureKind(forNoteId noteId: String) -> GeoMapFeatureKind? {
        if geoMapPins.contains(where: { $0.noteId == noteId }) { return .pin }
        if geoMapTracks.contains(where: { $0.noteId == noteId }) { return .track }
        if geoMapShapes.contains(where: { $0.noteId == noteId }) { return .shape }
        return nil
    }

    private func clearGeoMapSelection() {
        geoMapSelection = nil
        geoMapDetailHTML = nil
        geoMapDetailGPXStats = nil
        geoMapFocusedMarkId = nil
        geoMapLastScrolledMarkId = nil
        geoMapEditorBridge.clearSelection()
    }

    private func geoMapDetailScrollAnchorId(for rawMarkId: String) -> String? {
        guard let selection = geoMapSelection, selection.kind == .track,
              let track = geoMapTracks.first(where: { $0.noteId == selection.noteId }) else { return nil }
        if rawMarkId == "summary" {
            guard let stats = geoMapDetailGPXStats,
                  let focus = track.journeyFocus(at: 0, stats: stats) else { return nil }
            return GeoMapMarkFocus.scrollAnchorId(for: focus.markId)
        }
        let normalized = GeoMapMarkFocus.normalizedListMarkId(rawMarkId)
        if normalized.hasPrefix("waypoint:") || normalized.hasPrefix("line-start:") {
            return GeoMapMarkFocus.scrollAnchorId(for: normalized)
        }
        return nil
    }

    private func scrollGeoMapDetailToMark(_ rawMarkId: String?, proxy: ScrollViewProxy) {
        guard let rawMarkId, rawMarkId != geoMapLastScrolledMarkId,
              let anchorId = geoMapDetailScrollAnchorId(for: rawMarkId) else { return }
        geoMapLastScrolledMarkId = rawMarkId
        Log.geoMap.info("[geo-map-debug] scrollToMark raw=\(rawMarkId) anchor=\(anchorId)")
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(anchorId, anchor: .center)
        }
    }

    private func handleGeoMapFeatureSelected(
        vm: NoteDetailViewModel,
        noteId: String,
        kind: GeoMapFeatureKind,
        markFocus: GeoMapMarkFocus? = nil
    ) {
        let nextMarkId = markFocus?.markId
        if geoMapSelection?.noteId == noteId,
           geoMapSelection?.kind == kind,
           geoMapFocusedMarkId == nextMarkId {
            Log.geoMap.info("[geo-map-debug] featureSelected SKIP duplicate noteId=\(noteId) markId=\(nextMarkId ?? "nil")")
            return
        }
        Log.geoMap.info("[geo-map-debug] featureSelected noteId=\(noteId) kind=\(kind.rawValue) markId=\(nextMarkId ?? "nil")")
        let isSameNote = geoMapSelection?.noteId == noteId
        geoMapSelection = GeoMapSelection(noteId: noteId, kind: kind)
        geoMapFocusedMarkId = nextMarkId
        if nextMarkId != geoMapLastScrolledMarkId {
            geoMapLastScrolledMarkId = nil
        }
        if !isSameNote || kind != .track {
            geoMapDetailHTML = nil
            geoMapDetailGPXStats = nil
        }
        Task {
            if kind == .pin || kind == .shape {
                geoMapDetailHTML = await vm.geoMapChildHTML(for: noteId)
            } else if let track = geoMapTracks.first(where: { $0.noteId == noteId }) {
                geoMapDetailGPXStats = GeoMapGPXParser.parse(track.gpxXML)
            }
        }
    }

    private func saveGeoMapSettings(vm: NoteDetailViewModel, note: NoteItem) {
        geoMapEditorBridge.applySettings(geoMapDisplaySettings.bridgeJSON())
        guard let client = vm.client else { return }
        Task {
            do {
                let updated = try await geoMapDisplaySettings.apply(to: note, via: client)
                vm.note = updated
            } catch {
                Log.geoMap.error("Failed to save geo map settings: \(error.localizedDescription)")
            }
        }
    }

    private func handleGeoMapGpxImport(result: Result<[URL], Error>, vm: NoteDetailViewModel, note: NoteItem) {
        switch result {
        case .failure(let error):
            Log.geoMap.error("GPX import picker failed: \(error.localizedDescription)")
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    let data = try Data(contentsOf: url)
                    let track = try await vm.importGeoMapGpxFile(
                        data: data,
                        filename: url.lastPathComponent,
                        parentNoteId: note.noteId
                    )
                    geoMapTracks.append(track)
                    geoMapEditorBridge.loadTracks(geoMapTracks.bridgeJSONArray())
                    await vm.loadChildNotes()
                    appState.backgroundSyncPendingChanges()
                } catch {
                    Log.geoMap.error("GPX import failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleGeoMapRemoveTrack(vm: NoteDetailViewModel, noteId: String, mapParentNote: NoteItem) {
        Task {
            let ok = await vm.deleteChildNote(noteId: noteId)
            guard ok else { return }
            clearGeoMapSelection()
            if vm.client != nil, vm.isOnline {
                await vm.refreshDirectChildrenMetadataFromServer()
            } else {
                await vm.loadChildNotes()
            }
            loadGeoMapData(vm: vm, note: mapParentNote, force: true)
        }
    }

    /// Saves a shape drawn on the map as Trilium v0.106 does: a text note under the map carrying `#geoShape`, named by
    /// a map's `#titleTemplate` where it has one, with no `#iconClass` (the shape's own icon shows). Drawn at once.
    private func handleGeoMapShapeDrawn(
        vm: NoteDetailViewModel,
        note: NoteItem,
        kind: GeoMapShape.Kind,
        coordinates: [[Double]],
        radiusMeters: Double?
    ) {
        guard let value = GeoMapShape.serializedValue(kind: kind, coordinates: coordinates, radiusMeters: radiusMeters) else { return }
        Task {
            guard let profileId = vm.serverProfileId else { return }
            let title = String(localized: "New Shape", comment: "Default title for a shape drawn on a geo map")
            do {
                let (newNoteId, _) = try PersistenceManager.shared.createOfflineChildNote(
                    parentNoteId: note.noteId,
                    title: title,
                    noteType: "text",
                    mime: "text/html",
                    initialContent: "",
                    serverProfileId: profileId,
                    initialAttributes: [NoteCreationAttribute(type: "label", name: GeoMapShape.label, value: value)],
                    useParentTitleTemplate: true
                )
                if let shape = GeoMapShape(noteId: newNoteId, title: title, value: value, color: nil) {
                    geoMapShapes.append(shape)
                }
                await vm.loadChildNotes()
                appState.backgroundSyncPendingChanges()
            } catch {
                Log.geoMap.error("Failed to create geo map shape: \(error.localizedDescription)")
            }
        }
    }

    /// `placeName` titles a pin dropped on a searched place (as the web map does); without one, the default title
    /// stands in and a map's `#titleTemplate` names the pin.
    private func handleGeoMapCreatePin(vm: NoteDetailViewModel, note: NoteItem, lat: Double, lng: Double, title placeName: String? = nil) {
        Task {
            guard let profileId = vm.serverProfileId else { return }
            let title = placeName ?? String(localized: "New Location", comment: "Default title for new geo map pin")
            do {
                let (newNoteId, _) = try PersistenceManager.shared.createOfflineChildNote(
                    parentNoteId: note.noteId,
                    title: title,
                    noteType: "text",
                    mime: "text/html",
                    initialContent: "",
                    serverProfileId: profileId,
                    // v0.106 writes no #iconClass on new markers, so a template's or #child:iconClass icon applies and
                    // the default pin shows otherwise; older servers show a plain note icon without one.
                    initialAttributes: [NoteCreationAttribute(type: "label", name: "geolocation", value: "\(lat),\(lng)")]
                        + (TriliumServerCompatibility.supportsGeoNoteIcons(appState.serverAppInfo)
                            ? []
                            : [NoteCreationAttribute(type: "label", name: "iconClass", value: "bx bx-map-pin")]),
                    // "New Location" is a placeholder: a map's #titleTemplate names new markers, as on the web.
                    useParentTitleTemplate: placeName == nil
                )

                let pin = GeoMapPin(noteId: newNoteId, title: title, lat: lat, lng: lng)
                geoMapPins.append(pin)
                geoMapEditorBridge.addPin(noteId: newNoteId, title: title, lat: lat, lng: lng)
                await vm.loadChildNotes()
                appState.backgroundSyncPendingChanges()
            } catch {
                Log.geoMap.error("Failed to create geo map pin: \(error.localizedDescription)")
            }
        }
    }

    private func handleGeoMapMovePin(vm: NoteDetailViewModel, noteId: String, lat: Double, lng: Double) {
        Task {
            guard let client = vm.client else { return }
            do {
                let noteResp = try await client.getNote(noteId)
                let noteItem = NoteItem(from: noteResp)
                if let existingAttr = noteItem.attributes.first(where: { $0.type == .label && $0.name == "geolocation" }) {
                    try await client.deleteAttribute(noteId: noteId, attributeId: existingAttr.attributeId)
                }
                try await client.createAttribute(CreateAttributeRequest(
                    noteId: noteId, type: "label", name: "geolocation",
                    value: "\(lat),\(lng)", isInheritable: nil, position: nil
                ))
                if let idx = geoMapPins.firstIndex(where: { $0.noteId == noteId }) {
                    let existing = geoMapPins[idx]
                    geoMapPins[idx] = GeoMapPin(
                        noteId: noteId, title: existing.title, lat: lat, lng: lng,
                        iconClass: existing.iconClass, color: existing.color
                    )
                }
                if let n = vm.note {
                    loadGeoMapPins(vm: vm, note: n)
                }
            } catch {
                Log.geoMap.error("Failed to move geo map pin: \(error.localizedDescription)")
            }
        }
    }

    private func handleGeoMapRemovePin(vm: NoteDetailViewModel, noteId: String) {
        Task {
            let ok = await vm.deleteChildNote(noteId: noteId)
            guard ok else { return }
            if geoMapSelection?.noteId == noteId { clearGeoMapSelection() }
            geoMapPins.removeAll { $0.noteId == noteId }
            geoMapEditorBridge.removePin(noteId: noteId)
            if vm.client != nil, vm.isOnline {
                await vm.refreshDirectChildrenMetadataFromServer()
            } else {
                await vm.loadChildNotes()
            }
            if let n = vm.note {
                loadGeoMapData(vm: vm, note: n, force: true)
            }
        }
    }

    /// Rewrites geo map blob to Trilium desktop’s shape: `{ "view": { "center": { "lat", "lng" }, "zoom" } }`.
    /// Fixes legacy top-level `{ center, zoom }`, and bad longitude keys (`Ing` vs `lng`) so Leaflet on desktop can parse.
    private static func canonicalGeoMapViewportJSONForTriliumDesktop(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return raw
        }
        var view = root["view"] as? [String: Any]
        if view == nil, root["center"] != nil, root["zoom"] != nil {
            view = ["center": root["center"] as Any, "zoom": root["zoom"] as Any]
        }
        guard var viewDict = view, let zoom = viewDict["zoom"] else { return raw }

        let centerAny = viewDict["center"]
        var latVal: Double?
        var lngVal: Double?

        if let arr = centerAny as? [Any], arr.count >= 2 {
            latVal = doubleFromJSONNumber(arr[0])
            lngVal = doubleFromJSONNumber(arr[1])
        } else if let dict = centerAny as? [String: Any] {
            latVal = doubleFromJSONNumber(dict["lat"])
            lngVal = doubleFromJSONNumber(dict["lng"])
                ?? doubleFromJSONNumber(dict["Ing"])
                ?? doubleFromJSONNumber(dict["long"])
                ?? doubleFromJSONNumber(dict["lon"])
        }

        guard let lat = latVal, let lng = lngVal, let zoomVal = doubleFromJSONNumber(zoom) else { return raw }

        let canonical: [String: Any] = [
            "view": [
                "center": [
                    "lat": (lat * 10000).rounded() / 10000,
                    "lng": (lng * 10000).rounded() / 10000,
                ],
                "zoom": (zoomVal * 100).rounded() / 100,
            ]
        ]
        guard let out = try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys]),
              let s = String(data: out, encoding: .utf8) else { return raw }
        return s
    }

    private static func doubleFromJSONNumber(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// JSON body shape Trilium uses for geo map viewport (`view.center` + `view.zoom`).
    /// Also accepts legacy Trinote saves that omitted the `view` wrapper.
    private func geoMapViewportJSONMatches(_ contentString: String?) -> Bool {
        guard let content = contentString, !content.isEmpty,
              let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        func hasZoom(_ any: Any?) -> Bool { any is NSNumber }
        if let view = obj["view"] as? [String: Any], view["center"] != nil, hasZoom(view["zoom"]) {
            return true
        }
        if obj["center"] != nil, hasZoom(obj["zoom"]) { return true }
        return false
    }

    /// Detects geo map notes: semantic geo (`geoMap` or `book` + `#viewType=geoMap`), viewport JSON in the body, or `book` with a child that has `#geolocation` in cache.
    /// Calendar roots are excluded even if children have geolocation labels.
    private func isGeoMapNote(_ note: NoteItem?, contentString: String?, vm: NoteDetailViewModel?) -> Bool {
        guard let note else { return false }
        if note.isCalendarRoot { return false }
        if note.isSemanticGeoMap { return true }
        if geoMapViewportJSONMatches(contentString) { return true }
        if (note.type == .book || note.type == .collection), let vm, vm.cachedAnyChildHasGeolocationLabel() { return true }
        return false
    }

    /// Valid Trilium-shaped viewport JSON for map WebViews; defaults when body is empty or not yet loaded.
    private func effectiveGeoMapViewportJSONForDisplay(_ contentString: String?) -> String {
        let trimmed = (contentString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, geoMapViewportJSONMatches(contentString) else {
            return NoteType.emptyGeoMapJSON
        }
        return Self.canonicalGeoMapViewportJSONForTriliumDesktop(trimmed)
    }

    private func handleEditorPhotoPicks(_ images: [PhotoLibraryImage]) async {
        let batch = Array(images.prefix(20))
        guard !batch.isEmpty, let vm = viewModel else { return }
        // Reserve a slot per photo before the first upload, then fill them as each one lands.
        let webView = editorWebView
        Self.beginEditorImageBatch(webView: webView, count: batch.count)
        await vm.uploadPhotosAsAttachments(batch) { insert in
            Self.insertBatchImageInEditor(webView: webView, insert: insert)
        }
        Self.endEditorImageBatch(webView: webView)
    }

    private func handleEditorFilePick(_ result: Result<[URL], Error>) async {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            let data = try Data(contentsOf: url)
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let filename = url.lastPathComponent.isEmpty ? "attachment" : url.lastPathComponent

            if mime.hasPrefix("image/") {
                let imageData: Data
                let imageMime: String
                if let uiImage = UIImage(data: data), let jpeg = uiImage.jpegData(compressionQuality: 0.8) {
                    imageData = jpeg
                    imageMime = "image/jpeg"
                } else {
                    imageData = data
                    imageMime = mime
                }
                imageToInsert = "data:\(imageMime);base64,\(imageData.base64EncodedString())"
            } else {
                presentAttachmentUploadNamePrompt(data: data, mime: mime, filename: filename)
            }
        } catch {
            Log.ui.error("Editor file pick failed: \(error.localizedDescription)")
        }
    }

    @ViewBuilder
    private func codeEditingView(_ vm: NoteDetailViewModel) -> some View {
        @Bindable var vm = vm
        ZStack(alignment: .bottomTrailing) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $vm.editableContent)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .scrollContentBackground(.hidden)
                    .contentMargins(
                        .bottom,
                        NoteDetailFloatingChipLayout.scrollClearance(findBarPresented: false, editing: true),
                        for: .scrollContent
                    )
                    .background(Color(.systemGroupedBackground))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if vm.editableContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Match UITextView origin: TextEditor’s 8pt horizontal padding + 5pt
                    // `lineFragmentPadding`, and the default 8pt top `textContainerInset`.
                    Text(String(localized: "Start writing…", comment: "Empty code note editor placeholder"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.42))
                        .padding(.leading, 13)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(
                NoteDetailScrollOffsetReader { y, verticallyScrollable, _, _ in
                    updateEditorSaveCancelChipVisibility(contentOffsetY: y, verticallyScrollable: verticallyScrollable)
                }
                .frame(width: 0, height: 0)
            )

            if showEditorSaveCancelChip && !hidesEditorSaveButton {
                editorSaveChip(vm: vm)
                    .padding(.trailing, 16)
                    .padding(.bottom, 62)
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            editorSaveCancelScrollBaselineReady = false
            lastEditorScrollOffsetY = 0
            cancelEditorSaveChipIdleShowTask()
            editorSaveChipIgnoreTypingUntil = Date().addingTimeInterval(Self.editorSaveChipIgnoreTypingAfterAppear)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                showEditorSaveCancelChip = true
            }
        }
        .onDisappear {
            cancelEditorSaveChipIdleShowTask()
        }
        .onChange(of: vm.editableContent) { _, body in
            handleEditorSaveChipTypingActivity()
            if vm.noteEditedBody(body) { scheduleAutosave(vm: vm) }
        }
    }

    private func attachmentsSection(_ vm: NoteDetailViewModel) -> AnyView {
        AnyView(attachmentsSectionContent(vm))
    }

    @ViewBuilder
    private func attachmentsSectionContent(_ vm: NoteDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text(String(localized: "Attachments", comment: "Note detail section"))
                    .font(.headline)
                Spacer()
                if !vm.attachments.isEmpty {
                    Button {
                        showDeleteAllAttachmentsConfirm = true
                    } label: {
                        Label(
                            String(localized: "Remove All", comment: "Delete every attachment on the note"),
                            systemImage: "trash"
                        )
                    }
                    .disabled(vm.isSaving || !vm.isOnline)
                    .accessibilityLabel(
                        String(localized: "Remove all attachments", comment: "Accessibility label for delete-all attachments")
                    )
                }
                AttachmentUploadButton(noteId: vm.noteId, viewModel: vm)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if vm.attachments.isEmpty {
                Text(String(localized: "No attachments", comment: "Attachments empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ForEach(vm.attachments) { attachment in
                    AttachmentRow(attachment: attachment, viewModel: vm) { noteId, _ in
                        navigateToNoteId = noteId
                    }
                }
            }
        }
        .alert(
            String(localized: "Remove All Attachments?", comment: "Delete-all attachments confirm title"),
            isPresented: $showDeleteAllAttachmentsConfirm
        ) {
            Button(String(localized: "Cancel", comment: "Cancel delete-all attachments"), role: .cancel) {}
            Button(
                String(localized: "Remove All", comment: "Confirm delete-all attachments"),
                role: .destructive
            ) {
                Task { await vm.deleteAllAttachments() }
            }
        } message: {
            Text(
                String(
                    localized: "Delete all \(vm.attachments.count) attachments from this note? This cannot be undone.",
                    comment: "Delete-all attachments confirm message; count is substituted"
                )
            )
        }
    }

    private func metadataSection(_ note: NoteItem) -> AnyView {
        AnyView(metadataSectionContent(note))
    }

    private func metadataSectionContent(_ note: NoteItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Group {
                LabeledContent(String(localized: "Note ID", comment: "Metadata field"), value: note.noteId)
                LabeledContent(String(localized: "Type", comment: "Metadata field"), value: note.uiNoteTypeDisplayName)
                LabeledContent(String(localized: "MIME", comment: "Metadata field"), value: note.mime)
                if !note.dateCreated.isEmpty {
                    LabeledContent(String(localized: "Created", comment: "Metadata field"), value: note.dateCreated)
                }
                if !note.dateModified.isEmpty {
                    LabeledContent(String(localized: "Modified", comment: "Metadata field"), value: note.dateModified)
                }
            }
            .font(.caption)

            if !note.attributes.isEmpty {
                Text(String(localized: "Attributes", comment: "Metadata section"))
                    .font(.caption.weight(.medium))
                    .padding(.top, 4)
                ForEach(note.attributes) { attr in
                    HStack {
                        Image(systemName: attr.type == .label ? "tag" : "arrow.right")
                            .font(.caption2)
                        Text(attr.name)
                            .font(.caption.weight(.medium))
                        Text(attr.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    @ToolbarContentBuilder
    private func noteToolbar(_ vm: NoteDetailViewModel, note: NoteItem) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Favorite first (leftmost), always at hand whatever the last-used quick action is.
            if !vm.isEditing, isToolbarQuickActionAvailable(.favorite, vm: vm, note: note) {
                Button {
                    toggleFavorite(note: note, isFavorite: favoriteNoteIds.contains(note.noteId))
                } label: {
                    toolbarQuickActionLabel(.favorite, vm: vm, note: note)
                }
                .accessibilityLabel(toolbarQuickActionAccessibilityLabel(.favorite, vm: vm, note: note))
            }

            // Then the last-used quick action, then ⋯.
            // Details (the default) live in the ⋯ menu, so the bar stays narrow: star and ⋯, plus
            // a quick action only once another one has been used (or Cancel while editing).
            if let quick = firstAvailableToolbarQuickAction(vm: vm, note: note), quick != .noteDetails, quick != .favorite {
                Button {
                    performToolbarQuickAction(quick, vm: vm, note: note)
                } label: {
                    toolbarQuickActionLabel(quick, vm: vm, note: note)
                }
                .disabled(isToolbarQuickActionDisabled(quick, vm: vm))
                .accessibilityLabel(toolbarQuickActionAccessibilityLabel(quick, vm: vm, note: note))
            }

            Button {
                // The keyboard took the room the menu needs (iPad popover, phone sheet): lower it.
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                showNoteOverflowMenu = true
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(String(localized: "Note actions", comment: "Overflow menu"))
            .popover(isPresented: noteOverflowPresentationBinding(asPopover: true), arrowEdge: .top) {
                VStack(spacing: 0) {
                    noteOverflowActionButtons(vm: vm, note: note)
                }
                .padding(.vertical, 8)
                .modifier(NoteOverflowPopoverSizingModifier())
            }

            if usesNoteInspector {
                Button {
                    showsNoteInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .accessibilityLabel(
                    showsNoteInspector
                        ? String(localized: "Hide Note Panel", comment: "iPad: hide the table of contents / info column")
                        : String(localized: "Show Note Panel", comment: "iPad: show the table of contents / info column")
                )
            }
        }
    }

    // MARK: - Note inspector (iPad)

    /// iPad split layout: table of contents and note details in a column beside the note (Trilium's right
    /// pane) instead of below it.
    /// Off: this belonged to upstream's desktop-style iPad layout, which the fork does not use.
    private var usesNoteInspector: Bool { false }

    private var noteInspectorTab: NoteInspectorTab {
        get { NoteInspectorTab(rawValue: noteInspectorTabRaw) ?? .contents }
        nonmutating set { noteInspectorTabRaw = newValue.rawValue }
    }

    private var noteInspectorBinding: Binding<Bool> {
        Binding(
            get: { usesNoteInspector && showsNoteInspector },
            set: { showsNoteInspector = $0 }
        )
    }

    private func noteDetailsShown(_ vm: NoteDetailViewModel) -> Bool {
        usesNoteInspector ? showsNoteInspector && noteInspectorTab == .info : vm.showDetails
    }

    /// "Note Details": the inspector's Info tab on iPad, the section below the note elsewhere.
    private func toggleNoteDetails(_ vm: NoteDetailViewModel) {
        guard usesNoteInspector else {
            withAnimation { vm.showDetails.toggle() }
            return
        }
        if noteDetailsShown(vm) {
            showsNoteInspector = false
        } else {
            noteInspectorTab = .info
            showsNoteInspector = true
        }
    }

    @ViewBuilder
    private func noteInspector(_ vm: NoteDetailViewModel, note: NoteItem) -> some View {
        VStack(spacing: 0) {
            Picker(
                String(localized: "Note Panel", comment: "iPad note inspector tab picker"),
                selection: Binding(get: { noteInspectorTab }, set: { noteInspectorTab = $0 })
            ) {
                Text(String(localized: "Contents", comment: "iPad note inspector tab: table of contents")).tag(NoteInspectorTab.contents)
                Text(String(localized: "Info", comment: "iPad note inspector tab: note details")).tag(NoteInspectorTab.info)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            switch noteInspectorTab {
            case .contents:
                tableOfContents(vm)
            case .info:
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        metadataSection(note)
                        attachmentsSection(vm)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Re-read headings when a document finishes loading, editing ends, or the tab shows.
        .task(id: "\(findControl.loadedHTMLDocumentCount)-\(vm.isEditing)-\(noteInspectorTabRaw)") {
            guard noteInspectorTab == .contents, !vm.isEditing else { return }
            let control = findControl
            tocHeadings = await withCheckedContinuation { continuation in
                control.readHeadings { continuation.resume(returning: $0) }
            }
        }
    }

    @ViewBuilder
    private func tableOfContents(_ vm: NoteDetailViewModel) -> some View {
        if vm.isEditing {
            ContentUnavailableView(
                String(localized: "Contents Show While Reading", comment: "iPad table of contents while editing"),
                systemImage: "list.bullet.indent",
                description: Text(String(localized: "Save or cancel your edit to see this note's headings.", comment: "iPad table of contents while editing"))
            )
        } else if tocHeadings.isEmpty {
            ContentUnavailableView(
                String(localized: "No Headings", comment: "iPad table of contents empty"),
                systemImage: "list.bullet.indent",
                description: Text(String(localized: "Headings in this note appear here.", comment: "iPad table of contents empty hint"))
            )
        } else {
            let topLevel = tocHeadings.map(\.level).min() ?? 1
            List(tocHeadings) { heading in
                Button {
                    findControl.scrollToHeading(at: heading.index)
                } label: {
                    Text(heading.text)
                        .font(heading.level == topLevel ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .padding(.leading, CGFloat(heading.level - topLevel) * 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
            .listStyle(.plain)
        }
    }

    /// Wide windows (iPad) show the ⋯ actions as a popover on the button, like a desktop menu; narrow
    /// ones keep the bottom sheet.
    private func noteOverflowPresentationBinding(asPopover: Bool) -> Binding<Bool> {
        Binding(
            get: { showNoteOverflowMenu && (horizontalSizeClass == .regular) == asPopover },
            set: { if !$0 { showNoteOverflowMenu = false } }
        )
    }

    @ViewBuilder
    private func noteOverflowActionsSheet(vm: NoteDetailViewModel, note: NoteItem) -> some View {
        VStack(spacing: 0) {
            noteOverflowActionButtons(vm: vm, note: note)
        }
        .padding(.top, 4)
        .padding(.bottom, 28)
        .modifier(NoteOverflowSheetSizingModifier())
    }

    @ViewBuilder
    private func noteOverflowActionButtons(vm: NoteDetailViewModel, note: NoteItem) -> some View {
        // Apple Intelligence first, in a section of its own (TestFlight feedback).
        if NoteSummaryModel.isAvailable, Self.summarizableTypes.contains(note.type), !vm.needsProtectedSession {
            Label(String(localized: "Apple Intelligence", comment: "Note overflow: section header for on-device AI actions"), systemImage: "apple.intelligence")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.trinoteTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            Button {
                dismissNoteOverflowThen { summarizeFinishingEdit(vm: vm, note: note) }
            } label: {
                noteOverflowLabel(String(localized: "Summarize", comment: "Note overflow: Apple Intelligence summary"), systemImage: "apple.intelligence")
            }
            .buttonStyle(.plain)
            Button {
                dismissNoteOverflowThen { runNoteAIFinishingEdit(.todos, vm: vm, note: note) }
            } label: {
                noteOverflowLabel(String(localized: "Find To-dos", comment: "Note overflow: Apple Intelligence extracts action items"), systemImage: "checklist")
            }
            .buttonStyle(.plain)
            Button {
                dismissNoteOverflowThen { runNoteAIFinishingEdit(.title, vm: vm, note: note) }
            } label: {
                noteOverflowLabel(String(localized: "Suggest Title", comment: "Note overflow: Apple Intelligence title"), systemImage: "character.cursor.ibeam")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 20)
        }
        if note.type.isEditable {
            Button {
                dismissNoteOverflow()
                if vm.isEditing {
                    saveEditedContent(vm: vm, note: note)
                } else {
                    vm.startEditing()
                }
            } label: {
                if vm.isEditing {
                    noteOverflowLabel(
                        String(localized: "Save", comment: "Save note from editor overflow menu"),
                        systemImage: "checkmark.circle"
                    )
                } else {
                    Label {
                        Text(String(localized: "Edit Note", comment: "Open note editor"))
                    } icon: {
                        Image("EditNoteFloating")
                            .renderingMode(.template)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .disabled(vm.needsProtectedSession || (vm.isEditing && vm.isSaving))
        }

        if vm.isEditing {
            Button {
                // After the menu closes: Cancel may ask first (Autosave already saved part of the edit).
                dismissNoteOverflowThen { cancelNoteEditing(vm: vm, note: note) }
            } label: {
                noteOverflowLabel(
                    String(localized: "Cancel Editing", comment: "Leave note editor from overflow menu"),
                    systemImage: "xmark"
                )
            }
            .buttonStyle(.plain)
        } else {
            Button {
                recordToolbarQuickAction(.newChild)
                dismissNoteOverflowThen { vm.showCreateChild = true }
            } label: {
                noteOverflowLabel(String(localized: "New Child Note", comment: "Note overflow menu"), systemImage: "plus")
            }
            .buttonStyle(.plain)
        }

        if !note.isProtected || appState.protectedSessionActive {
            Button {
                recordToolbarQuickAction(.duplicate)
                dismissNoteOverflow()
                Task {
                    if let dup = await vm.duplicateNote() {
                        navigateToNoteId = dup.noteId
                    }
                }
            } label: {
                noteOverflowLabel(String(localized: "Duplicate", comment: "Note overflow menu"), systemImage: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .disabled(vm.isSaving)
        }

        if note.noteId != TriliumTreeConstants.rootNoteId, !note.isProtected || appState.protectedSessionActive {
            Button {
                dismissNoteOverflowThen { showMoveParentPicker = true }
            } label: {
                noteOverflowLabel(
                    String(localized: "Move", comment: "Note overflow: move under another parent"),
                    systemImage: "arrow.forward.folder"
                )
            }
            .buttonStyle(.plain)
            .disabled(vm.client == nil || vm.isSaving)
        }

        Button {
            dismissNoteOverflow()
            vm.editedTitle = note.title
            vm.editingTitle = true
        } label: {
            noteOverflowLabel(String(localized: "Rename", comment: "Note overflow menu"), systemImage: "pencil")
        }
        .buttonStyle(.plain)

        if canChangeNoteAppearance(note) {
            Button {
                dismissNoteOverflowThen { showAppearancePicker = true }
            } label: {
                noteOverflowLabel(
                    String(localized: "Change Icon/Color", comment: "Note overflow menu: open appearance picker"),
                    systemImage: "paintpalette"
                )
            }
            .buttonStyle(.plain)
            .disabled(vm.isSaving)
        }

        Divider().padding(.leading, 20)

        Button {
            recordToolbarQuickAction(.noteDetails)
            dismissNoteOverflow()
            toggleNoteDetails(vm)
        } label: {
            noteOverflowLabel(
                noteDetailsShown(vm)
                    ? String(localized: "Hide Details", comment: "Note overflow toggle details")
                    : String(localized: "Note Details", comment: "Note overflow toggle details"),
                systemImage: noteDetailsShown(vm) ? "info.circle.fill" : "info.circle"
            )
        }
        .buttonStyle(.plain)

        Divider().padding(.leading, 20)

        if NotePrinter.isAvailable, !(note.isProtected && vm.needsProtectedSession) {
            Button {
                dismissNoteOverflowThen { NotePrinter.print(note: note, viewModel: vm) }
            } label: {
                noteOverflowLabel(String(localized: "Print", comment: "Print a note or PDF"), systemImage: "printer")
            }
            .buttonStyle(.plain)
        }

        if note.type == .spreadsheet, TriliumServerCompatibility.supportsSpreadsheetXlsxExport(appState.serverAppInfo) {
            Button {
                dismissNoteOverflowThen { exportSpreadsheetToXlsx(vm: vm) }
            } label: {
                noteOverflowLabel(
                    vm.isOnline
                        ? String(localized: "Export to Excel (.xlsx)", comment: "Note overflow: spreadsheet export, as in Trilium")
                        : String(localized: "Export to Excel needs a connection", comment: "Note overflow: spreadsheet export offline"),
                    systemImage: "tablecells"
                )
            }
            .buttonStyle(.plain)
            .disabled(!vm.isOnline || isExportingSpreadsheetXlsx || vm.needsProtectedSession || vm.isSaving)
        }

        if !(note.isProtected && vm.needsProtectedSession) {
            Button {
                let items = noteShareItems(note: note, vm: vm)
                dismissNoteOverflowThen { scheduleNoteDetailShareSheet(items: items) }
            } label: {
                noteOverflowLabel(String(localized: "Share…", comment: "Note overflow: system share sheet"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
        }

        if CrossInstanceCopyAvailability.shouldShowMenuItem(noteId: note.noteId) {
            if note.isProtected || vm.needsProtectedSession {
                noteOverflowLabel(
                    String(localized: "Copy to Instance unavailable (protected note)", comment: "Copy to instance disabled"),
                    systemImage: "lock.fill"
                )
                .foregroundStyle(.secondary)
                .disabled(true)
            } else {
                Button {
                    dismissNoteOverflowThen { showCopyToInstance = true }
                } label: {
                    noteOverflowLabel(
                        String(localized: "Copy to Instance…", comment: "Note overflow: copy to another signed-in instance"),
                        systemImage: "square.on.square"
                    )
                }
                .buttonStyle(.plain)
            }
        }

        if appState.activeProfile != nil {
            Button {
                recordToolbarQuickAction(.favorite)
                dismissNoteOverflow()
                toggleFavorite(note: note, isFavorite: favoriteNoteIds.contains(note.noteId))
            } label: {
                if favoriteNoteIds.contains(note.noteId) {
                    noteOverflowLabel(String(localized: "Remove from Favorites", comment: "Note overflow"), systemImage: "star.slash")
                } else {
                    noteOverflowLabel(String(localized: "Add to Favorites", comment: "Note overflow"), systemImage: "star")
                }
            }
            .buttonStyle(.plain)
        }

        if !vm.isEditing, !vm.needsProtectedSession {
            Button {
                dismissNoteOverflowThen { exportMarkdown(note: note) }
            } label: {
                noteOverflowLabel(String(localized: "Export as Markdown…", comment: "Note overflow: save the note and its sub-notes as Markdown files"), systemImage: "arrow.down.doc")
            }
            .buttonStyle(.plain)
        }

        if !vm.isEditing && note.type.supportsReadOnlyOnPageFind {
            Button {
                recordToolbarQuickAction(.findOnPage)
                dismissNoteOverflow()
                if findControl.isPresented {
                    findControl.close()
                } else {
                    findControl.isPresented = true
                }
            } label: {
                noteOverflowLabel(
                    findControl.isPresented
                        ? String(localized: "Hide Find Bar", comment: "Close in-page search")
                        : String(localized: "Find on Page", comment: "Open in-page search for read-only note"),
                    systemImage: "magnifyingglass"
                )
            }
            .buttonStyle(.plain)
        }

        Divider().padding(.leading, 20)

        Button(role: .destructive) {
            dismissNoteOverflowThen {
                eraseNotesOnDelete = false
                vm.showDeleteConfirm = true
            }
        } label: {
            noteOverflowLabel(String(localized: "Delete Note", comment: "Note overflow"), systemImage: "trash")
        }
        .buttonStyle(.plain)
    }

    /// Builds the bundle from the cache (works offline) and hands it to the file exporter, which
    /// can save to iCloud Drive or any Files location.
    private func exportMarkdown(note: NoteItem) {
        guard let profileId = appState.activeProfile?.id else { return }
        let exporter = MarkdownBundleExporter(context: PersistenceManager.shared.context, profileId: profileId)
        do {
            let (wrapper, summary) = try exporter.export(rootNoteId: note.noteId)
            markdownExportFilename = wrapper.preferredFilename ?? MarkdownBundleExporter.safeFilename(note.title)
            markdownExport = MarkdownBundleDocument(wrapper: wrapper)
            var parts = [summary.notes == 1
                ? String(localized: "1 note", comment: "Markdown export result")
                : String(localized: "\(summary.notes) notes", comment: "Markdown export result")]
            if summary.images > 0 {
                parts.append(String(localized: "\(summary.images) images", comment: "Markdown export result"))
            }
            if summary.withoutContent > 0 {
                parts.append(String(localized: "\(summary.withoutContent) not yet downloaded, saved as titles only", comment: "Markdown export result"))
            }
            pendingMarkdownExportSummary = parts.joined(separator: " · ")
        } catch {
            markdownExportMessage = String(localized: "This note isn't saved on this device yet. Open it once while online, then export.", comment: "Markdown export: note not cached")
        }
    }

    private func relatedNotesSection(note: NoteItem) -> AnyView {
        AnyView(relatedNotesSectionContent(note: note))
    }

    @ViewBuilder
    private func relatedNotesSectionContent(note: NoteItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !relatedNotes.isEmpty {
                Label(String(localized: "Related", comment: "Note detail: notes about the same topic"), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.trinoteTextSecondary)
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            ForEach(relatedNotes) { match in
                                Button {
                                    navigateToNoteId = match.noteId
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        NoteIconView(iconClass: nil, fallbackNoteType: NoteType(rawValue: match.noteType) ?? .text, size: .regular, foregroundStyle: .trinoteIcon)
                                        Text(match.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Color.trinoteTextPrimary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .frame(width: 150, height: 74, alignment: .topLeading)
                                    .padding(12)
                                    .contentShape(.rect(cornerRadius: 18))
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                                .hoverEffect(.lift)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(.vertical, relatedNotes.isEmpty ? 0 : 12)
        .animation(.snappy, value: relatedNotes)
        .task(id: note.noteId) {
            guard let profileId = appState.activeProfile?.id else { return }
            let index = RelatedNotes.shared
            relatedNotes = (try? await index.related(to: note.noteId, profileId: profileId)) ?? []
        }
    }

    /// Notes whose screen shows the summary card (their PDFs and pictures are read too).
    static let summarizableTypes: Set<NoteType> = [.text, .code, .markdown]

    /// The summary card shows in reading mode: an open editor is saved and closed first.
    private func summarizeFinishingEdit(vm: NoteDetailViewModel, note: NoteItem) {
        runNoteAIFinishingEdit(.summary, vm: vm, note: note)
    }

    private func runNoteAIFinishingEdit(_ kind: NoteSummaryModel.Kind, vm: NoteDetailViewModel, note: NoteItem) {
        guard vm.isEditing else {
            runNoteAI(kind, vm: vm, note: note)
            return
        }
        saveEditedContent(vm: vm, note: note) { saved in
            guard saved else { return }
            runNoteAI(kind, vm: vm, note: note)
        }
    }

    private func summarize(vm: NoteDetailViewModel, note: NoteItem) {
        runNoteAI(.summary, vm: vm, note: note)
    }

    /// Summary, to-dos or a title from the note's text, in the card above the note.
    private func runNoteAI(_ kind: NoteSummaryModel.Kind, vm: NoteDetailViewModel, note: NoteItem) {
        let raw = vm.contentString ?? ""
        let ownText = note.type == .text ? LabelSuggester.plainText(fromHTML: raw) : raw
        Task {
            // Includes the text in the note's PDFs and images when the note itself is short.
            let text = await NoteVisualText.text(for: note, viewModel: vm, ownText: ownText)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                switch kind {
                case .summary: summaryModel.summarize(title: note.title, plainText: text)
                case .todos: summaryModel.findTodos(title: note.title, plainText: text, existing: NoteSummaryModel.checklistItems(inHTML: raw))
                case .title: summaryModel.suggestTitle(title: note.title, plainText: text)
                }
            }
        }
    }

    /// What the card's add button does: the summary goes on top, the to-dos at the end, a title
    /// renames the note. Nil while the note can't take it (see `canAppendClip`).
    /// Apple Intelligence in the editor's format bar: for text notes it can read.
    private func editorAIAvailable(vm: NoteDetailViewModel) -> Bool {
        NoteSummaryModel.isAvailable && vm.note?.type == .text && !vm.needsProtectedSession
    }

    /// Summary, to-dos or a title from what is in the editor right now, unsaved edits included.
    private func runNoteAIInEditor(_ kind: NoteSummaryModel.Kind, vm: NoteDetailViewModel) {
        guard let note = vm.note, let webView = editorWebView else { return }
        webView.evaluateJavaScript("(function(){try{return window.editorBridge.getContent()}catch(e){return ''}})()") { result, _ in
            let raw = (result as? String).flatMap { $0.isEmpty ? nil : $0 } ?? vm.contentString ?? ""
            let text = LabelSuggester.plainText(fromHTML: raw)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                switch kind {
                case .summary: summaryModel.summarize(title: note.title, plainText: text)
                case .todos: summaryModel.findTodos(title: note.title, plainText: text, existing: NoteSummaryModel.checklistItems(inHTML: raw))
                case .title: summaryModel.suggestTitle(title: note.title, plainText: text)
                }
            }
        }
    }

    /// Puts an Apple Intelligence result at the top of the open editor, like the summary.
    private func insertIntoEditor(_ html: String, atStart: Bool) {
        guard let args = try? String(data: JSONSerialization.data(withJSONObject: [atStart ? "start" : "end", html]), encoding: .utf8) else { return }
        editorWebView?.evaluateJavaScript("try{window.editorBridge.insertTriliumHTMLAt(...\(args))}catch(e){}", completionHandler: nil)
    }

    private func noteAIApply(vm: NoteDetailViewModel) -> (() -> Void)? {
        if vm.isEditing, summaryModel.kind != .title {
            // Summary and to-dos both go on top of the note (TestFlight feedback).
            let html = summaryModel.kind == .summary ? summaryModel.noteHTML : summaryModel.todosHTML
            return {
                insertIntoEditor(html, atStart: true)
                withAnimation(.snappy) { summaryModel.dismiss() }
            }
        }
        switch summaryModel.kind {
        case .summary:
            guard vm.canAppendClip else { return nil }
            return {
                if vm.prependHTML(summaryModel.noteHTML) { withAnimation(.snappy) { summaryModel.dismiss() } }
            }
        case .todos:
            guard vm.canAppendClip else { return nil }
            return {
                // On top of the note, like the summary (TestFlight feedback).
                if vm.prependHTML(summaryModel.todosHTML) { withAnimation(.snappy) { summaryModel.dismiss() } }
            }
        case .title:
            // The title is its own field, so it can change while the body is being edited.
            guard !vm.needsProtectedSession else { return nil }
            return {
                let title = summaryModel.text
                guard !title.isEmpty else { return }
                vm.editedTitle = title
                Task {
                    await vm.renameNote()
                    withAnimation(.snappy) { summaryModel.dismiss() }
                }
            }
        }
    }

    // MARK: - Sub-note long-press menu

    /// The long-press menu on a note's title: Apple Intelligence on top, then the everyday actions.
    @ViewBuilder
    private func noteTitleMenu(vm: NoteDetailViewModel, note: NoteItem) -> some View {
        if NoteSummaryModel.isAvailable, Self.summarizableTypes.contains(note.type), !vm.needsProtectedSession {
            Section(String(localized: "Apple Intelligence", comment: "Note overflow: section header for on-device AI actions")) {
                Button { summarizeFinishingEdit(vm: vm, note: note) } label: {
                    Label(String(localized: "Summarize", comment: "Note overflow: Apple Intelligence summary"), systemImage: "apple.intelligence")
                }
                Button { runNoteAIFinishingEdit(.todos, vm: vm, note: note) } label: {
                    Label(String(localized: "Find To-dos", comment: "Note overflow: Apple Intelligence extracts action items"), systemImage: "checklist")
                }
                Button { runNoteAIFinishingEdit(.title, vm: vm, note: note) } label: {
                    Label(String(localized: "Suggest Title", comment: "Note overflow: Apple Intelligence title"), systemImage: "character.cursor.ibeam")
                }
            }
        }
        // A short menu: the quick things you do with the note itself. Editing, moving,
        // exporting and the rest stay in the ••• menu.
        Section {
            Button {
                vm.editedTitle = note.title
                vm.editingTitle = true
            } label: {
                Label(String(localized: "Rename", comment: "Note overflow menu"), systemImage: "pencil")
            }
            Button {
                toggleFavorite(note: note, isFavorite: favoriteNoteIds.contains(note.noteId))
            } label: {
                if favoriteNoteIds.contains(note.noteId) {
                    Label(String(localized: "Remove from Favorites", comment: "Note overflow"), systemImage: "star.slash")
                } else {
                    Label(String(localized: "Add to Favorites", comment: "Note overflow"), systemImage: "star")
                }
            }
        }
        Section {
            Button {
                UIPasteboard.general.url = NoteLink.url(for: note.noteId)
            } label: {
                Label(String(localized: "Copy Link", comment: "Note list: copy a triquidnotes:// link"), systemImage: "link")
            }
            if !(note.isProtected && vm.needsProtectedSession) {
                Button {
                    scheduleNoteDetailShareSheet(items: noteShareItems(note: note, vm: vm))
                } label: {
                    Label(String(localized: "Share…", comment: "Note overflow: system share sheet"), systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    @ViewBuilder
    private func childNoteMenu(_ child: ChildNoteSummary, vm: NoteDetailViewModel) -> some View {
        Button {
            navigateToNoteId = child.noteId
        } label: {
            Label(String(localized: "Open Note", comment: "Note list chip: open the folder note itself"), systemImage: "doc.text")
        }
        Button {
            UIPasteboard.general.url = NoteLink.url(for: child.noteId)
        } label: {
            Label(String(localized: "Copy Link", comment: "Note list: copy a triquidnotes:// link"), systemImage: "link")
        }
        Button {
            Task { await toggleChildFavorite(child) }
        } label: {
            if favoriteNoteIds.contains(child.noteId) {
                Label(String(localized: "Remove from Favorites", comment: "Note overflow"), systemImage: "star.slash")
            } else {
                Label(String(localized: "Add to Favorites", comment: "Note overflow"), systemImage: "star")
            }
        }
        .disabled(!appState.isOnline)
        Button {
            childMoveRequest = NoteMoveRequest(noteId: child.noteId, title: child.title)
        } label: {
            Label(String(localized: "Move", comment: "Note overflow: move under another parent"), systemImage: "arrow.forward.folder")
        }
        Divider()
        Button {
            childAppearanceTarget = NoteAppearanceTarget(noteId: child.noteId, title: child.title, iconClass: child.iconClass, colorLabel: nil, initialTab: .color)
        } label: {
            Label(String(localized: "Color…", comment: "Note list: pick the note's Trilium color"), systemImage: "paintpalette")
        }
        .disabled(!appState.isOnline)
        Button {
            childAppearanceTarget = NoteAppearanceTarget(noteId: child.noteId, title: child.title, iconClass: child.iconClass, colorLabel: nil, initialTab: .icon)
        } label: {
            Label(String(localized: "Icon…", comment: "Note list: pick the note's Trilium icon"), systemImage: "face.smiling")
        }
        .disabled(!appState.isOnline)
        Divider()
        Button(role: .destructive) {
            eraseChildOnDelete = false
            childPendingDelete = child
        } label: {
            Label(String(localized: "Delete Note", comment: "Note overflow"), systemImage: "trash")
        }
    }

    private func toggleChildFavorite(_ child: ChildNoteSummary) async {
        let isFavorite = favoriteNoteIds.contains(child.noteId)
        do {
            try await FavoriteBookmarks.setFavorite(!isFavorite, noteId: child.noteId, title: child.title, noteType: child.type.rawValue, appState: appState)
            if isFavorite { favoriteNoteIds.remove(child.noteId) } else { favoriteNoteIds.insert(child.noteId) }
        } catch {
            childActionError = APIError.from(error).localizedDescription
        }
    }

    private func deleteChild(_ child: ChildNoteSummary, erase: Bool, vm: NoteDetailViewModel) async {
        let tree = TreeViewModel(appState: appState, parentNoteId: vm.note?.noteId ?? "root")
        if await tree.deleteNoteAndSubnotes(noteId: child.noteId, eraseNotes: erase, refreshTree: false) {
            await vm.loadChildNotes()
        } else if let error = tree.error {
            childActionError = error
        }
    }

    private func changeChild(vm: NoteDetailViewModel, _ change: () async throws -> Void) async {
        do {
            try await change()
            await vm.loadChildNotes()
        } catch {
            childActionError = APIError.from(error).localizedDescription
        }
    }

    private func noteOverflowLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
    }

    private func dismissNoteOverflow() {
        showNoteOverflowMenu = false
    }

    private func dismissNoteOverflowThen(_ work: @escaping () -> Void) {
        showNoteOverflowMenu = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            work()
        }
    }

    private func recordToolbarQuickAction(_ action: NoteDetailToolbarQuickAction) {
        lastToolbarQuickActionRaw = action.rawValue
    }

    private func toolbarQuickActionCandidates(preferred: NoteDetailToolbarQuickAction) -> [NoteDetailToolbarQuickAction] {
        [preferred] + NoteDetailToolbarQuickAction.allCases.filter { $0 != preferred }
    }

    private func firstAvailableToolbarQuickAction(vm: NoteDetailViewModel, note: NoteItem) -> NoteDetailToolbarQuickAction? {
        // Legacy "edit" / "rename" raw values no longer match a case → falls back to .noteDetails.
        let preferred = NoteDetailToolbarQuickAction(rawValue: lastToolbarQuickActionRaw) ?? .noteDetails
        let candidates: [NoteDetailToolbarQuickAction]
        if vm.isEditing {
            // Same slot as “New Child” in the menu: prefer cancel while editing.
            candidates = [.cancelEditing] + toolbarQuickActionCandidates(preferred: preferred).filter { $0 != .cancelEditing }
        } else {
            candidates = toolbarQuickActionCandidates(preferred: preferred)
        }
        for action in candidates where isToolbarQuickActionAvailable(action, vm: vm, note: note) {
            return action
        }
        return nil
    }

    private func isToolbarQuickActionAvailable(_ action: NoteDetailToolbarQuickAction, vm: NoteDetailViewModel, note: NoteItem) -> Bool {
        switch action {
        case .cancelEditing: return vm.isEditing
        case .newChild: return !vm.isEditing
        case .noteDetails: return true
        case .duplicate: return !note.isProtected || appState.protectedSessionActive
        case .findOnPage: return !vm.isEditing && note.type.supportsReadOnlyOnPageFind
        case .favorite: return appState.activeProfile != nil
        }
    }

    private func isToolbarQuickActionDisabled(_ action: NoteDetailToolbarQuickAction, vm: NoteDetailViewModel) -> Bool {
        switch action {
        case .duplicate: return vm.isSaving
        default: return false
        }
    }

    private func performToolbarQuickAction(_ action: NoteDetailToolbarQuickAction, vm: NoteDetailViewModel, note: NoteItem) {
        switch action {
        case .cancelEditing:
            cancelNoteEditing(vm: vm, note: note)
        case .newChild:
            vm.showCreateChild = true
        case .noteDetails:
            toggleNoteDetails(vm)
        case .duplicate:
            Task {
                if let dup = await vm.duplicateNote() {
                    navigateToNoteId = dup.noteId
                }
            }
        case .findOnPage:
            if findControl.isPresented {
                findControl.close()
            } else {
                findControl.isPresented = true
            }
        case .favorite:
            toggleFavorite(note: note, isFavorite: favoriteNoteIds.contains(note.noteId))
        }
    }

    @ViewBuilder
    private func toolbarQuickActionLabel(_ action: NoteDetailToolbarQuickAction, vm: NoteDetailViewModel, note: NoteItem) -> some View {
        switch action {
        case .cancelEditing:
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
        case .newChild:
            Image(systemName: "plus")
        case .noteDetails:
            Image(systemName: noteDetailsShown(vm) ? "info.circle.fill" : "info.circle")
        case .duplicate:
            Image(systemName: "doc.on.doc")
        case .findOnPage:
            Image(systemName: findControl.isPresented ? "magnifyingglass.circle.fill" : "magnifyingglass")
        case .favorite:
            // A favorite shows a filled yellow star; tapping it removes the favorite.
            if favoriteNoteIds.contains(note.noteId) {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
            } else {
                Image(systemName: "star")
            }
        }
    }

    private func toolbarQuickActionAccessibilityLabel(_ action: NoteDetailToolbarQuickAction, vm: NoteDetailViewModel, note: NoteItem) -> String {
        switch action {
        case .cancelEditing:
            return String(localized: "Cancel editing", comment: "Toolbar quick action while editing note")
        case .newChild:
            return String(localized: "New child note", comment: "Toolbar repeat last action")
        case .noteDetails:
            return noteDetailsShown(vm)
                ? String(localized: "Hide note details", comment: "Toolbar repeat last action")
                : String(localized: "Show note details", comment: "Toolbar repeat last action")
        case .duplicate:
            return String(localized: "Duplicate note", comment: "Toolbar repeat last action")
        case .findOnPage:
            return findControl.isPresented
                ? String(localized: "Hide find bar", comment: "Toolbar repeat last action")
                : String(localized: "Find on page", comment: "Toolbar repeat last action")
        case .favorite:
            return favoriteNoteIds.contains(note.noteId)
                ? String(localized: "Remove from favorites", comment: "Toolbar repeat last action")
                : String(localized: "Add to favorites", comment: "Toolbar repeat last action")
        }
    }

    private func loadFavoriteNoteIds() {
        guard let profileId = appState.activeProfile?.id else {
            favoriteNoteIds = []
            return
        }
        do {
            let favs = try PersistenceManager.shared.fetchFavorites(serverProfileId: profileId)
            favoriteNoteIds = Set(favs.map(\.noteId))
        } catch {
            Log.persistence.error("Failed to load favorite IDs: \(error.localizedDescription)")
        }
    }

    private func scheduleNoteDetailShareURLSheet(url: URL) {
        scheduleNoteDetailShareSheet(items: [url])
    }

    private func scheduleNoteDetailShareSheet(items: [Any]) {
        TrinoteDeferredSystemShareSheet.schedulePresentation {
            noteDetailShareSheetItem = NoteDetailShareSheetItem(items: items)
        }
    }

    /// What the system share sheet gets: a file or image note as its file, any other note as its
    /// title and text.
    private func noteShareItems(note: NoteItem, vm: NoteDetailViewModel) -> [Any] {
        if note.type == .file || note.type == .image, let data = vm.content, !data.isEmpty {
            let name = note.title.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name.isEmpty ? "Note" : name)
            guard (try? data.write(to: url)) != nil else { return [] }
            return [url]
        }
        guard let html = vm.contentString, !html.isEmpty else { return note.title.isEmpty ? [] : [note.title] }
        let text = NotePlainText.fromHTML(html)
        return [note.title.isEmpty ? text : note.title + "\n\n" + text]
    }

    /// Favorites are the `#bookmarked` label, so this writes to the server.
    private func toggleFavorite(note: NoteItem, isFavorite: Bool) {
        Task {
            do {
                try await FavoriteBookmarks.setFavorite(
                    !isFavorite, noteId: note.noteId, title: note.title, noteType: note.type.rawValue, appState: appState
                )
                loadFavoriteNoteIds()
            } catch {
                Log.persistence.error("Failed to toggle favorite: \(error.localizedDescription)")
                favoriteError = error.localizedDescription
            }
        }
    }
}

// MARK: - Create Child Sheet

/// Note types offered when creating a child note. Spreadsheet / Kanban / Presentation are gated by server version.
struct NewNoteTypePicker: View {
    @Binding var selection: NoteType
    var supportsSpreadsheet: Bool
    var supportsKanban: Bool = true
    var supportsPresentation: Bool = true
    /// When `false`, the picker stays on Text and cannot be changed (share-import flow).
    var isEnabled: Bool = true

    var body: some View {
        Picker(String(localized: "Type", comment: "New note type"), selection: $selection) {
            Text(String(localized: "Text", comment: "Note type")).tag(NoteType.text)
            Text(String(localized: "Code", comment: "Note type")).tag(NoteType.code)
            Text(String(localized: "Markdown", comment: "Note type: code note with Markdown MIME")).tag(NoteType.markdown)
            Text(String(localized: "Canvas", comment: "Note type")).tag(NoteType.canvas)
            Text(String(localized: "Mermaid", comment: "Note type")).tag(NoteType.mermaid)
            Text(String(localized: "Mind Map", comment: "Note type")).tag(NoteType.mindMap)
            if supportsSpreadsheet {
                Text(String(localized: "Spreadsheet", comment: "Note type")).tag(NoteType.spreadsheet)
            }
            Text(String(localized: "Geo Map", comment: "Note type")).tag(NoteType.geoMap)
            Text(String(localized: "Calendar", comment: "Note type: Trilium journal / calendar root")).tag(NoteType.calendar)
            if supportsKanban {
                Text(String(localized: "Kanban Board", comment: "Note type")).tag(NoteType.kanban)
            }
            if supportsPresentation {
                Text(String(localized: "Presentation", comment: "Note type")).tag(NoteType.presentation)
            }
        }
        .disabled(!isEnabled)
        .onChange(of: supportsSpreadsheet) { _, supported in
            if !supported, selection == .spreadsheet {
                selection = .text
            }
        }
        .onChange(of: supportsKanban) { _, supported in
            if !supported, selection == .kanban {
                selection = .text
            }
        }
        .onChange(of: supportsPresentation) { _, supported in
            if !supported, selection == .presentation {
                selection = .text
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                selection = .text
            }
        }
    }
}

struct CreateChildNoteSheet: View {
    @Bindable var viewModel: NoteDetailViewModel
    var onNoteCreated: ((String, String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
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
                    String(localized: "Note Title (leave blank for default)", comment: "New child sheet"),
                    text: $viewModel.newNoteTitle
                )
                    .textInputAutocapitalization(.sentences)

                if templateChoice.template == nil {
                    NewNoteTypePicker(
                        selection: $viewModel.newNoteType,
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
                    Button(String(localized: "Cancel", comment: "New child sheet")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Create", comment: "New child sheet")) {
                        Task { await createAndDismiss() }
                    }
                    .disabled(viewModel.isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func createAndDismiss() async {
        let title = NoteCreationTitle.resolved(from: viewModel.newNoteTitle)
        let noteId: String?
        if let template = templateChoice.template {
            noteId = await viewModel.createChildNote(
                fromTemplate: template,
                parentNoteId: templateChoice.parentNoteId(defaultParentNoteId: viewModel.noteId)
            )
            let clones = templateChoice.cloneParentNoteIds
            if let noteId, !clones.isEmpty {
                Task { await NoteTemplates.cloneNewNote(noteId, into: clones, appState: appState) }
            }
        } else {
            noteId = await viewModel.createChildNote()
        }
        if let noteId {
            dismiss()
            onNoteCreated?(noteId, title)
        }
    }
}

private struct NoteOverflowSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Sizes the ⋯ actions sheet to its full content so rows are not clipped behind a short system menu.
private struct NoteOverflowSheetSizingModifier: ViewModifier {
    @State private var contentHeight: CGFloat = 740

    func body(content: Content) -> some View {
        let maxHeight = AppDelegate.foregroundWindowFrameInScreen.height * 0.92
        let detentHeight = min(max(contentHeight, 280), maxHeight)
        content
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: NoteOverflowSheetHeightKey.self, value: proxy.size.height)
                }
            }
            .onPreferenceChange(NoteOverflowSheetHeightKey.self) { measured in
                guard measured > 100 else { return }
                let padded = measured + 20
                if abs(contentHeight - padded) > 1 {
                    contentHeight = padded
                }
            }
            .presentationDetents([.height(detentHeight)])
            .presentationDragIndicator(.visible)
    }
}

/// Files dropped on a note in the iPad layout become attachments, through the usual name prompt. Notes dragged
/// from the tree, and text or links from other apps, aren't files and are left alone.
private struct NoteFileDropDelegate: DropDelegate {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    /// Data, MIME type, file name.
    let onFile: @MainActor @Sendable (Data, String, String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard isEnabled,
              !info.hasItemsConforming(to: [TreeNoteDrag.type]),
              let provider = info.itemProviders(for: [.data]).first
        else { return false }
        return provider.suggestedName != nil || !info.hasItemsConforming(to: [.text, .url])
    }

    func dropEntered(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.15)) { isTargeted = true }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.15)) { isTargeted = false }
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let provider = info.itemProviders(for: [.data]).first else { return false }
        let typeIdentifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true }
            ?? UTType.data.identifier
        let onFile = onFile
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
            // The file is only there during this callback.
            guard let url, let data = try? Data(contentsOf: url) else { return }
            let type = UTType(typeIdentifier)
            let filename = url.pathExtension.isEmpty
                ? url.lastPathComponent + (type?.preferredFilenameExtension.map { ".\($0)" } ?? "")
                : url.lastPathComponent
            let mime = type?.preferredMIMEType
                ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            Task { @MainActor in onFile(data, mime, filename) }
        }
        return true
    }
}

/// The ⋯ actions as a popover: a fixed width, scrolling when the list is taller than the window allows.
private struct NoteOverflowPopoverSizingModifier: ViewModifier {
    @State private var contentHeight: CGFloat = 600
    /// The software keyboard's height while it is up; the popover fits in the space above it and
    /// scrolls, so every item stays reachable with the keyboard showing.
    @State private var keyboardHeight: CGFloat = KeyboardFrameTracker.shared.height
    private static let width: CGFloat = 320

    func body(content: Content) -> some View {
        let window = AppDelegate.foregroundWindowFrameInScreen.height
        let aboveKeyboard = window - keyboardHeight - 120
        let maxHeight = max(220, min(window * 0.8, aboveKeyboard))
        ScrollView {
            content
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: NoteOverflowSheetHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .onPreferenceChange(NoteOverflowSheetHeightKey.self) { measured in
            guard measured > 100, abs(contentHeight - measured) > 1 else { return }
            contentHeight = measured
        }
        .frame(width: Self.width, height: min(contentHeight, maxHeight))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screen = UIScreen.main.bounds.height
            keyboardHeight = frame.minY >= screen ? 0 : frame.height
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
    }
}

// Make String Identifiable for navigationDestination
extension String: @retroactive Identifiable {
    public var id: String { self }
}

/// Editing is task-oriented (redesign §5): where toolbars run vertically (iPhone Duo), the tab bar
/// gives way to the note's toolbar items rather than the other way round. Needs iOS 27.1.
private struct EditingToolbarCompression: ViewModifier {
    let isEditing: Bool

    func body(content: Content) -> some View {
        // A vertical toolbar rail exists only on iPhone Duo; Mac Catalyst has no such API.
        #if targetEnvironment(macCatalyst)
        content
        #else
        if #available(iOS 27.1, *) {
            content.toolbarVerticalCompressionBehavior(isEditing ? .prefersToolbarItems : .automatic)
        } else {
            content
        }
        #endif
    }
}

/// The geo map's place search sheet, opened with the area the map showed.
private struct GeoMapSearchRequest: Identifiable {
    let id = UUID()
    let viewport: [Double]?
}

private extension View {
    /// `.inspector` only where the note panel can be shown; see the call site.
    @ViewBuilder
    func notePanelInspector<Panel: View>(
        enabled: Bool,
        isPresented: Binding<Bool>,
        @ViewBuilder content: () -> Panel
    ) -> some View {
        if enabled {
            inspector(isPresented: isPresented, content: content)
        } else {
            self
        }
    }

    /// Cancel Editing after an autosave: confirms before putting back the note from before editing.
    func cancelEditingConfirmation(isPresented: Binding<Bool>, onDiscard: @escaping () -> Void) -> some View {
        alert(
            String(localized: "Discard Changes?", comment: "Alert title: Cancel Editing after Autosave already saved some edits"),
            isPresented: isPresented
        ) {
            Button(
                String(localized: "Discard Changes", comment: "Alert button: put back the note from before editing"),
                role: .destructive,
                action: onDiscard
            )
            Button(String(localized: "Keep Editing", comment: "Alert button: stay in the note editor"), role: .cancel) {}
        } message: {
            Text(String(
                localized: "Autosave has already saved some of your edits. Discarding puts the note back the way it was when you started editing.",
                comment: "Alert message: Cancel Editing after Autosave already saved some edits"
            ))
        }
    }
}

/// Read-only scroll position bookkeeping for `NoteDetailView`, kept out of SwiftUI state (see `scrollTracking`).
@MainActor
final class ReadOnlyScrollTracking {
    /// Scroll fraction (0–1) of the read-only ScrollView, used to restore position in the editor.
    var fraction: CGFloat
    /// The same position in points, with the scroll view width it was read at.
    var offset: ReadScrollOffset?
    /// Last `contentOffset.y` seen, for the floating Edit chip's scroll direction.
    var lastContentOffsetY: CGFloat = 0

    init(fraction: CGFloat = 0, offset: ReadScrollOffset? = nil) {
        self.fraction = fraction
        self.offset = offset
    }
}

/// A restore's position in points and the fraction it was saved with (see `readOnlyScrollOffsetPendingRestore`).
struct PendingReadScrollOffset {
    var fraction: CGFloat
    var offset: ReadScrollOffset
}

/// The software keyboard's height, kept from app start so a popover that opens while the keyboard is
/// already up knows how much room is left.
@MainActor
final class KeyboardFrameTracker {
    static let shared = KeyboardFrameTracker()
    private(set) var height: CGFloat = 0
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated {
                guard let frame else { return }
                KeyboardFrameTracker.shared.height = frame.minY >= UIScreen.main.bounds.height ? 0 : frame.height
            }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeyboardFrameTracker.shared.height = 0 }
        })
    }
}
