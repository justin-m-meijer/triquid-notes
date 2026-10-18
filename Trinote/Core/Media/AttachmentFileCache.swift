import Foundation

/// Keeps note attachments (PDFs, documents, any file) and each note's attachment list on the device,
/// next to the cached images, so they open offline. Uses the image cache store with its own entity
/// types, so Clear Cache and the cached-notebook choices apply to files too.
@MainActor
enum AttachmentFileCache {
    static let fileEntityType = "attachmentFile"
    private static let listEntityType = "attachmentList"

    private static var persistence: PersistenceManager { .shared }

    static func data(attachmentId: String, serverProfileId: String) -> Data? {
        (try? persistence.fetchCachedImage(entityId: attachmentId, entityType: fileEntityType, serverProfileId: serverProfileId))?.data
    }

    static func store(_ data: Data, attachmentId: String, mime: String, noteId: String, parentNoteIds: [String], serverProfileId: String) {
        try? persistence.cacheImageIfAllowed(
            entityId: attachmentId,
            entityType: fileEntityType,
            data: data,
            mime: mime,
            sourceNoteId: noteId,
            parentNoteIds: parentNoteIds,
            serverProfileId: serverProfileId,
            policy: CacheExclusionPolicy()
        )
    }

    // MARK: - Attachment lists

    private struct StoredAttachment: Codable {
        let attachmentId, ownerId, role, mime, title: String
        let position, contentLength: Int
    }

    static func list(noteId: String, serverProfileId: String) -> [AttachmentItem] {
        guard let data = (try? persistence.fetchCachedImage(entityId: noteId, entityType: listEntityType, serverProfileId: serverProfileId))?.data,
              let stored = try? JSONDecoder().decode([StoredAttachment].self, from: data) else { return [] }
        return stored.map {
            AttachmentItem(attachmentId: $0.attachmentId, ownerId: $0.ownerId, role: $0.role, mime: $0.mime, title: $0.title, position: $0.position, contentLength: $0.contentLength)
        }
    }

    static func storeList(_ items: [AttachmentItem], noteId: String, parentNoteIds: [String], serverProfileId: String) {
        let stored = items.map {
            StoredAttachment(attachmentId: $0.attachmentId, ownerId: $0.ownerId, role: $0.role, mime: $0.mime, title: $0.title, position: $0.position, contentLength: $0.contentLength)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? persistence.cacheImageIfAllowed(
            entityId: noteId,
            entityType: listEntityType,
            data: data,
            mime: "application/json",
            sourceNoteId: noteId,
            parentNoteIds: parentNoteIds,
            serverProfileId: serverProfileId,
            policy: CacheExclusionPolicy()
        )
    }

    /// Attachments a note's HTML links to that are not inline images (those are cached as images).
    nonisolated static func linkedAttachmentIds(in html: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"attachmentId=([A-Za-z0-9_]+)"#) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return Set(regex.matches(in: html, range: range).compactMap { match in
            Range(match.range(at: 1), in: html).map { String(html[$0]) }
        })
    }

    nonisolated static func mime(for data: Data) -> String {
        data.starts(with: Array("%PDF".utf8)) ? "application/pdf" : "application/octet-stream"
    }
}
