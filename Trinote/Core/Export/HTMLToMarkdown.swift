import Foundation

/// Converts Trilium (CKEditor 5) note HTML to CommonMark / GFM. Tolerant of HTML that is not
/// well-formed XML (`<br>`, `<img>`, named entities), so it scans tags instead of parsing XML.
///
/// Covers what Trilium's editor produces: headings, paragraphs, bold/italic/strike/code, links
/// (including internal `#root/…/noteId` links via `resolveNoteLink`), images, bulleted, numbered and
/// to-do lists (nested), block quotes, code blocks with a language, tables and horizontal rules.
/// Anything else keeps its text.
struct HTMLToMarkdown {
    /// Rewrites an internal note link (`#root/abc/noteId`) to a relative file path; `nil` keeps it as is.
    var resolveNoteLink: (_ noteId: String) -> String? = { _ in nil }
    /// Rewrites an image `src` (e.g. `api/images/…`) to a bundled file path; `nil` keeps it as is.
    var resolveImage: (_ src: String) -> String? = { _ in nil }

    func convert(_ html: String) -> String {
        var state = State()
        for token in Self.tokenize(html) {
            switch token {
            case .text(let text):
                state.appendText(Self.decodeEntities(text))
            case .open(let name, let attributes):
                open(name, attributes: attributes, state: &state)
            case .close(let name):
                close(name, state: &state)
            }
        }
        return Self.tidy(state.output)
    }

    // MARK: - Tags

    private func open(_ name: String, attributes: [String: String], state: inout State) {
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            state.startBlock()
            state.write(String(repeating: "#", count: Int(name.dropFirst()) ?? 1) + " ")
        case "p", "div", "figure":
            state.startBlock()
        case "br":
            // A backslash break survives editors that strip trailing spaces.
            if state.preDepth > 0 { state.write("\n") } else { state.write("\\\n" + state.linePrefix) }
        case "strong", "b":
            state.write("**")
        case "em", "i":
            state.write("*")
        case "s", "del", "strike":
            state.write("~~")
        case "code":
            if state.preDepth == 0 {
                state.write("`")
                state.inlineCodeDepth += 1
            } else if state.pendingFenceLanguage != nil {
                // Trilium puts the language on <code>, other editors on <pre>.
                if let language = attributes["class"].flatMap(Self.language(fromClass:)) {
                    state.pendingFenceLanguage = language
                }
                state.flushFence()
            }
        case "pre":
            state.startBlock()
            state.pendingFenceLanguage = attributes["class"].flatMap(Self.language(fromClass:)) ?? ""
            state.preDepth += 1
        case "blockquote":
            state.startBlock()
            state.quoteDepth += 1
            state.write("> ")
            state.atItemStart = true
        case "ul":
            state.lists.append(.init(ordered: false, isTodo: attributes["class"]?.contains("todo-list") == true))
            if state.lists.count == 1 { state.startBlock() }
        case "ol":
            state.lists.append(.init(ordered: true, counter: Int(attributes["start"] ?? "") ?? 1))
            if state.lists.count == 1 { state.startBlock() }
        case "li":
            state.startListItem()
        case "input":
            // Trilium to-do items: <li><label class="todo-list__label"><input type="checkbox" checked>…
            if attributes["type"] == "checkbox" {
                state.markTodo(checked: attributes.keys.contains("checked"))
            }
        case "a":
            state.write("[")
            state.links.append(link(for: attributes["href"] ?? ""))
        case "img":
            let src = attributes["src"] ?? ""
            let alt = (attributes["alt"] ?? "").replacingOccurrences(of: "]", with: "")
            state.write("![\(alt)](\(resolveImage(src) ?? src))")
        case "hr":
            state.startBlock()
            state.write("---")
            state.startBlock()
        case "table":
            state.startBlock()
            state.table = TableState()
        case "tr":
            state.table?.rows.append([])
        case "th", "td":
            if name == "th" { state.table?.hasHeader = true }
            if var table = state.table, !table.rows.isEmpty {
                table.rows[table.rows.count - 1].append("")
                state.table = table
            }
            state.inCell = true
        default:
            break
        }
    }

    private func close(_ name: String, state: inout State) {
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6", "p", "div", "figure":
            state.startBlock()
        case "strong", "b":
            state.write("**")
        case "em", "i":
            state.write("*")
        case "s", "del", "strike":
            state.write("~~")
        case "code":
            if state.preDepth == 0 {
                state.write("`")
                state.inlineCodeDepth = max(0, state.inlineCodeDepth - 1)
            }
        case "pre":
            state.flushFence()
            state.preDepth = max(0, state.preDepth - 1)
            if !state.output.hasSuffix("\n") { state.write("\n") }
            state.write("```")
            state.startBlock()
        case "blockquote":
            // Drop the empty quote line the last paragraph left behind.
            state.output = state.output.replacingOccurrences(of: "(\\n>[ >]*)+$", with: "", options: .regularExpression)
            state.quoteDepth = max(0, state.quoteDepth - 1)
            state.startBlock()
        case "ul", "ol":
            _ = state.lists.popLast()
            if state.lists.isEmpty { state.startBlock() }
        case "a":
            let href = state.links.popLast() ?? ""
            state.write("](\(href))")
        case "th", "td":
            state.inCell = false
        case "table":
            if let table = state.table { state.write(table.markdown) }
            state.table = nil
            state.startBlock()
        default:
            break
        }
    }

    private func link(for href: String) -> String {
        if let hashRange = href.range(of: "#root/") {
            let noteId = href[hashRange.upperBound...].split(separator: "/").last.map(String.init) ?? ""
            if let resolved = resolveNoteLink(noteId) { return resolved }
        }
        return href.replacingOccurrences(of: " ", with: "%20")
    }

    // MARK: - Writer state

    private struct ListState {
        var ordered: Bool
        var counter = 1
        var isTodo = false
    }

    private struct TableState {
        var rows: [[String]] = []
        var hasHeader = false

        var markdown: String {
            guard !rows.isEmpty else { return "" }
            let width = rows.map(\.count).max() ?? 0
            let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
            func line(_ cells: [String]) -> String {
                "| " + cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
            }
            // GFM needs a header row; without one the first row becomes it.
            var lines = [line(padded[0]), "|" + Array(repeating: " --- |", count: width).joined()]
            lines += padded.dropFirst().map(line)
            return lines.joined(separator: "\n")
        }
    }

    private struct State {
        var output = ""
        var lists: [ListState] = []
        var quoteDepth = 0
        var preDepth = 0
        var links: [String] = []
        var table: TableState?
        var inCell = false
        /// Right after a list marker or `> `: a `<p>` there must not start a new line.
        var atItemStart = false
        /// Inside `<code>` outside a block: text is literal, Markdown escapes would show.
        var inlineCodeDepth = 0
        /// A code block's opening fence waits for its language (`<pre><code class="language-…">`).
        var pendingFenceLanguage: String?

        mutating func flushFence() {
            guard let language = pendingFenceLanguage else { return }
            pendingFenceLanguage = nil
            write("```\(language)\n")
        }

        var linePrefix: String {
            String(repeating: "> ", count: quoteDepth) + String(repeating: "   ", count: max(0, lists.count - 1))
        }

        mutating func write(_ text: String) {
            if !text.isEmpty { atItemStart = false }
            if inCell, table != nil {
                let row = table!.rows.count - 1
                guard row >= 0, !table!.rows[row].isEmpty else { return }
                table!.rows[row][table!.rows[row].count - 1] += text
                return
            }
            output += text
        }

        mutating func appendText(_ raw: String) {
            if preDepth > 0 {
                flushFence()
                write(raw)
                return
            }
            let collapsed = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if collapsed == " ", output.hasSuffix("\n") || output.hasSuffix(" ") || output.isEmpty { return }
            write(inlineCodeDepth > 0 ? collapsed : Self.escape(collapsed))
        }

        /// Ends the current line and leaves a blank line before the next block (inside lists and
        /// quotes, just a new line with the right prefix).
        mutating func startBlock() {
            guard !inCell, !atItemStart else { return }
            let trimmed = output.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
            output = trimmed
            guard !output.isEmpty else { return }
            if !lists.isEmpty || quoteDepth > 0 {
                if !output.hasSuffix("\n") { output += "\n" }
                output += linePrefix
            } else if !output.hasSuffix("\n\n") {
                output += output.hasSuffix("\n") ? "\n" : "\n\n"
            }
        }

        mutating func startListItem() {
            if !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
            output = output.replacingOccurrences(of: "\\n[ >]*$", with: "\n", options: .regularExpression)
            output += linePrefix
            guard var list = lists.popLast() else { return }
            let marker = list.ordered ? "\(list.counter). " : "- "
            list.counter += 1
            lists.append(list)
            output += marker
            atItemStart = true
        }

        mutating func markTodo(checked: Bool) {
            output += checked ? "[x] " : "[ ] "
        }

        /// Characters that would otherwise start Markdown syntax inside running text.
        static func escape(_ text: String) -> String {
            var escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            for character in ["*", "_", "`", "[", "]", "<"] {
                escaped = escaped.replacingOccurrences(of: character, with: "\\" + character)
            }
            // Text that reads like an entity (`&amp;` typed as text) must not turn into a character.
            return escaped.replacingOccurrences(of: "&(?=#?[A-Za-z0-9]+;)", with: "\\\\&", options: .regularExpression)
        }
    }

    // MARK: - Tokenizer

    private enum Token {
        case text(String)
        case open(String, [String: String])
        case close(String)
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)((?:[^>"']|"[^"]*"|'[^']*')*)>|<!--[\s\S]*?-->"#)
    private static let attributePattern = try! NSRegularExpression(pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?"#)

    private static func tokenize(_ html: String) -> [Token] {
        let ns = html as NSString
        var tokens: [Token] = []
        var cursor = 0
        var skipping: String?
        for match in tagPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor, skipping == nil {
                tokens.append(.text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            cursor = match.range.location + match.range.length
            guard match.range(at: 2).location != NSNotFound else { continue } // comment
            let isClose = ns.substring(with: match.range(at: 1)) == "/"
            let name = ns.substring(with: match.range(at: 2)).lowercased()
            if let skipped = skipping {
                if isClose, name == skipped { skipping = nil }
                continue
            }
            if !isClose, name == "script" || name == "style" {
                skipping = name
                continue
            }
            if isClose {
                tokens.append(.close(name))
            } else {
                tokens.append(.open(name, attributes(ns.substring(with: match.range(at: 3)))))
            }
        }
        if cursor < ns.length, skipping == nil {
            tokens.append(.text(ns.substring(from: cursor)))
        }
        return tokens
    }

    private static func attributes(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        let ns = raw as NSString
        for match in attributePattern.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            var value = ""
            for group in 2...4 where match.range(at: group).location != NSNotFound {
                value = decodeEntities(ns.substring(with: match.range(at: group)))
            }
            result[name] = value
        }
        return result
    }

    /// `language-javascript` → `javascript`. Trilium derives the class from the note MIME type:
    /// `language-text-x-python` (text/x-python) → `python`,
    /// `language-application-javascript-env-frontend` (application/javascript;env=frontend) → `javascript`.
    static func language(fromClass value: String) -> String? {
        guard let token = value.split(separator: " ").first(where: { $0.hasPrefix("language-") }) else { return nil }
        let raw = String(token.dropFirst("language-".count))
        var parts = raw.split(separator: "-").map(String.init)
        if parts.count >= 2, ["text", "application"].contains(parts[0]) {
            parts.removeFirst()
            if parts.first == "x", parts.count >= 2 { parts.removeFirst() }
            return parts.first
        }
        return raw == "plaintext" ? nil : raw
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "euro": "€", "copy": "©", "reg": "®", "trade": "™", "times": "×", "deg": "°",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let pattern = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let body = ns.substring(with: match.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#x"), let code = UInt32(body.dropFirst(2), radix: 16) {
                replacement = Unicode.Scalar(code).map(String.init)
            } else if body.hasPrefix("#"), let code = UInt32(body.dropFirst()) {
                replacement = Unicode.Scalar(code).map(String.init)
            } else {
                replacement = namedEntities[body]
            }
            result += replacement ?? ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Trailing spaces, runs of blank lines, non-breaking spaces and empty emphasis — outside code
    /// blocks only, whose whitespace is part of the code.
    private static func tidy(_ markdown: String) -> String {
        var lines: [String] = []
        var inFence = false
        var blankRun = 0
        for rawLine in markdown.replacingOccurrences(of: "\u{00A0}", with: " ").components(separatedBy: "\n") {
            if rawLine.hasPrefix("```") { inFence.toggle() }
            if inFence || rawLine.hasPrefix("```") {
                lines.append(rawLine)
                blankRun = 0
                continue
            }
            let line = rawLine
                .replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\*\\*\\*\\*|~~~~", with: "", options: .regularExpression)
            blankRun = line.isEmpty ? blankRun + 1 : 0
            if blankRun < 2 { lines.append(line) }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
