import Foundation

enum SharedImportImporter {
    enum ImportError: LocalizedError, Equatable {
        case noActiveProfile
        case emptyPayload
        case missingFileData

        var errorDescription: String? {
            switch self {
            case .noActiveProfile:
                String(localized: "No server profile is active.", comment: "Share import error")
            case .emptyPayload:
                String(localized: "Shared content could not be read.", comment: "Share import error")
            case .missingFileData:
                String(localized: "The shared file could not be read.", comment: "Share import error")
            }
        }
    }

    struct Result: Sendable {
        let noteId: String
        let title: String
        /// Non-nil when a non-image file was queued for upload (same path as toolbar attachments).
        let pendingAttachmentTitle: String?
    }

    /// Creates a text note under `parentNoteId` and applies shared content by kind.
    /// - Parameter titleOverride: When non-nil/non-empty after trimming, used as the note title.
    @MainActor
    static func importPackage(
        _ package: SharedImportPackage,
        parentNoteId: String,
        persistence: PersistenceManager,
        serverProfileId: String,
        titleOverride: String? = nil
    ) throws -> Result {
        let payload = package.payload
        let title: String = {
            if let override = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
                return override
            }
            return resolvedTitle(for: payload, imageData: package.binaryData)
        }()
        let initialContent: String
        let attachment: (data: Data, filename: String, mime: String)?
        var attributes: [NoteCreationAttribute] = []
        switch payload.kind {
        case .webClip:
            guard let clip = payload.webClip else { throw ImportError.emptyPayload }
            initialContent = WebClipNoteBuilder.html(for: clip)
            // Like Tri Clipper: #clipUrl finds the note again for the same page.
            attributes.append(NoteCreationAttribute(type: "label", name: "clipUrl", value: clip.url))
            attachment = nil

        case .image:
            if let data = package.binaryData, !data.isEmpty {
                let mime = resolvedImageMIME(payload: payload, data: data)
                let base64 = data.base64EncodedString()
                // Use figure-wrapped img (Trilium/TipTap image block). A bare `<p><img>` becomes an
                // empty paragraph above the image in the editor.
                initialContent = "<figure class=\"image\"><img src=\"data:\(mime);base64,\(base64)\"></figure>"
            } else {
                initialContent = "<p></p>"
            }
            attachment = nil

        case .plainText:
            let text = payload.text
                ?? package.binaryData.flatMap { String(data: $0, encoding: .utf8) }
                ?? ""
            initialContent = PlainTextToNoteHTML.convert(text)
            attachment = nil

        case .markdown:
            let text = payload.text
                ?? package.binaryData.flatMap { String(data: $0, encoding: .utf8) }
                ?? ""
            initialContent = MarkdownToNoteHTML.convert(text)
            attachment = nil

        case .file:
            guard let data = package.binaryData, !data.isEmpty else {
                throw ImportError.missingFileData
            }
            let filename = payload.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = (filename?.isEmpty == false) ? filename! : "attachment"
            let mime = payload.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedMIME = (mime?.isEmpty == false) ? mime! : "application/octet-stream"
            if let body = payload.bodyText, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                initialContent = PlainTextToNoteHTML.convert(body)
            } else {
                initialContent = ""
            }
            attachment = (data, resolvedName, resolvedMIME)
        }

        if initialContent.isEmpty, attachment == nil, payload.text == nil, package.binaryData == nil {
            throw ImportError.emptyPayload
        }

        let (noteId, _) = try persistence.createOfflineChildNote(
            parentNoteId: parentNoteId,
            title: title,
            noteType: NoteType.text.triliumStorageType,
            mime: NoteType.text.creationMime,
            initialContent: initialContent,
            serverProfileId: serverProfileId,
            initialAttributes: attributes
        )

        var pendingAttachmentTitle: String?
        if let attachment {
            try persistence.enqueuePendingAttachmentImport(
                noteId: noteId,
                role: "file",
                mime: attachment.mime,
                title: attachment.filename,
                position: 0,
                data: attachment.data,
                serverProfileId: serverProfileId
            )
            pendingAttachmentTitle = attachment.filename
        }

        // Recognized text from a scan: suggest labels from it when the note first opens.
        if case .file = payload.kind, let body = payload.bodyText, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LabelSuggester.suggestOnFirstOpen(noteId: noteId)
        }

        return Result(noteId: noteId, title: title, pendingAttachmentTitle: pendingAttachmentTitle)
    }

    static func resolvedTitle(for payload: SharedImportPayload, imageData: Data? = nil) -> String {
        if payload.kind == .webClip, let clip = payload.webClip {
            let title = clip.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? (URL(string: clip.url)?.host() ?? clip.url) : title
        }
        if let name = payload.filename?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let base = (name as NSString).deletingPathExtension
            let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if !SharedImportTitle.isGenericPlaceholderBasename(trimmed) {
                    return trimmed
                }
                // Generic placeholders like "shared-image.jpg" fall through to kind-based defaults.
            } else if !SharedImportTitle.isGenericPlaceholderBasename(name) {
                return name
            }
        }
        switch payload.kind {
        case .image:
            let date = SharedImportTitle.preferredImageTitleDate(fromImageData: imageData)
            return SharedImportTitle.timestampedImageTitle(at: date)
        case .plainText, .markdown:
            if let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
                if firstLine.count <= 60 { return firstLine }
                return String(firstLine.prefix(57)) + "…"
            }
            return String(localized: "Shared note", comment: "Default title for shared text note")
        case .file:
            return String(localized: "Shared file", comment: "Default title for shared file note")
        case .webClip:
            return payload.text.flatMap { URL(string: $0)?.host() } ?? String(localized: "Clipped page", comment: "Default title for a clipped web page")
        }
    }

    private static func resolvedImageMIME(payload: SharedImportPayload, data: Data) -> String {
        if let mime = payload.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines),
           mime.hasPrefix("image/") {
            return mime
        }
        return data.detectImageMIME()
    }
}

/// A clipped page as note HTML: where it came from, then the article.
enum WebClipNoteBuilder {
    static func html(for clip: SharedWebClip) -> String {
        let escape = MarkdownToNoteHTML.escapeHTML
        var source = "<a href=\"\(escape(clip.url))\">\(escape(clip.site.isEmpty ? clip.url : clip.site))</a>"
        if !clip.author.isEmpty { source += " · \(escape(clip.author))" }
        if let date = publishedDate(clip.published) { source += " · \(escape(date))" }
        return "<p><em>\(source)</em></p>" + (clip.isSelection ? "<blockquote>\(clip.html)</blockquote>" : clip.html)
    }

    private static func publishedDate(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: String(raw.prefix(10)) + "T00:00:00Z") {
            return date.formatted(date: .long, time: .omitted)
        }
        return nil
    }
}
