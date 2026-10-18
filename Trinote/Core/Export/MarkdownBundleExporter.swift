import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Exports a note and the sub-notes cached under it as a folder of Markdown files, from the local
/// cache — so it works offline. The layout follows Trilium's own Markdown export: `Note.md` next to
/// a `Note/` folder with its children. Each file starts with YAML front matter (title, Trilium id,
/// type, labels) so the bundle can be imported again without losing identity.
///
/// Internal links between exported notes become relative links; images that are cached on this
/// device are written to `_assets/` and linked from there.
@MainActor
struct MarkdownBundleExporter {
    struct Summary: Equatable {
        var notes = 0
        var images = 0
        /// Sub-notes known in the tree but without cached content (exported with front matter only).
        var withoutContent = 0
    }

    let context: ModelContext
    let profileId: String
    /// Guards against huge trees and clone cycles.
    var maxNotes = 2_000
    var maxDepth = 24

    private struct Entry {
        let note: CachedNote
        /// Path components of the `.md` file inside the bundle, e.g. `["Projects", "Plan.md"]`.
        let path: [String]
    }

    func export(rootNoteId: String) throws -> (FileWrapper, Summary) {
        guard let root = try fetch(rootNoteId) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let entries = try layout(root: root)
        let pathByNoteId = Dictionary(entries.map { ($0.note.noteId, $0.path) }, uniquingKeysWith: { first, _ in first })
        let labels = try labelsByNote(Set(pathByNoteId.keys))

        var files: [[String]: Data] = [:]
        var assets: [String: Data] = [:]
        var summary = Summary()
        for entry in entries {
            var converter = HTMLToMarkdown()
            let folderDepth = entry.path.count - 1
            converter.resolveNoteLink = { noteId in
                pathByNoteId[noteId].map { Self.relativeLink(to: $0, fromDepth: folderDepth) }
            }
            converter.resolveImage = { src in
                guard let asset = imageAsset(for: src) else { return nil }
                assets[asset.name] = asset.data
                return String(repeating: "../", count: folderDepth) + "_assets/" + asset.name
            }
            let body = markdownBody(for: entry.note, converter: converter)
            if entry.note.content == nil { summary.withoutContent += 1 }
            let text = frontMatter(for: entry.note, labels: labels[entry.note.noteId] ?? []) + body
            files[entry.path] = Data(text.utf8)
            summary.notes += 1
        }
        summary.images = assets.count

        let bundle = FileWrapper(directoryWithFileWrappers: [:])
        for (path, data) in files {
            insert(data, at: path, into: bundle)
        }
        for (name, data) in assets {
            insert(data, at: ["_assets", name], into: bundle)
        }
        bundle.preferredFilename = Self.safeFilename(root.title)
        return (bundle, summary)
    }

    // MARK: - Layout

    private func layout(root: CachedNote) throws -> [Entry] {
        var entries: [Entry] = []
        var visited: Set<String> = []
        func visit(_ note: CachedNote, folder: [String], usedNames: inout Set<String>, depth: Int) throws {
            guard entries.count < maxNotes, depth <= maxDepth, visited.insert(note.noteId).inserted else { return }
            let base = Self.uniqueName(Self.safeFilename(note.title), used: &usedNames)
            entries.append(Entry(note: note, path: folder + [base + ".md"]))
            var childNames: Set<String> = []
            for childId in note.childNoteIds {
                guard let child = try fetch(childId) else { continue }
                try visit(child, folder: folder + [base], usedNames: &childNames, depth: depth + 1)
            }
        }
        var rootNames: Set<String> = ["_assets"]
        try visit(root, folder: [], usedNames: &rootNames, depth: 0)
        return entries
    }

    private func fetch(_ noteId: String) throws -> CachedNote? {
        let profileId = profileId
        var descriptor = FetchDescriptor<CachedNote>(predicate: #Predicate { $0.noteId == noteId && $0.serverProfileId == profileId })
        descriptor.fetchLimit = 1
        guard let note = try context.fetch(descriptor).first, !note.isProtected else { return nil }
        return note
    }

    private func labelsByNote(_ noteIds: Set<String>) throws -> [String: [(String, String)]] {
        let profileId = profileId
        let descriptor = FetchDescriptor<CachedAttribute>(predicate: #Predicate { $0.serverProfileId == profileId && $0.type == "label" })
        var result: [String: [(String, String)]] = [:]
        for attribute in try context.fetch(descriptor) where noteIds.contains(attribute.noteId) && NoteLabelVisibility.isVisible(attribute.name) {
            result[attribute.noteId, default: []].append((attribute.name, attribute.value))
        }
        return result
    }

    // MARK: - Content

    private func markdownBody(for note: CachedNote, converter: HTMLToMarkdown) -> String {
        guard let data = note.content, let raw = String(data: data, encoding: .utf8) else { return "" }
        switch NoteType(rawValue: note.noteType) {
        case .text:
            return converter.convert(raw)
        case .markdown:
            return raw.hasSuffix("\n") ? raw : raw + "\n"
        case .code:
            let language = HTMLToMarkdown.language(fromClass: "language-" + note.mime.replacingOccurrences(of: "/", with: "-")) ?? ""
            return "```\(language)\n\(raw)\(raw.hasSuffix("\n") ? "" : "\n")```\n"
        default:
            // Canvas, maps, files…: their content is not text; the front matter records what they are.
            return ""
        }
    }

    private func frontMatter(for note: CachedNote, labels: [(String, String)]) -> String {
        var lines = ["---", "title: \(Self.yamlString(note.title))", "trilium_id: \(note.noteId)", "type: \(note.noteType)"]
        if let modified = note.utcDateModified { lines.append("modified: \(Self.yamlString(modified))") }
        if !labels.isEmpty {
            lines.append("labels:")
            lines += labels.map { name, value in
                value.isEmpty ? "  - \(Self.yamlString(name))" : "  - \(Self.yamlString("\(name)=\(value)"))"
            }
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n"
    }

    private static let imageSourcePattern = try! NSRegularExpression(pattern: #"api/(attachments|images)/([a-zA-Z0-9_-]+)"#)

    private func imageAsset(for src: String) -> (name: String, data: Data)? {
        let ns = src as NSString
        guard let match = Self.imageSourcePattern.firstMatch(in: src, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let routeType = ns.substring(with: match.range(at: 1))
        let entityId = ns.substring(with: match.range(at: 2))
        let id = "\(profileId):\(routeType):\(entityId)"
        var descriptor = FetchDescriptor<CachedImageData>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let image = try? context.fetch(descriptor).first else { return nil }
        let ext = UTType(mimeType: image.mime)?.preferredFilenameExtension ?? "bin"
        return ("\(entityId).\(ext)", image.data)
    }

    private func insert(_ data: Data, at path: [String], into root: FileWrapper) {
        var folder = root
        for component in path.dropLast() {
            if let existing = folder.fileWrappers?[component], existing.isDirectory {
                folder = existing
            } else {
                let created = FileWrapper(directoryWithFileWrappers: [:])
                created.preferredFilename = component
                folder.addFileWrapper(created)
                folder = created
            }
        }
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = path.last
        folder.addFileWrapper(file)
    }

    // MARK: - Names

    /// A file name that works on every file system: no path separators or reserved characters,
    /// not hidden, not empty, at most 120 characters.
    static func safeFilename(_ title: String) -> String {
        let reserved = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var name = title.components(separatedBy: reserved).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Untitled" }
        return String(name.prefix(120))
    }

    /// A name whose `.md` file and folder are both free in `used`, so a note titled "X.md" never
    /// produces a folder that collides with the file of a note titled "X".
    static func uniqueName(_ base: String, used: inout Set<String>) -> String {
        var candidate = base
        var counter = 2
        while used.contains(candidate.lowercased()) || used.contains(candidate.lowercased() + ".md") {
            candidate = "\(base) (\(counter))"
            counter += 1
        }
        used.insert(candidate.lowercased())
        used.insert(candidate.lowercased() + ".md")
        return candidate
    }

    /// A link from a file `fromDepth` folders deep to `path`, percent-encoded for Markdown.
    static func relativeLink(to path: [String], fromDepth: Int) -> String {
        let encoded = path.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? $0 }
        return String(repeating: "../", count: fromDepth) + encoded.joined(separator: "/")
    }

    static func yamlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// A folder of Markdown for `.fileExporter`.
struct MarkdownBundleDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.folder]
    let wrapper: FileWrapper

    init(wrapper: FileWrapper) {
        self.wrapper = wrapper
    }

    init(configuration: ReadConfiguration) throws {
        wrapper = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        wrapper
    }
}
