import Foundation
import PDFKit
import UIKit
import Vision

/// Text inside a note's images and PDFs (a ticket, a scanned letter), so summaries and label
/// suggestions have something to work with when the note itself has little text. All on device:
/// a PDF's own text layer, else Vision text recognition on its first pages or on the image.
@MainActor
enum NoteVisualText {
    /// Below this many characters of its own, a note's images and PDFs are read too.
    static let ownTextThreshold = 200
    private static let maxPDFPages = 3
    private static let maxImages = 4
    private static let maxCharacters = 6_000

    /// The note's own text, followed by what its images and PDFs say when the note is short.
    static func text(for note: NoteItem, viewModel vm: NoteDetailViewModel, ownText: String) async -> String {
        let trimmed = ownText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count < ownTextThreshold else { return ownText }
        let extracted = await extract(note: note, viewModel: vm)
        guard !extracted.isEmpty else { return ownText }
        let combined = trimmed.isEmpty ? extracted : trimmed + "\n\n" + extracted
        return String(combined.prefix(maxCharacters))
    }

    private static func extract(note: NoteItem, viewModel vm: NoteDetailViewModel) async -> String {
        var parts: [String] = []
        switch note.type {
        case .image:
            if let data = vm.content, let image = UIImage(data: data) {
                parts.append(await recognizedText(in: [image]))
            }
        case .file:
            if let data = vm.content, isPDF(mime: note.mime, title: note.title) {
                parts.append(await pdfText(data))
            } else if let data = vm.content, let image = UIImage(data: data) {
                parts.append(await recognizedText(in: [image]))
            }
        default:
            // Attached PDFs (shown as cards under the text), then images in the text.
            if vm.attachments.isEmpty, vm.isOnline { await vm.loadAttachments() }
            for attachment in vm.attachments where attachment.role == "file" && isPDF(mime: attachment.mime, title: attachment.title) {
                if let (data, _) = await vm.downloadAttachment(attachment), !data.isEmpty {
                    parts.append(await pdfText(data))
                }
            }
            let images = await imagesInHTML(vm.contentString ?? "", viewModel: vm)
            if !images.isEmpty { parts.append(await recognizedText(in: images)) }
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func isPDF(mime: String?, title: String) -> Bool {
        mime?.lowercased() == "application/pdf" || title.lowercased().hasSuffix(".pdf")
    }

    /// The PDF's text layer, or recognized text on its first pages when it is a scan.
    static func pdfText(_ data: Data) async -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        let pageCount = min(document.pageCount, maxPDFPages)
        let layer = (0..<pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        if layer.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { return layer }
        let pages: [UIImage] = (0..<pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 1600 / max(bounds.width, bounds.height, 1)
            return page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        }
        return await recognizedText(in: pages)
    }

    /// Images embedded in the note (data URIs) or served by Trilium. The display HTML has those as
    /// `trinote-img://attachments/…` (raw bodies as `api/attachments/…`); bytes come from the cache, else the server.
    private static func imagesInHTML(_ html: String, viewModel vm: NoteDetailViewModel) async -> [UIImage] {
        var images: [UIImage] = []
        let ns = html as NSString
        if html.contains("data:image/") {
            for match in dataURIPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                guard images.count < maxImages,
                      let data = Data(base64Encoded: ns.substring(with: match.range(at: 1)), options: .ignoreUnknownCharacters),
                      let image = UIImage(data: data) else { continue }
                images.append(image)
            }
        }
        var seen = Set<String>()
        for match in serverImagePattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard images.count < maxImages else { break }
            let route = ns.substring(with: match.range(at: 1)).lowercased()
            let entityId = ns.substring(with: match.range(at: 2))
            guard seen.insert(route + "/" + entityId).inserted else { continue }
            if let data = await vm.loadImageBytes(routeType: route, entityId: entityId),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }
        return images
    }

    private static let dataURIPattern = try! NSRegularExpression(pattern: #"data:image/[a-zA-Z+.-]+;base64,([A-Za-z0-9+/=\s]+)"#)
    private static let serverImagePattern = try! NSRegularExpression(
        pattern: #"(?i)(?:api/|trinote-img://)(attachments|images)/([a-zA-Z0-9_-]+)"#
    )

    private static func recognizedText(in images: [UIImage]) async -> String {
        await QuickCapture.recognizedText(in: images)
    }
}
