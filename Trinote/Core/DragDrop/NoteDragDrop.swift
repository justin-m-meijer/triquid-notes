import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A note dragged out of a list (Search, Recents, Favorites): other apps receive a
/// `triquidnotes://note/…` link and a plain-text title, so dropping it in Notes, Mail or another
/// Trinote window works.
struct NoteDragItem: Transferable {
    let noteId: String
    let title: String

    var url: URL { NoteLink.url(for: noteId) ?? URL(string: "\(NoteLink.scheme)://")! }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.url)
        ProxyRepresentation(exporting: { "\($0.title)\n\($0.url.absoluteString)" })
    }
}

/// Something dropped onto an open note, to be appended to it: a link, an image or text.
enum NoteClip: Transferable {
    case url(URL)
    case image(Data, UTType)
    case text(String)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (url: URL) in NoteClip.url(url) })
        DataRepresentation(importedContentType: .png) { NoteClip.image($0, .png) }
        DataRepresentation(importedContentType: .jpeg) { NoteClip.image($0, .jpeg) }
        DataRepresentation(importedContentType: .heic) { NoteClip.image($0, .heic) }
        DataRepresentation(importedContentType: .gif) { NoteClip.image($0, .gif) }
        ProxyRepresentation(importing: { (text: String) in NoteClip.text(text) })
    }

    /// Trilium HTML for the clip, in the shapes its editor produces.
    var html: String {
        let escape = MarkdownToNoteHTML.escapeHTML
        switch self {
        case .url(let url):
            if let link = NoteLink(url: url) {
                return "<p><a class=\"reference-link\" href=\"#root/\(link.noteId)\">\(escape(link.noteId))</a></p>"
            }
            let text = escape(url.absoluteString)
            return "<p><a href=\"\(text)\">\(text)</a></p>"
        case .image(let data, let type):
            let mime = type.preferredMIMEType ?? "image/png"
            // Figure-wrapped like Trilium's image block; the server turns data URIs into attachments.
            return "<figure class=\"image\"><img src=\"data:\(mime);base64,\(data.base64EncodedString())\"></figure>"
        case .text(let text):
            let paragraphs = text
                .components(separatedBy: CharacterSet.newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { "<p>\(escape($0))</p>" }
            return paragraphs.joined()
        }
    }
}

/// Shows where a drop will land while something is dragged over a note.
struct NoteDropHighlight: View {
    let isTargeted: Bool

    var body: some View {
        if isTargeted {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                .background(.tint.opacity(0.06), in: .rect(cornerRadius: 24, style: .continuous))
                .overlay(alignment: .bottom) {
                    Label(String(localized: "Drop to add to this note", comment: "Drop target hint over an open note"), systemImage: "plus.circle.fill")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 32)
                }
                .padding(10)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }
}
