import Foundation
import Observation

enum ShareImportUIPhase: Equatable {
    case idle
    case needsSignIn
    case showExplanation
    case showParentPicker
    case showCreateNote
    case importing
    case failed(String)
}

struct PendingOpenSharedNote: Equatable, Sendable {
    let noteId: String
    let title: String
    /// When set, the editor inserts this attachment chip (same as toolbar file upload).
    let attachmentIdToInsert: String?
    let attachmentTitleToInsert: String?
    /// Always open shared imports in the editor so the user can review and Save.
    var startInEditMode: Bool { true }

    init(
        noteId: String,
        title: String,
        attachmentIdToInsert: String? = nil,
        attachmentTitleToInsert: String? = nil
    ) {
        self.noteId = noteId
        self.title = title
        self.attachmentIdToInsert = attachmentIdToInsert
        self.attachmentTitleToInsert = attachmentTitleToInsert
    }
}

private final class ShareImportNoteIdRemapCapture: @unchecked Sendable {
    var remapped: String?
}

/// Coordinates inbound share-sheet imports after the Share Extension writes the App Group.
@Observable
@MainActor
final class ShareImportCoordinator {
    private(set) var phase: ShareImportUIPhase = .idle
    private(set) var pendingPackage: SharedImportPackage?
    /// Parent chosen in `ParentPickerSheet` before the new-note sheet.
    private(set) var selectedParentNoteId: String?
    /// Suggested title for the create-note sheet (from filename / content).
    private(set) var suggestedNoteTitle: String = ""
    /// Set after a successful import so the Notes tab can open the new note.
    private(set) var pendingOpenNote: PendingOpenSharedNote?
    /// Where "Add to Inbox" puts the note; nil until worked out (see `refreshInboxDestination`).
    private(set) var inboxDestination: InboxDestination?
    /// While "Add to Inbox" finds (or makes) today's journal note.
    private(set) var isPlacingInInbox = false
    /// Bumped whenever UI-relevant share-import state changes (for reliable SwiftUI refresh).
    private(set) var activationToken: Int = 0
    /// A shared file (a PDF from the share sheet, a scan) waiting in Quick capture, which shows it
    /// as an attachment and saves it with `saveSharedFile`.
    private(set) var quickCaptureFile: SharedImportPackage?

    private weak var appState: AppState?
    private var retryTask: Task<Void, Never>?

    func configure(appState: AppState) {
        self.appState = appState
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme == SharedImportConstants.hostURLScheme,
              url.host == SharedImportConstants.hostURLHost
        else { return }
        bumpActivation()
        beginFromPendingStoreIfPossible()
        scheduleRetriesIfNeeded()
    }

    /// Call on foreground / after auth / after launch so a leftover App Group payload is still consumed.
    func checkForPendingPayload() {
        switch phase {
        case .showExplanation, .showParentPicker, .showCreateNote, .importing:
            return
        case .idle, .needsSignIn, .failed:
            break
        }
        guard SharedImportStore.peekExists() else { return }
        beginFromPendingStoreIfPossible()
    }

    func continueFromExplanation() {
        guard phase == .showExplanation, pendingPackage != nil else { return }
        phase = .showParentPicker
        bumpActivation()
    }

    func cancel() {
        retryTask?.cancel()
        retryTask = nil
        SharedImportStore.clear()
        pendingPackage = nil
        selectedParentNoteId = nil
        suggestedNoteTitle = ""
        phase = .idle
        bumpActivation()
    }

    func parentPickerWasDismissedWithoutSelection() {
        guard phase == .showParentPicker else { return }
        cancel()
    }

    /// Works out where "Add to Inbox" goes, for its button to name.
    func refreshInboxDestination() async {
        guard let appState else { return }
        inboxDestination = await InboxDestination.resolve(appState: appState)
    }

    /// "Add to Inbox": Trilium's capture destination becomes the parent.
    func inboxDidSelect() async {
        guard phase == .showParentPicker, !isPlacingInInbox, let appState else { return }
        isPlacingInInbox = true
        defer { isPlacingInInbox = false }
        do {
            let destination: InboxDestination
            if let known = inboxDestination {
                destination = known
            } else {
                destination = await InboxDestination.resolve(appState: appState)
            }
            let parentNoteId = try await destination.parentNoteId(appState: appState)
            guard phase == .showParentPicker else { return }
            parentDidSelect(parentNoteId)
        } catch {
            phase = .failed(error.localizedDescription)
            bumpActivation()
        }
    }

    /// Parent chosen — next show the new-note naming sheet (text type only).
    func parentDidSelect(_ parentNoteId: String) {
        guard pendingPackage != nil else {
            phase = .failed(String(localized: "Shared content could not be read.", comment: "Share import error"))
            bumpActivation()
            return
        }
        selectedParentNoteId = parentNoteId
        if let package = pendingPackage {
            suggestedNoteTitle = SharedImportImporter.resolvedTitle(
                for: package.payload,
                imageData: package.binaryData
            )
        }
        phase = .showCreateNote
        bumpActivation()
    }

    func createNoteSheetWasDismissedWithoutCreating() {
        // Only cancel when the user backs out of naming — not after Create has started
        // (phase moves to `.importing`) or finished (`.idle`).
        guard phase == .showCreateNote else { return }
        cancel()
    }

    /// Call synchronously when the user taps Create so a sheet dismiss cannot cancel the import
    /// before `createNote` runs.
    func beginCreateNote() {
        guard phase == .showCreateNote, pendingPackage != nil, selectedParentNoteId != nil else { return }
        phase = .importing
        bumpActivation()
    }

    /// Creates the text note under the selected parent with shared content applied, then opens it for editing.
    func createNote(title rawTitle: String) async {
        // `beginCreateNote()` normally moves us to `.importing` first; allow a direct call too.
        if phase == .showCreateNote {
            beginCreateNote()
        }
        guard phase == .importing else {
            if phase != .needsSignIn {
                if case .failed = phase {
                    // Keep existing failure.
                } else {
                    phase = .failed(String(localized: "Shared content could not be read.", comment: "Share import error"))
                    bumpActivation()
                }
            }
            return
        }
        guard let package = pendingPackage else {
            phase = .failed(String(localized: "Shared content could not be read.", comment: "Share import error"))
            bumpActivation()
            return
        }
        guard let parentNoteId = selectedParentNoteId else {
            phase = .failed(String(localized: "Choose where to place the note first.", comment: "Share import error"))
            bumpActivation()
            return
        }
        guard let appState, let profileId = appState.activeProfile?.id, appState.isAuthenticated else {
            phase = .needsSignIn
            bumpActivation()
            return
        }

        do {
            // Same as tree/detail new-note: blank title → "Note dd-MM-yyyy HH:mm:ss".
            let title = NoteCreationTitle.resolved(from: rawTitle)
            let needsAttachmentUpload = package.payload.kind == .file
            if needsAttachmentUpload {
                guard appState.networkMonitor.isConnected, appState.client != nil else {
                    phase = .failed(String(localized: "Cannot upload while offline.", comment: "Share import error"))
                    bumpActivation()
                    return
                }
            }

            let result = try SharedImportImporter.importPackage(
                package,
                parentNoteId: parentNoteId,
                persistence: PersistenceManager.shared,
                serverProfileId: profileId,
                titleOverride: title
            )
            SharedImportStore.clear()
            pendingPackage = nil
            selectedParentNoteId = nil
            suggestedNoteTitle = ""

            var openNoteId = result.noteId
            var attachmentId: String?
            var attachmentTitle: String?
            if let pendingTitle = result.pendingAttachmentTitle {
                do {
                    let finalized = try await finalizeSharedFileAttachment(
                        localNoteId: result.noteId,
                        preferredTitle: pendingTitle,
                        appState: appState
                    )
                    openNoteId = finalized.noteId
                    attachmentId = finalized.attachmentId
                    attachmentTitle = finalized.title
                } catch {
                    phase = .failed(error.localizedDescription)
                    bumpActivation()
                    NotificationCenter.default.post(name: .trinoteTreeShouldRefresh, object: nil)
                    return
                }
            }

            pendingOpenNote = PendingOpenSharedNote(
                noteId: openNoteId,
                title: result.title,
                attachmentIdToInsert: attachmentId,
                attachmentTitleToInsert: attachmentTitle
            )
            phase = .idle
            bumpActivation()
            // Text/image shares stay local until the user Saves. File shares already synced the note
            // and uploaded the attachment so the editor can insert the same chip as the toolbar.
            NotificationCenter.default.post(name: .trinoteTreeShouldRefresh, object: nil)
        } catch {
            phase = .failed(error.localizedDescription)
            bumpActivation()
        }
    }

    /// Quick capture closed without saving the shared file.
    func discardQuickCaptureFile() {
        quickCaptureFile = nil
        SharedImportStore.clear()
        bumpActivation()
    }

    /// Saves a shared file from Quick capture: a text note with what was typed under `parentNoteId`,
    /// the file uploaded as its attachment, and a link to the attachment at the end of the text.
    /// Needs a connection, like other file shares. Returns the new note's id.
    func saveSharedFile(
        _ package: SharedImportPackage,
        parentNoteId: String,
        title: String,
        bodyHTML: String,
        attributes: [NoteCreationAttribute]
    ) async throws -> String {
        guard let appState, let profileId = appState.activeProfile?.id, appState.isAuthenticated else {
            throw SharedImportImporter.ImportError.noActiveProfile
        }
        guard appState.networkMonitor.isConnected, let client = appState.client else {
            throw QuickCaptureFileError.offline
        }
        guard let data = package.binaryData, !data.isEmpty else {
            throw SharedImportImporter.ImportError.missingFileData
        }
        let filename = package.payload.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (filename?.isEmpty == false) ? filename! : "attachment"
        let mime = package.payload.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMIME = (mime?.isEmpty == false) ? mime! : "application/octet-stream"

        let persistence = PersistenceManager.shared
        let (localNoteId, _) = try persistence.createOfflineChildNote(
            parentNoteId: parentNoteId,
            title: title,
            noteType: NoteType.text.triliumStorageType,
            mime: NoteType.text.creationMime,
            initialContent: bodyHTML,
            serverProfileId: profileId,
            initialAttributes: attributes
        )
        try persistence.enqueuePendingAttachmentImport(
            noteId: localNoteId,
            role: "file",
            mime: resolvedMIME,
            title: resolvedName,
            position: 0,
            data: data,
            serverProfileId: profileId
        )
        SharedImportStore.clear()
        quickCaptureFile = nil
        if let body = package.payload.bodyText, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LabelSuggester.suggestOnFirstOpen(noteId: localNoteId)
        }

        let finalized = try await finalizeSharedFileAttachment(
            localNoteId: localNoteId,
            preferredTitle: resolvedName,
            appState: appState
        )
        // The same link the editor's attachment chip writes.
        let attachmentId = finalized.attachmentId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? finalized.attachmentId
        let link = ##"<p><a class="reference-link" href="#root/\##(finalized.noteId)?viewMode=attachments&amp;attachmentId=\##(attachmentId)">\##(MarkdownToNoteHTML.escapeHTML(finalized.title))</a></p>"##
        let content = Data((bodyHTML + link).utf8)
        do {
            try await client.updateNoteContent(finalized.noteId, content: content, contentType: "text/html")
            try? persistence.cacheNoteContent(finalized.noteId, content: content, serverProfileId: profileId)
        } catch {
            // The attachment is uploaded either way; the note just lacks the link. Opening it adds it.
            pendingOpenNote = PendingOpenSharedNote(
                noteId: finalized.noteId,
                title: title,
                attachmentIdToInsert: finalized.attachmentId,
                attachmentTitleToInsert: finalized.title
            )
        }
        bumpActivation()
        NotificationCenter.default.post(name: .trinoteTreeShouldRefresh, object: nil)
        return finalized.noteId
    }

    func dismissFailure() {
        if SharedImportStore.peekExists() {
            phase = .showExplanation
        } else {
            pendingPackage = nil
            selectedParentNoteId = nil
            suggestedNoteTitle = ""
            phase = .idle
        }
        bumpActivation()
    }

    /// Dismisses the sign-in prompt while keeping the App Group payload for after login.
    func acknowledgeNeedsSignIn() {
        guard phase == .needsSignIn else { return }
        phase = .idle
        bumpActivation()
    }

    /// Clears `pendingOpenNote` after the Notes tab has consumed it.
    func consumePendingOpenNote() {
        pendingOpenNote = nil
        bumpActivation()
    }

    /// Called when authentication becomes available so a deferred share can continue.
    func onAuthenticated() {
        if pendingPackage != nil {
            phase = .showExplanation
            bumpActivation()
            return
        }
        checkForPendingPayload()
        scheduleRetriesIfNeeded()
    }

    // MARK: - Private

    private enum FinalizeAttachmentError: LocalizedError {
        case noteNotSynced
        case offline
        case uploadFailed

        var errorDescription: String? {
            switch self {
            case .noteNotSynced:
                String(localized: "Could not create the note on the server.", comment: "Share import error")
            case .offline:
                String(localized: "Cannot upload while offline.", comment: "Share import error")
            case .uploadFailed:
                String(localized: "Could not upload the shared file.", comment: "Share import error")
            }
        }
    }

    /// Syncs the offline note, uploads the queued file attachment, and returns server ids for the editor chip.
    private func finalizeSharedFileAttachment(
        localNoteId: String,
        preferredTitle: String,
        appState: AppState
    ) async throws -> (noteId: String, attachmentId: String, title: String) {
        let capture = ShareImportNoteIdRemapCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .trinoteOfflineNoteIdReplaced,
            object: nil,
            queue: .main
        ) { notification in
            guard let from = notification.userInfo?["from"] as? String,
                  let to = notification.userInfo?["to"] as? String,
                  from == localNoteId
            else { return }
            capture.remapped = to
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await appState.flushPendingNoteCreationsIfPossible(assumeSessionIsReady: true)

        let noteId = capture.remapped ?? localNoteId
        guard !noteId.isOfflineLocalNoteId else {
            throw FinalizeAttachmentError.noteNotSynced
        }
        guard let client = appState.client,
              let profileId = appState.activeProfile?.id
        else {
            throw FinalizeAttachmentError.offline
        }

        let pending = try PersistenceManager.shared.fetchPendingAttachmentImports(
            noteId: noteId,
            serverProfileId: profileId
        )
        if let row = pending.first(where: { $0.title == preferredTitle }) ?? pending.first {
            let attachmentId = try await client.uploadNoteAttachment(
                noteId: noteId,
                data: row.data,
                filename: row.title,
                contentType: row.mime
            )
            try? PersistenceManager.shared.deletePendingAttachmentImport(
                id: row.id,
                serverProfileId: profileId
            )
            return (noteId, attachmentId, row.title)
        }

        // Concurrent flush may have already uploaded it.
        if let attachments = try? await client.getNoteAttachments(noteId),
           let match = attachments.first(where: { $0.title == preferredTitle }) ?? attachments.last {
            return (noteId, match.attachmentId, match.title)
        }
        throw FinalizeAttachmentError.uploadFailed
    }

    private func bumpActivation() {
        activationToken &+= 1
    }

    private func beginFromPendingStoreIfPossible() {
        do {
            let package = try SharedImportStore.load()
            pendingPackage = package
            suggestedNoteTitle = SharedImportImporter.resolvedTitle(
                for: package.payload,
                imageData: package.binaryData
            )
            retryTask?.cancel()
            retryTask = nil
            if let appState, appState.isAuthenticated, appState.activeProfile != nil {
                if package.payload.kind == .file {
                    // Files open Quick capture with the file attached; it asks where to put it.
                    quickCaptureFile = package
                    phase = .idle
                } else {
                    phase = .showExplanation
                }
            } else {
                phase = .needsSignIn
            }
            bumpActivation()
        } catch SharedImportStoreError.noPendingPayload {
            // Ignore — URL open can race the extension write.
        } catch {
            phase = .failed(error.localizedDescription)
            bumpActivation()
        }
    }

    private func scheduleRetriesIfNeeded() {
        guard pendingPackage == nil, phase == .idle || phase == .needsSignIn else { return }
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            let delays: [UInt64] = [150, 350, 700, 1_200, 2_000]
            for delay in delays {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.pendingPackage != nil { return }
                switch self.phase {
                case .showExplanation, .showParentPicker, .showCreateNote, .importing:
                    return
                case .idle, .needsSignIn, .failed:
                    break
                }
                self.beginFromPendingStoreIfPossible()
                if self.pendingPackage != nil { return }
            }
        }
    }
}

enum QuickCaptureFileError: LocalizedError {
    case offline

    var errorDescription: String? {
        String(localized: "Attaching a file needs a connection.", comment: "Quick capture: shared file while offline")
    }
}
