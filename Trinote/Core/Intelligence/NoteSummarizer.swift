import Foundation
import FoundationModels
import Observation
import SwiftUI

/// An on-device summary of the open note (Apple Intelligence, Foundation Models), streamed into a
/// card at the top of the note. Nothing leaves the device; it is written to the note only when asked.
@MainActor
@Observable
final class NoteSummaryModel {
    /// What the card shows: a summary, the note's open to-dos, or a title for it.
    enum Kind: Equatable {
        case summary, todos, title
    }

    private(set) var kind: Kind = .summary
    /// The to-dos found in the note (`.todos`).
    private(set) var todos: [String] = []
    private(set) var text = ""
    private(set) var isGenerating = false
    private(set) var errorMessage: String?
    var isVisible = false

    @ObservationIgnored private var task: Task<Void, Never>?

    /// The on-device model reads a few thousand tokens; longer notes are summarized from their start.
    private static let maxInputCharacters = 6_000

    static var isAvailable: Bool {
        #if DEBUG
        if LabelSuggester.isDemo { return true }
        #endif
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func summarize(title: String, plainText: String) {
        start(.summary, title: title, plainText: plainText)
    }

    /// The action items in the note, as a checklist to add to it. Items already on a checklist in
    /// the note (`existing`) are left out, so adding them doesn't list them twice.
    func findTodos(title: String, plainText: String, existing: [String] = []) {
        existingTodos = Set(existing.map(Self.normalized))
        existingTodoList = existing
        start(.todos, title: title, plainText: plainText)
    }

    @ObservationIgnored private var existingTodos: Set<String> = []
    @ObservationIgnored private var existingTodoList: [String] = []

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// The descriptions of the checklist items already in a note's HTML.
    static func checklistItems(inHTML html: String) -> [String] {
        let pattern = #"todo-list__label__description\">(.*?)</span>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            Range(match.range(at: 1), in: html).map { LabelSuggester.plainText(fromHTML: String(html[$0])) }
        }
    }

    /// A short title for the note, from its text.
    func suggestTitle(title: String, plainText: String) {
        start(.title, title: title, plainText: plainText)
    }

    private func start(_ kind: Kind, title: String, plainText: String) {
        task?.cancel()
        self.kind = kind
        isVisible = true
        text = ""
        todos = []
        errorMessage = nil
        let body = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            errorMessage = String(localized: "This note has no text to summarize.", comment: "Note summary: empty note")
            return
        }
        isGenerating = true
        let input = String(body.prefix(Self.maxInputCharacters))
        let truncated = body.count > Self.maxInputCharacters
        task = Task { [weak self] in
            switch kind {
            case .summary: await self?.run(title: title, body: input, truncated: truncated)
            case .todos: await self?.runTodos(title: title, body: input)
            case .title: await self?.runTitle(body: input)
            }
        }
    }

    /// Whether there is something to put in the note.
    var hasResult: Bool {
        errorMessage == nil && (kind == .todos ? !todos.isEmpty : !text.isEmpty)
    }

    /// The found to-dos as a Trilium checklist under a heading, for the end of the note.
    var todosHTML: String {
        let heading = String(localized: "To-dos", comment: "Note AI: heading above the extracted checklist")
        let items = todos.map {
            "<li><label class=\"todo-list__label\"><input type=\"checkbox\" disabled=\"disabled\"><span class=\"todo-list__label__description\">\(Self.escaped($0))</span></label></li>"
        }.joined()
        return "<h3>\(Self.escaped(heading))</h3><ul class=\"todo-list\">\(items)</ul>"
    }

    @Generable
    struct FoundTodos {
        @Guide(description: "Concrete action items from the note, each a short imperative phrase. Empty when the note has none.", .maximumCount(12))
        var items: [String]
    }

    @Generable
    struct SuggestedTitle {
        @Guide(description: "A short, specific title for the note, at most eight words, without quotes or a trailing period.")
        var title: String
    }

    private func runTodos(title: String, body: String) async {
        defer { isGenerating = false }
        // In the note's own language: the items go into the note, and a translated copy of a to-do
        // already on its checklist would slip past the duplicate check.
        let session = LanguageModelSession(instructions: """
            You find the action items in personal notes: things the writer still has to do. Write each \
            as a short imperative phrase in the same language as the note, keeping its wording. Skip \
            things already done, plain facts, and items already on the note's checklist. Return no \
            items when there are none.
            """)
        let already = existingTodoList.isEmpty ? "" : "\nAlready on the checklist (skip these):\n" + existingTodoList.map { "- \($0)" }.joined(separator: "\n")
        do {
            let response = try await session.respond(to: "Title: \(title)\n\(body)\(already)", generating: FoundTodos.self)
            guard !Task.isCancelled else { return }
            var seen = existingTodos
            let items = response.content.items
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".;")) }
                .filter { !$0.isEmpty && seen.insert(Self.normalized($0)).inserted }
            todos = items
            if items.isEmpty {
                errorMessage = String(localized: "No new to-dos found in this note.", comment: "Note AI: nothing to extract")
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = String(localized: "Couldn't read this note.", comment: "Note AI: generation failed")
        }
    }

    private func runTitle(body: String) async {
        defer { isGenerating = false }
        let language = Self.appLanguageName
        let session = LanguageModelSession(instructions: """
            You give personal notes a short, specific title in \(language), like a person would: \
            what the note is about, not a sentence.
            """)
        do {
            let response = try await session.respond(to: body, generating: SuggestedTitle.self)
            guard !Task.isCancelled else { return }
            text = response.content.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”"))
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = String(localized: "Couldn't read this note.", comment: "Note AI: generation failed")
        }
    }

    /// A summary of a clipped article in the app's language, for the top of the clip; nil when
    /// Apple Intelligence is off or the text is too short to need one.
    static func clipSummary(title: String, plainText: String) async -> String? {
        guard isAvailable else { return nil }
        let body = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count > 600 else { return nil }
        let session = LanguageModelSession(instructions: """
            You summarize web articles a person saved to read later. Write two to three short \
            sentences in \(appLanguageName): what the article says and why it matters. No preamble.
            """)
        let prompt = "Title: \(title)\n\(body.prefix(maxInputCharacters))"
        return try? await session.respond(to: prompt).content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The summary as a quote block for the top of a text note.
    var noteHTML: String {
        let heading = String(localized: "Summary", comment: "Note summary card title")
        let paragraphs = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "<p>\(Self.escaped($0))</p>" }
            .joined()
        return "<blockquote><p><strong>\(Self.escaped(heading))</strong></p>\(paragraphs)</blockquote>"
    }

    /// The language the app shows (Dutch, French, German, English…), named in English for the
    /// instructions: "the language of the note" let the English instructions pull summaries to English.
    static var appLanguageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    private static func escaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func dismiss() {
        task?.cancel()
        task = nil
        isGenerating = false
        isVisible = false
    }

    private func run(title: String, body: String, truncated: Bool) async {
        defer { isGenerating = false }
        #if DEBUG
        if LabelSuggester.isDemo {
            for word in "A short demo summary: the note collects reading notes, open questions and the next steps to take.".split(separator: " ") {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                text += (text.isEmpty ? "" : " ") + word
            }
            return
        }
        #endif
        let language = Self.appLanguageName
        let session = LanguageModelSession(instructions: """
            You summarize personal notes. Write two to four short sentences in \(language), whatever language \
            the note is in. Mention the main point first, then any decisions, dates or next steps. \
            No preamble, no bullet points.
            """)
        let prompt = """
            Title: \(title)
            \(truncated ? "(Only the beginning of the note is included.)\n" : "")
            \(body)
            """
        do {
            for try await snapshot in session.streamResponse(to: prompt) {
                guard !Task.isCancelled else { return }
                text = snapshot.content
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = String(localized: "Couldn't summarize this note.", comment: "Note summary: generation failed")
        }
    }
}

/// The summary card shown above the note body.
struct NoteSummaryCard: View {
    @Environment(\.appFont) private var appFont
    let model: NoteSummaryModel
    let onRegenerate: () -> Void
    /// Writes the summary into the note; nil hides the button (not a text note, or not editable right now).
    var onAddToNote: (() -> Void)?

    private var cardTitle: String {
        switch model.kind {
        case .summary: String(localized: "Summary", comment: "Note summary card title")
        case .todos: String(localized: "To-dos", comment: "Note AI: heading above the extracted checklist")
        case .title: String(localized: "Suggested title", comment: "Note AI: title suggestion card")
        }
    }

    private var addLabel: String {
        switch model.kind {
        case .summary: String(localized: "Add summary to note", comment: "Note summary: insert at the top of the note")
        case .todos: String(localized: "Add to-dos to note", comment: "Note AI: append the checklist to the note")
        case .title: String(localized: "Use as title", comment: "Note AI: rename the note to the suggestion")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "apple.intelligence")
                    .symbolEffect(.pulse, isActive: model.isGenerating)
                Text(cardTitle)
                Spacer(minLength: 8)
                if !model.isGenerating {
                    Button(action: onRegenerate) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(String(localized: "Summarize again", comment: "Note summary: regenerate"))
                    Button {
                        UIPasteboard.general.string = model.kind == .todos ? model.todos.joined(separator: "\n") : model.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(!model.hasResult)
                    .accessibilityLabel(String(localized: "Copy summary", comment: "Note summary: copy"))
                    if let onAddToNote {
                        Button(action: onAddToNote) {
                            Image(systemName: model.kind == .title ? "character.cursor.ibeam" : "text.badge.plus")
                        }
                        .disabled(!model.hasResult)
                        .accessibilityLabel(addLabel)
                    }
                }
                Button {
                    withAnimation(.snappy) { model.dismiss() }
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(String(localized: "Close summary", comment: "Note summary: close"))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.trinoteTextSecondary)
            .buttonStyle(.borderless)

            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Color.trinoteTextSecondary)
            } else if model.kind == .todos, !model.todos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.todos, id: \.self) { item in
                        Label(item, systemImage: "circle")
                            .font(.body).fontDesign(appFont.displayDesign)
                            .foregroundStyle(Color.trinoteTextPrimary)
                    }
                }
            } else if model.text.isEmpty {
                // Placeholder lines while the first words arrive.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach([1.0, 0.92, 0.6], id: \.self) { fraction in
                        GeometryReader { proxy in
                            Capsule().fill(Color.trinoteSeparator)
                                .frame(width: proxy.size.width * fraction, height: 10)
                        }
                        .frame(height: 10)
                    }
                }
                .redacted(reason: .placeholder)
            } else {
                Text(model.text)
                    .font(.body).fontDesign(appFont.displayDesign)
                    .foregroundStyle(Color.trinoteTextPrimary)
                    .textSelection(.enabled)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: model.text)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1
                        )
                )
        }
        .accessibilityElement(children: .contain)
    }
}
