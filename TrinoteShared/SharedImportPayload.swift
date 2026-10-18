import Foundation

/// Metadata written by the Share Extension for the main app to consume.
struct SharedImportPayload: Codable, Sendable, Equatable {
    var id: String
    var createdAt: Date
    var filename: String?
    var mimeType: String?
    var uti: String?
    var kind: SharedImportKind
    /// UTF-8 text when kind is `.plainText` or `.markdown`, or a shared URL string.
    var text: String?
    /// When true, binary bytes live at `SharedImportConstants.binaryFileName` in the App Group.
    var hasBinaryData: Bool
    /// Plain text for the note body next to a `.file` attachment (the recognized text of a scan).
    var bodyText: String?
    /// The clipped page when kind is `.webClip`.
    var webClip: SharedWebClip?

    init(
        id: String = UUID().uuidString,
        createdAt: Date = .now,
        filename: String?,
        mimeType: String?,
        uti: String?,
        kind: SharedImportKind,
        text: String?,
        hasBinaryData: Bool,
        bodyText: String? = nil,
        webClip: SharedWebClip? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.filename = filename
        self.mimeType = mimeType
        self.uti = uti
        self.kind = kind
        self.text = text
        self.hasBinaryData = hasBinaryData
        self.bodyText = bodyText
        self.webClip = webClip
    }
}

/// What TriClipper.js extracted from a page.
struct SharedWebClip: Codable, Sendable, Equatable {
    var url: String
    var title: String
    var site: String
    var author: String
    var published: String
    var excerpt: String
    /// The article, or the selection when there was one, in Trilium's HTML subset.
    var html: String
    var isSelection: Bool

    /// From the dictionary TriClipper.js returns (`TriClipperExtract()`).
    init?(dictionary: [String: Any]) {
        guard let url = dictionary["url"] as? String, !url.isEmpty else { return nil }
        let selection = (dictionary["selectionHtml"] as? String) ?? ""
        let article = (dictionary["articleHtml"] as? String) ?? ""
        self.url = url
        self.title = (dictionary["title"] as? String) ?? ""
        self.site = (dictionary["site"] as? String) ?? ""
        self.author = (dictionary["author"] as? String) ?? ""
        self.published = (dictionary["published"] as? String) ?? ""
        self.excerpt = (dictionary["excerpt"] as? String) ?? ""
        self.isSelection = !selection.isEmpty
        self.html = selection.isEmpty ? article : selection
    }
}

/// Payload plus optional binary bytes loaded from the App Group.
struct SharedImportPackage: Sendable, Equatable {
    var payload: SharedImportPayload
    var binaryData: Data?
}
