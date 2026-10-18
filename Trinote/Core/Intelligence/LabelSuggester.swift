import Foundation
import FoundationModels
import SwiftData
import SwiftUI

/// Trilium labels that are bookkeeping, not meaning: hidden from the note header and never suggested.
enum NoteLabelVisibility {
    static let hiddenNames: Set<String> = [
        "iconClass", "color", "bookmarked", "calendarRoot", "viewType", "collection", "geolocation",
        "sorted", "readOnly", "autoReadOnlyDisabled", "shareRoot", "archived", "clipUrl", "pageUrl",
        // The journal marks its day, week, month and year notes; that is bookkeeping, not a tag.
        "dateNote", "weekNote", "monthNote", "quarterNote", "yearNote",
        // Trilium settings and file metadata.
        "cssClass", "originalFileName", "fileSize", "excludeFromNoteMap", "bookZoomLevel", "widget",
        "executeDescription", "executeButton", "executeTitle", "run", "runOnInstance", "runAtHour",
        "template", "inherit", "appCss", "appTheme", "customRequestHandler", "customResourceProvider",
        "renderNote", "docName", "keyboardShortcut", "disableVersioning", "titleTemplate", "hideChildrenOverview",
        "hidePromotedAttributes", "iconPack", "taskTagNote", "taskTodoRoot", "taskDoneRoot", "mapRootNoteId",
        // Metadata importers write (a PDF's title, a book's description).
        "title", "description", "author", "source", "creationDate", "modificationDate", "pageCount",
    ]

    /// Names that only group values; for these the value alone is the tag ("#tags=politics" → "politics").
    private static let groupingNames: Set<String> = ["tag", "tags", "label", "labels"]

    /// How a label reads in a chip: "boek: lezen", "politics" or "todo" instead of Trilium's
    /// "#boek=lezen" syntax. The chip draws a tag symbol in front.
    static func friendlyText(name: String, value: String) -> String {
        if value.isEmpty { return name }
        // "kerst=kerst" (an earlier label suggestion) reads as the tag itself.
        if value.caseInsensitiveCompare(name) == .orderedSame { return name }
        if groupingNames.contains(name.lowercased()) { return value }
        return "\(name): \(value)"
    }

    /// Tags worth browsing: a label without a value, or a grouping label's value (tags=politics),
    /// but not dates, numbers or file names, which are data rather than tags.
    static func isTag(name: String, value: String) -> Bool {
        guard isVisible(name) else { return false }
        // Structure and metadata: taskTagRoot, bookmarkFolder, wordCount, todoDate…
        let lowered = name.lowercased()
        if ["root", "folder", "count", "date", "size", "level", "url", "id", "hash"].contains(where: { lowered.hasSuffix($0) }) { return false }
        if value.isEmpty { return true }
        guard groupingNames.contains(name.lowercased()) else { return false }
        return value.rangeOfCharacter(from: .letters) != nil && !value.contains(".")
    }

    /// "name" or "name=value" as typed or stored in Quick capture.
    static func friendlyText(raw: String) -> String {
        let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
        return friendlyText(name: parts.first ?? raw, value: parts.count > 1 ? parts[1] : "")
    }

    static func isVisible(_ name: String) -> Bool {
        !hiddenNames.contains(name)
            && !name.hasPrefix("_")
            && !name.hasPrefix("workspace")
            && !name.hasPrefix("share")
            // Settings such as calendar:view or map:style configure a view; they are not tags.
            && !name.contains(":")
    }
}

/// Search queries for one label (`#name` or `#name="value"`), as the tag cloud writes them.
enum LabelQuery {
    static func make(_ label: LabelSuggestion) -> String {
        label.value.isEmpty ? "#\(label.name)" : "#\(label.name)=\"\(label.value)\""
    }

    /// The label a query searches for, when the query is only that; nil for other searches.
    static func parse(_ query: String) -> LabelSuggestion? {
        let pattern = #"^#([A-Za-z0-9_:-]+)(?:=(?:"([^"]*)"|(\S+)))?$"#
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let nameRange = Range(match.range(at: 1), in: trimmed) else { return nil }
        let quoted = Range(match.range(at: 2), in: trimmed).map { String(trimmed[$0]) }
        let bare = Range(match.range(at: 3), in: trimmed).map { String(trimmed[$0]) }
        return LabelSuggestion(name: String(trimmed[nameRange]), value: quoted ?? bare ?? "")
    }
}

/// A label the model proposes: `name` alone, or `name=value` like Trilium's `#tags=resource`.
struct LabelSuggestion: Hashable, Sendable {
    let name: String
    let value: String

    var display: String { value.isEmpty ? "#\(name)" : "#\(name)=\(value)" }
    var friendly: String { NoteLabelVisibility.friendlyText(name: name, value: value) }
}

/// Suggests labels for a note with Apple's on-device model (Apple Intelligence). The note text never
/// leaves the device. Labels already used on the server are offered as the preferred vocabulary so
/// suggestions follow the person's own scheme instead of inventing near-duplicates.
@MainActor
enum LabelSuggester {
    /// False on devices without Apple Intelligence, or while it is off or still downloading.
    static var isAvailable: Bool {
        #if DEBUG
        if isDemo { return true }
        #endif
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    #if DEBUG
    /// `-TrinoteDemoLabelSuggestions`: fixed suggestions where Apple Intelligence cannot run (the
    /// simulator), so the suggestion UI can be checked and screenshotted.
    static var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("-TrinoteDemoLabelSuggestions") }
    #endif

    @Generable
    struct Proposal {
        @Guide(description: "Between 3 and 5 labels that describe what the note is about.", .count(3...5))
        var labels: [ProposedLabel]
    }

    @Generable
    struct ProposedLabel {
        @Guide(description: "The label name: one word or camelCase, no spaces, no leading #. Reuse a name from the existing labels when one fits.")
        var name: String
        @Guide(description: "The value when the existing labels use name=value (for example tags=politics); otherwise an empty string.")
        var value: String
    }

    /// The model's context is small; a note's opening says enough about what it is.
    private static let maxTextLength = 6000

    static func suggest(
        title: String,
        text: String,
        vocabulary: [LabelSuggestion],
        current: [LabelSuggestion]
    ) async throws -> [LabelSuggestion] {
        #if DEBUG
        if isDemo {
            let currentNames = Set(current.map(\.name))
            return [LabelSuggestion(name: "reading", value: ""), LabelSuggestion(name: "books", value: ""), LabelSuggestion(name: "status", value: "todo")]
                .filter { !currentNames.contains($0.name) }
        }
        #endif
        let vocabularyList = vocabulary.prefix(60).map(\.display).joined(separator: ", ")
        let currentList = current.map(\.display).joined(separator: ", ")
        let instructions = """
            You label notes in Trilium, a personal knowledge base. Suggest short labels that help find \
            the note later. Prefer labels from the list of existing labels; only make up a new one when \
            none fits. Write new labels in the language of the existing labels, or in \(NoteSummaryModel.appLanguageName) \
            when there are none. Never repeat a label the note already has.
            """
        let prompt = """
            Existing labels: \(vocabularyList.isEmpty ? "none" : vocabularyList)
            Labels this note already has: \(currentList.isEmpty ? "none" : currentList)

            Title: \(title)

            Text:
            \(String(text.prefix(maxTextLength)))
            """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: Proposal.self)
        let taken = Set(current.map { $0.name.lowercased() + "=" + $0.value.lowercased() })
        var seen = Set<String>()
        return response.content.labels.compactMap { proposed in
            let name = proposed.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .replacingOccurrences(of: " ", with: "")
            var value = proposed.value.trimmingCharacters(in: .whitespacesAndNewlines)
            // The model sometimes repeats the name as the value ("kerst=kerst"): that is a plain tag.
            if value.caseInsensitiveCompare(name) == .orderedSame { value = "" }
            let key = name.lowercased() + "=" + value.lowercased()
            guard !name.isEmpty, NoteLabelVisibility.isVisible(name), !taken.contains(key), seen.insert(key).inserted else {
                return nil
            }
            return LabelSuggestion(name: name, value: value)
        }
    }

    /// The labels used across this server's cached notes, most used first.
    static func vocabulary(serverProfileId: String, context: ModelContext) -> [LabelSuggestion] {
        let profileId = serverProfileId
        let descriptor = FetchDescriptor<CachedAttribute>(
            predicate: #Predicate { $0.serverProfileId == profileId && $0.type == "label" }
        )
        let attributes = (try? context.fetch(descriptor)) ?? []
        var counts: [LabelSuggestion: Int] = [:]
        for attribute in attributes where NoteLabelVisibility.isVisible(attribute.name) {
            // Long values are data (URLs, dates), not a reusable tag.
            var value = attribute.value.count <= 30 ? attribute.value : ""
            if value.caseInsensitiveCompare(attribute.name) == .orderedSame { value = "" }
            counts[LabelSuggestion(name: attribute.name, value: value), default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Plain text from note HTML, enough for the model to read.
    nonisolated static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(of: #"<(script|style)[^>]*>.*?</\1>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<br\s*/?>|</p>|</li>|</h[1-6]>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, value) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Scans

    private static let autoSuggestKey = "labelSuggestOnOpenNoteIds"

    /// A scanned document's note suggests labels from its recognized text the first time it opens.
    static func suggestOnFirstOpen(noteId: String) {
        var ids = UserDefaults.standard.stringArray(forKey: autoSuggestKey) ?? []
        guard !ids.contains(noteId) else { return }
        ids.append(noteId)
        UserDefaults.standard.set(Array(ids.suffix(50)), forKey: autoSuggestKey)
    }

    /// True once per marked note; the mark is cleared.
    static func takeSuggestOnOpen(noteId: String) -> Bool {
        #if DEBUG
        if isDemo { return true }
        #endif
        var ids = UserDefaults.standard.stringArray(forKey: autoSuggestKey) ?? []
        guard let index = ids.firstIndex(of: noteId) else { return false }
        ids.remove(at: index)
        UserDefaults.standard.set(ids, forKey: autoSuggestKey)
        return true
    }
}

/// A small tag symbol before a label's text in a chip.
struct TagChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 11, weight: .semibold))
            configuration.title
        }
    }
}

/// One label chip. Applied labels and suggestions must never look alike: an applied label is a
/// filled accent capsule; a suggestion is neutral, outlined with a dashed line and led by a plus,
/// so it reads as "tap to add" rather than "already on this note".
struct TagChip: View {
    enum Kind {
        /// On the note (or on the note being captured).
        case applied
        /// Offered by Apple Intelligence; tapping adds it.
        case suggested
    }

    let text: String
    let kind: Kind
    /// The applied accent fill; callers pass their resolved accent tint.
    var appliedFill: Color = .accentColor.opacity(0.14)

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind == .applied ? "tag.fill" : "plus")
                .font(.system(size: 10, weight: .bold))
            Text(text)
        }
        .font(.system(size: 14, weight: kind == .applied ? .semibold : .regular))
        .foregroundStyle(kind == .applied ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.trinoteTextSecondary))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            switch kind {
            case .applied:
                Capsule().fill(appliedFill)
            case .suggested:
                Capsule()
                    .fill(Color.trinoteCard)
                    .overlay(Capsule().strokeBorder(Color.trinoteTextTertiary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
        }
        .contentShape(.capsule)
    }
}

/// The small "✨ Suggested" heading above a row of suggestion chips, with a dismiss button.
struct SuggestedLabelsHeader: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
            Text(String(localized: "Suggested", comment: "Heading above Apple Intelligence label suggestions"))
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Dismiss suggestions", comment: "VoiceOver: hide label suggestions"))
        }
        .font(.caption.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(Color.trinoteTextTertiary)
    }
}

/// Lays out chips left to right and starts a new line when the next one does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    /// Centers each line instead of starting it at the leading edge.
    var centersLines = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = centersLines ? bounds.minX + (bounds.width - row.width) / 2 : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            // A chip wider than the line is squeezed to the line's width rather than overflowing.
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, maxWidth)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > maxWidth, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
