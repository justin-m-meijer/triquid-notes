import PhotosUI
import SwiftUI

/// A parent note Quick capture can save into.
struct CaptureDestination: Codable, Hashable, Sendable {
    let noteId: String
    let title: String
}

/// Where Quick capture saved recently, and the inbox note Trilium resolved last, per server.
enum CaptureDestinations {
    private static func recentKey(_ profileId: String) -> String { "quickCaptureRecentParents." + profileId }
    private static func inboxKey(_ profileId: String) -> String { "quickCaptureInbox." + profileId }

    static func recent(profileId: String) -> [CaptureDestination] {
        guard let data = UserDefaults.standard.data(forKey: recentKey(profileId)) else { return [] }
        return (try? JSONDecoder().decode([CaptureDestination].self, from: data)) ?? []
    }

    static func remember(_ destination: CaptureDestination, profileId: String) {
        var list = recent(profileId: profileId).filter { $0.noteId != destination.noteId }
        list.insert(destination, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(3))) {
            UserDefaults.standard.set(data, forKey: recentKey(profileId))
        }
    }

    private static func defaultKey(_ profileId: String) -> String { "quickCaptureDefault." + profileId }

    /// Settings › Quick capture saves to. `nil` means Trilium's inbox.
    static func defaultDestination(profileId: String) -> CaptureDestination? {
        guard let data = UserDefaults.standard.data(forKey: defaultKey(profileId)) else { return nil }
        return try? JSONDecoder().decode(CaptureDestination.self, from: data)
    }

    static func setDefaultDestination(_ destination: CaptureDestination?, profileId: String) {
        if let destination, let data = try? JSONEncoder().encode(destination) {
            UserDefaults.standard.set(data, forKey: defaultKey(profileId))
        } else {
            UserDefaults.standard.removeObject(forKey: defaultKey(profileId))
        }
    }

    /// The person's inbox note. A top-level note named like "Inbox" (for example "00-Inbox") is the
    /// inbox the tree shows, so it wins; otherwise Trilium's answer, which is the `#inbox` note or,
    /// without one, today's journal note.
    @MainActor
    static func resolveInboxNote(client: any TriliumClientProtocol, profileId: String, day: String) async throws -> NoteIdTitle {
        let topLevel = (try? PersistenceManager.shared.fetchCachedChildren(parentNoteId: TriliumTreeConstants.rootNoteId, serverProfileId: profileId)) ?? []
        let named = topLevel.map(\.1).filter { $0.title.localizedCaseInsensitiveContains("inbox") }
        if let best = named.first(where: { $0.title.caseInsensitiveCompare("inbox") == .orderedSame }) ?? named.first {
            return NoteIdTitle(noteId: best.noteId, title: best.title, isProtected: best.isProtected)
        }
        return try await client.getInboxNote(onISODay: day)
    }

    static func cachedInbox(profileId: String) -> CaptureDestination? {
        guard let data = UserDefaults.standard.data(forKey: inboxKey(profileId)) else { return nil }
        return try? JSONDecoder().decode(CaptureDestination.self, from: data)
    }

    static func rememberInbox(_ destination: CaptureDestination, profileId: String) {
        if let data = try? JSONEncoder().encode(destination) {
            UserDefaults.standard.set(data, forKey: inboxKey(profileId))
        }
    }
}

/// Quick capture (redesign screen 3): a glass sheet to jot a note into the inbox or a recent parent,
/// with a photo, a checklist, labels and a page clipped from a copied link. Works offline: the note
/// is created locally and uploaded with the next sync.
struct QuickCaptureSheet: View {
    /// Saves what was typed and opens the new note in the full editor (note id, title).
    var onOpenInEditor: ((String, String) -> Void)?
    /// A file shared to the app (a PDF from the share sheet, a scan): saved as the note's attachment.
    var sharedFile: SharedImportPackage? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private enum Destination: Hashable {
        case inbox
        case note(CaptureDestination)
    }

    @State private var destination: Destination = .inbox
    /// Text is Quick capture itself; other types are created empty and open in their editor.
    @State private var noteType: NoteType = .text
    @State private var recentDestinations: [CaptureDestination] = []
    @State private var title = ""
    @State private var noteBody = ""
    @State private var images: [Data] = []
    @State private var file: SharedImportPackage?
    @State private var labels: [String] = []
    @State private var labelSuggestions: [LabelSuggestion] = []
    @State private var isSuggestingLabels = false
    @State private var clip: PageClip?
    @State private var isClipping = false
    @State private var clipboardHasLink = false
    /// A copied link whose page showed a cookie wall: opened so the user can accept and clip.
    @State private var blockedClipURL: URL?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showsParentPicker = false
    @State private var showsLabelPrompt = false
    @State private var labelText = ""
    @State private var showsCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsPhotoLibrary = false
    @FocusState private var focusedField: Field?

    private enum Field { case title, body }

    var body: some View {
        NavigationStack {
            // The text fills the sheet; the buttons ride on the keyboard, so no space is left over.
            VStack(alignment: .leading, spacing: 16) {
                // One row: the type first, then where it is saved (TestFlight feedback).
                // A shared file goes into a text note, so the type is not offered.
                typeAndDestinationRow
                if noteType == .text {
                    fieldsCard
                } else {
                    typedTitleCard
                }
                if noteType == .text, !images.isEmpty || !labels.isEmpty || clip != nil || file != nil {
                    attachmentsRow
                }
                if noteType == .text, LabelSuggester.isAvailable, hasContent {
                    suggestionRow
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .safeAreaInset(edge: .bottom, spacing: 12) {
                VStack(spacing: 8) {
                    if noteType == .text {
                        actionButtons
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .background(Color.trinoteGround.opacity(0.4))
            .navigationTitle(String(localized: "New note", comment: "Quick capture title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                // In the bar rather than under the buttons, where the keyboard hid it.
                if noteType == .text, onOpenInEditor != nil {
                    ToolbarItem(placement: .primaryAction) {
                        openInEditorButton
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving, file != nil {
                        // Uploading the shared file.
                        ProgressView()
                    } else {
                        Button(role: .confirm) { Task { await save() } }
                            .disabled(isSaving || (noteType == .text && !hasContent))
                    }
                }
            }
        }
        // On iPad a form sheet above the keyboard left one line to type in; a page sheet is taller.
        .modifier(TallSheetOnPad())
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            if let profileId = appState.activeProfile?.id {
                // A deleted note can't take new notes: they would wait for a parent that's gone.
                let exists = { (d: CaptureDestination) in
                    (try? PersistenceManager.shared.fetchCachedNote(id: d.noteId, serverProfileId: profileId)) != nil
                }
                recentDestinations = CaptureDestinations.recent(profileId: profileId).filter(exists)
                if let preferred = CaptureDestinations.defaultDestination(profileId: profileId), exists(preferred) {
                    destination = .note(preferred)
                    if !recentDestinations.contains(preferred) { recentDestinations.insert(preferred, at: 0) }
                }
            }
            refreshClipboardLink()
            if let sharedFile, file == nil {
                file = sharedFile
                noteType = .text
                if title.isEmpty { title = Self.title(forFile: sharedFile.payload.filename) }
                if noteBody.isEmpty, let text = sharedFile.payload.bodyText { noteBody = text }
            }
            focusedField = .body
        }
        .sheet(isPresented: $showsParentPicker) {
            ParentPickerSheet(
                navigationTitle: String(localized: "Save to", comment: "Quick capture: destination section"),
                instruction: String(localized: "Choose where to save the note. Use the tree to open folders, then tap a note to select it.", comment: "Quick capture: parent picker instruction"),
                topLevelButtonTitle: String(localized: "Top level (under Notes)", comment: "Move note under root"),
                onPick: { noteId, pickedTitle, _ in
                    let picked = CaptureDestination(noteId: noteId, title: pickedTitle)
                    destination = .note(picked)
                    if !recentDestinations.contains(picked) {
                        recentDestinations.insert(picked, at: 0)
                    }
                    showsParentPicker = false
                }
            )
            .environment(appState)
        }
        .fullScreenCover(isPresented: $showsCamera) {
            PhotoCaptureView(
                onCapture: { image in
                    showsCamera = false
                    if let data = image.normalizedToUpOrientation().jpegData(compressionQuality: 0.85) {
                        images.append(data)
                    }
                },
                onCancel: { showsCamera = false }
            )
            .ignoresSafeArea()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in refreshClipboardLink() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refreshClipboardLink() }
        .sheet(isPresented: Binding(get: { blockedClipURL != nil }, set: { if !$0 { blockedClipURL = nil } })) {
            if let blockedClipURL {
                ClipBrowserSheet(url: blockedClipURL) { clipped in
                    clip = clipped
                    summarizeClip(clipped)
                    if title.trimmingCharacters(in: .whitespaces).isEmpty { title = clipped.title }
                }
            }
        }
        .photosPicker(isPresented: $showsPhotoLibrary, selection: $photoItems, maxSelectionCount: 5, matching: .images)
        .onChange(of: photoItems) { _, items in
            Task { await loadPhotos(items) }
        }
        .alert(String(localized: "Add Label", comment: "Add label prompt title"), isPresented: $showsLabelPrompt) {
            TextField(String(localized: "name or name=value", comment: "Add label prompt placeholder"), text: $labelText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(String(localized: "Cancel", comment: "Alert dismiss"), role: .cancel) {}
            Button(String(localized: "Add", comment: "Add label prompt confirm")) { addLabel() }
        }
        .alert(
            String(localized: "Note Not Saved", comment: "Quick capture error title"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
            message: { Text(errorMessage ?? "") }
        )
    }

    private var hasContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !images.isEmpty
            || clip != nil
            || file != nil
    }

    // MARK: - Sections

    private var typeAndDestinationRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if file == nil {
                    typeMenu
                    Divider().frame(height: 22)
                }
                destinationChipsRow
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Save to", comment: "Quick capture: destination section"))
    }

    @ViewBuilder
    private var destinationChipsRow: some View {
        chip(String(localized: "Inbox", comment: "Favorites: fixed entry for Trilium's inbox"), systemImage: "tray", isOn: destination == .inbox) {
            destination = .inbox
        }
        ForEach(recentDestinations.prefix(3), id: \.self) { recent in
            chip(recent.title, systemImage: nil, isOn: destination == .note(recent)) {
                destination = .note(recent)
            }
        }
        chip(String(localized: "Other…", comment: "Quick capture: choose another parent"), systemImage: nil, isOn: false) {
            showsParentPicker = true
        }
        .accessibilityLabel(String(localized: "Choose another parent note", comment: "Quick capture accessibility"))
    }

    private func chip(_ title: String, systemImage: String?, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 15, weight: isOn ? .semibold : .regular))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .foregroundStyle(isOn ? AnyShapeStyle(.trinoteOnAccent) : AnyShapeStyle(Color.trinoteTextPrimary))
            .background {
                if isOn {
                    Capsule().fill(.tint)
                } else {
                    Capsule().fill(.clear).glassEffect(.regular, in: .capsule)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// The note type, as in Trilium's New note: Text is Quick capture, the rest open in their editor.
    private var typeMenu: some View {
            Menu {
                Picker(String(localized: "Type", comment: "New note type"), selection: $noteType) {
                    ForEach(availableTypes, id: \.self) { type in
                        Label(type.displayName, systemImage: type.iconName).tag(type)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: noteType.iconName)
                    Text(noteType.displayName)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .accessibilityLabel(String(localized: "Note type", comment: "Quick capture: note type menu"))
    }

    private var availableTypes: [NoteType] {
        let info = appState.serverAppInfo
        return [.text, .code, .markdown, .canvas, .mermaid, .mindMap, .spreadsheet, .geoMap, .calendar, .kanban, .presentation].filter { type in
            switch type {
            case .spreadsheet: TriliumServerCompatibility.supportsSpreadsheetNotes(info)
            case .kanban: TriliumServerCompatibility.supportsKanbanNotes(info)
            case .presentation: TriliumServerCompatibility.supportsPresentationNotes(info)
            default: true
            }
        }
    }

    /// Other types start empty, with only a title here; Done opens them in their own editor.
    private var typedTitleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(String(localized: "Note Title (leave blank for default)", comment: "New note from tree"), text: $title)
                .font(.system(size: 20, weight: .semibold))
                .focused($focusedField, equals: .title)
                .submitLabel(.done)
                .onSubmit { Task { await save() } }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.trinoteCard, in: .rect(cornerRadius: 20))
            Text(String(localized: "Done creates the note and opens it in its editor.", comment: "Quick capture: typed note hint"))
                .font(.footnote)
                .foregroundStyle(Color.trinoteTextSecondary)
                .padding(.horizontal, 4)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var fieldsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(String(localized: "Title", comment: "Note title field"), text: $title)
                .font(.system(size: 20, weight: .semibold))
                .focused($focusedField, equals: .title)
                .submitLabel(.next)
                .onSubmit { focusedField = .body }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            Divider().overlay(Color.trinoteSeparator)
            TextEditor(text: $noteBody)
                .font(.system(size: 17))
                .scrollContentBackground(.hidden)
                .focused($focusedField, equals: .body)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .frame(minHeight: 120, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if noteBody.isEmpty {
                        Text(String(localized: "Start typing…", comment: "Quick capture body placeholder"))
                            .font(.system(size: 17))
                            .foregroundStyle(Color.trinoteTextTertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
        }
        .frame(maxHeight: .infinity)
        .background(Color.trinoteCard, in: .rect(cornerRadius: 20))
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let file {
                    fileChip(file)
                }
                ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(.rect(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                removeButton { images.remove(at: index) }
                            }
                    }
                }
                ForEach(labels, id: \.self) { label in
                    TagChip(text: NoteLabelVisibility.friendlyText(raw: label), kind: .applied)
                        .overlay(alignment: .topTrailing) {
                            Button { withAnimation(.snappy) { labels.removeAll { $0 == label } } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(Color.trinoteTextSecondary)
                                    .background(Circle().fill(Color.trinoteCard))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                            .accessibilityLabel(String(localized: "Remove Label", comment: "Label chip menu"))
                        }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                if let clip {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text(clip.title.isEmpty ? (clip.url.host() ?? clip.url.absoluteString) : clip.title).lineLimit(1)
                        if clip.wordCount > 0 {
                            Text(String(localized: "\(clip.wordCount) words", comment: "Quick capture: size of the clipped article"))
                                .foregroundStyle(Color.trinoteTextSecondary)
                                .fixedSize()
                        }
                        Button { self.clip = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "Remove clipped page", comment: "Quick capture"))
                    }
                    .font(.system(size: 14))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.trinoteCard, in: .capsule)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// The shared file: its icon, name and size, uploaded as the note's attachment on save.
    private func fileChip(_ file: SharedImportPackage) -> some View {
        let name = file.payload.filename ?? String(localized: "Attachment", comment: "Quick capture: shared file without a name")
        let isPDF = file.payload.mimeType == "application/pdf" || name.lowercased().hasSuffix(".pdf")
        return HStack(spacing: 8) {
            Image(systemName: isPDF ? "doc.richtext" : "doc")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                if let size = file.binaryData?.count {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(Color.trinoteTextSecondary)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 18)
        .frame(height: 56)
        .background(Color.trinoteCard, in: .rect(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            removeButton { withAnimation(.snappy) { self.file = nil } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Attachment: \(name)", comment: "Quick capture: shared file chip"))
    }

    /// "Invoice 2026.pdf" → "Invoice 2026".
    private static func title(forFile filename: String?) -> String {
        guard let filename, !filename.isEmpty else { return "" }
        let base = (filename as NSString).deletingPathExtension
        return base.isEmpty ? filename : base
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.6))
        }
        .buttonStyle(.plain)
        .offset(x: 4, y: -4)
        .accessibilityLabel(String(localized: "Remove photo", comment: "Quick capture"))
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Menu {
                if QuickCapture.canTakePhoto {
                    Button { showsCamera = true } label: {
                        Label(String(localized: "Take Photo", comment: "Quick capture photo menu"), systemImage: "camera")
                    }
                }
                Button { showsPhotoLibrary = true } label: {
                    Label(String(localized: "Choose from Library", comment: "Quick capture photo menu"), systemImage: "photo.on.rectangle")
                }
            } label: {
                Label(String(localized: "Photo", comment: "Welcome screen: take a photo into a new note"), systemImage: "camera")
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.glass)
            .accessibilityLabel(String(localized: "Add photo", comment: "Quick capture"))

            Button {
                addChecklistItem()
            } label: {
                Label(String(localized: "Checklist", comment: "Format bar"), systemImage: "checklist")
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.glass)

            Button {
                labelText = ""
                showsLabelPrompt = true
            } label: {
                Label(String(localized: "Label", comment: "Quick capture: add a label"), systemImage: "number")
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.glass)

            // Clips the page of a copied link into the note (TestFlight feedback: a button beside
            // the others instead of a card). Reading the clipboard only happens on tap.
            Button {
                Task { await clipLinkFromClipboard() }
            } label: {
                Group {
                    if isClipping {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(String(localized: "Clipboard", comment: "Quick capture: clip the page of a copied link"), systemImage: "doc.on.clipboard")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.glass)
            // Needs the internet, not the server: works on a device-only notebook too.
            .disabled(!clipboardHasLink || clip != nil || isClipping || !appState.networkMonitor.isConnected)
            .accessibilityHint(String(localized: "Adds the page of the copied link to the note", comment: "Quick capture: clipboard button hint"))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .font(.system(size: 14))
        .controlSize(.small)
        .foregroundStyle(Color.trinoteTextPrimary)
    }

    /// Quick capture is for jotting; a regular note is one tap away in the full editor.
    private var openInEditorButton: some View {
        Button {
            Task { await save(openInEditor: true) }
        } label: {
            Label(String(localized: "Open in full editor", comment: "Quick capture: create the note and open it in the editor"), systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .disabled(isSaving)
    }

    /// Apple Intelligence label suggestions for what was typed; tapping one adds it.
    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if labelSuggestions.isEmpty {
                    Button {
                        Task { await suggestLabels() }
                    } label: {
                        HStack(spacing: 4) {
                            if isSuggestingLabels { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                            Text(String(localized: "Suggest labels", comment: "VoiceOver: suggest labels with Apple Intelligence"))
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .overlay(Capsule().strokeBorder(.tint.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSuggestingLabels)
                } else {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.trinoteTextTertiary)
                        .accessibilityHidden(true)
                    ForEach(labelSuggestions, id: \.self) { suggestion in
                        Button {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                                labelSuggestions.removeAll { $0 == suggestion }
                                let raw = suggestion.value.isEmpty ? suggestion.name : "\(suggestion.name)=\(suggestion.value)"
                                if !labels.contains(raw) { labels.append(raw) }
                            }
                        } label: {
                            TagChip(text: suggestion.friendly, kind: .suggested)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Add suggested label \(suggestion.friendly)", comment: "VoiceOver: add an Apple Intelligence label suggestion"))
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func suggestLabels() async {
        guard let profileId = appState.activeProfile?.id else { return }
        isSuggestingLabels = true
        defer { isSuggestingLabels = false }
        let current = labels.map { raw -> LabelSuggestion in
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            return LabelSuggestion(name: parts[0], value: parts.count > 1 ? parts[1] : "")
        }
        do {
            labelSuggestions = try await LabelSuggester.suggest(
                title: title,
                text: noteBody + (clip.map { "\n" + $0.paragraphs.joined(separator: "\n") } ?? ""),
                vocabulary: LabelSuggester.vocabulary(serverProfileId: profileId, context: PersistenceManager.shared.context),
                current: current
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Actions

    /// Starts a checklist line; lines starting with ☐ become a Trilium checklist when saved.
    private func addChecklistItem() {
        if noteBody.isEmpty || noteBody.hasSuffix("\n") {
            noteBody += QuickCaptureNoteBuilder.uncheckedPrefix
        } else {
            noteBody += "\n" + QuickCaptureNoteBuilder.uncheckedPrefix
        }
        focusedField = .body
    }

    private func addLabel() {
        var raw = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard !raw.isEmpty, !raw.contains(" "), !labels.contains(raw) else { return }
        labels.append(raw)
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data),
               let jpeg = image.jpegData(compressionQuality: 0.85) {
                images.append(jpeg)
            }
        }
        photoItems = []
    }

    /// Adds an Apple Intelligence summary above a clipped article once it is ready (on device;
    /// skipped when Apple Intelligence is off or the article is short).
    private func summarizeClip(_ clipped: PageClip) {
        Task {
            guard let summary = await NoteSummaryModel.clipSummary(title: clipped.title, plainText: clipped.plainText) else { return }
            if clip?.url == clipped.url { clip?.summary = summary }
        }
    }

    /// Neither `hasURLs` nor pattern detection reads the clipboard, so no paste prompt shows. The
    /// pattern also finds a link copied as plain text.
    private func refreshClipboardLink() {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasURLs {
            clipboardHasLink = true
            return
        }
        guard pasteboard.hasStrings else {
            clipboardHasLink = false
            return
        }
        // The async form: the callback one runs off the main thread, which the view's isolation traps.
        Task {
            let found = (try? await pasteboard.detectedPatterns(for: [\.probableWebURL]))?.contains(\.probableWebURL) ?? false
            clipboardHasLink = found
        }
    }

    /// Reading the clipboard shows the system paste prompt, so it only happens on tap.
    private func clipLinkFromClipboard() async {
        guard let url = UIPasteboard.general.url
                ?? UIPasteboard.general.string.flatMap({ URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
              url.scheme?.hasPrefix("http") == true else {
            errorMessage = String(localized: "The clipboard has no web link.", comment: "Quick capture clip error")
            return
        }
        isClipping = true
        defer { isClipping = false }
        do {
            let clipped = try await PageClipper.clip(url)
            if clipped.isBlocked {
                blockedClipURL = url
                return
            }
            clip = clipped
            summarizeClip(clipped)
            if title.trimmingCharacters(in: .whitespaces).isEmpty { title = clipped.title }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Nothing typed, picked or clipped yet: the note exists only to be written in the editor.
    private var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && images.isEmpty && file == nil && clip == nil && labels.isEmpty
    }

    /// Creates the note locally (offline-safe) and lets the sync upload it.
    private func save(openInEditor: Bool = false) async {
        guard let profileId = appState.activeProfile?.id else { return }
        isSaving = true
        defer { isSaving = false }

        let parent: CaptureDestination
        switch destination {
        case .note(let chosen):
            parent = chosen
        case .inbox:
            parent = await resolveInbox(profileId: profileId)
        }

        // "name=value" labels keep their value.
        var attributes = labels.map { label -> NoteCreationAttribute in
            let parts = label.split(separator: "=", maxSplits: 1).map(String.init)
            return NoteCreationAttribute(type: "label", name: parts[0], value: parts.count > 1 ? parts[1] : "")
        }
        // Like Tri Clipper: #clipUrl finds the note again for the same page.
        if let clip { attributes.append(NoteCreationAttribute(type: "label", name: "clipUrl", value: clip.url.absoluteString)) }
        if let file {
            // The file is uploaded as the note's attachment, so this waits for the server.
            let resolvedTitle = NoteCreationTitle.resolved(from: title)
            do {
                let noteId = try await appState.shareImport.saveSharedFile(
                    file,
                    parentNoteId: parent.noteId,
                    title: resolvedTitle,
                    bodyHTML: QuickCaptureNoteBuilder.html(body: noteBody, jpegImages: images, clip: clip),
                    attributes: attributes
                )
                if case .note(let chosen) = destination { CaptureDestinations.remember(chosen, profileId: profileId) }
                dismiss()
                if openInEditor { onOpenInEditor?(noteId, resolvedTitle) }
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        if noteType != .text {
            let resolvedTitle = NoteCreationTitle.resolved(from: title)
            do {
                let created = try PersistenceManager.shared.createOfflineChildNote(
                    parentNoteId: parent.noteId,
                    title: resolvedTitle,
                    noteType: noteType.triliumStorageType,
                    mime: noteType.creationMime,
                    initialContent: noteType.creationInitialContent,
                    serverProfileId: profileId,
                    initialAttributes: noteType.creationInitialAttributes
                )
                if case .note(let chosen) = destination { CaptureDestinations.remember(chosen, profileId: profileId) }
                appState.backgroundSyncPendingChanges()
                NotificationCenter.default.post(name: .trinoteTreeShouldRefresh, object: nil)
                if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { FreshEmptyNotes.register(created.noteId) }
                dismiss()
                onOpenInEditor?(created.noteId, resolvedTitle)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        let created: (noteId: String, branchId: String)
        let resolvedTitle = NoteCreationTitle.resolved(from: title)
        do {
            created = try PersistenceManager.shared.createOfflineChildNote(
                parentNoteId: parent.noteId,
                title: resolvedTitle,
                noteType: NoteType.text.triliumStorageType,
                mime: NoteType.text.creationMime,
                initialContent: QuickCaptureNoteBuilder.html(body: noteBody, jpegImages: images, clip: clip),
                serverProfileId: profileId,
                initialAttributes: attributes
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if case .note(let chosen) = destination {
            CaptureDestinations.remember(chosen, profileId: profileId)
        }
        appState.backgroundSyncPendingChanges()
        NotificationCenter.default.post(name: .trinoteTreeShouldRefresh, object: nil)
        dismiss()
        if openInEditor {
            if isBlank { FreshEmptyNotes.register(created.noteId) }
            onOpenInEditor?(created.noteId, resolvedTitle)
        }
    }

    /// Trilium's inbox for today when online (remembered for offline use), else the last one known,
    /// else the top level.
    private func resolveInbox(profileId: String) async -> CaptureDestination {
        if appState.isOnline, let client = appState.client {
            let day = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
            if let inbox = try? await CaptureDestinations.resolveInboxNote(client: client, profileId: profileId, day: day) {
                let destination = CaptureDestination(noteId: inbox.noteId, title: inbox.title)
                CaptureDestinations.rememberInbox(destination, profileId: profileId)
                return destination
            }
        }
        return CaptureDestinations.cachedInbox(profileId: profileId)
            ?? CaptureDestination(noteId: TriliumTreeConstants.rootNoteId, title: String(localized: "Notes", comment: "Root notebook screen title"))
    }
}

/// iPad only: iPhone sheets are already full height, and a page sheet there crowds the header.
private struct TallSheetOnPad: ViewModifier {
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.presentationSizing(.page)
        } else {
            content
        }
    }
}
