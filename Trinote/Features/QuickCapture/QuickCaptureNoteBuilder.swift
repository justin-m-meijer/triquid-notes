import Foundation
import WebKit

/// Turns what was typed in Quick capture into Trilium note HTML.
enum QuickCaptureNoteBuilder {
    static let uncheckedPrefix = "☐ "
    static let checkedPrefix = "☑ "

    /// Lines become paragraphs; consecutive lines starting with ☐ or ☑ become one Trilium checklist
    /// (CKEditor todo-list markup, which the app's editor and Trilium both read). Images follow the
    /// text, then a clipped page.
    static func html(body: String, jpegImages: [Data] = [], clip: PageClip? = nil) -> String {
        var parts: [String] = []
        var todoItems: [String] = []

        func flushTodos() {
            guard !todoItems.isEmpty else { return }
            parts.append("<ul class=\"todo-list\">" + todoItems.joined() + "</ul>")
            todoItems.removeAll()
        }

        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(uncheckedPrefix) || line.hasPrefix(checkedPrefix) || line == "☐" || line == "☑" {
                let checked = line.hasPrefix("☑")
                let text = String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                todoItems.append(
                    "<li><label class=\"todo-list__label\"><input type=\"checkbox\" disabled=\"disabled\"\(checked ? " checked=\"checked\"" : "")>"
                        + "<span class=\"todo-list__label__description\">\(escape(text))</span></label></li>"
                )
                continue
            }
            flushTodos()
            if !line.isEmpty {
                parts.append("<p>\(escape(line))</p>")
            }
        }
        flushTodos()

        for image in jpegImages {
            parts.append("<figure class=\"image\"><img src=\"data:image/jpeg;base64,\(image.base64EncodedString())\"></figure>")
        }

        if let clip {
            if let summary = clip.summary, !summary.isEmpty {
                let heading = String(localized: "Summary", comment: "Note summary card title")
                parts.append("<blockquote><p><strong>\(escape(heading))</strong></p><p>\(escape(summary))</p></blockquote>")
            }
            if let web = clip.webClip {
                parts.append(WebClipNoteBuilder.html(for: web))
            } else {
                parts.append("<p><a href=\"\(escape(clip.url.absoluteString))\">\(escape(clip.title.isEmpty ? clip.url.absoluteString : clip.title))</a></p>")
                parts.append(contentsOf: clip.paragraphs.map { "<p>\(escape($0))</p>" })
            }
        }

        return parts.isEmpty ? "<p></p>" : parts.joined()
    }

    private static func escape(_ text: String) -> String {
        MarkdownToNoteHTML.escapeHTML(text)
    }
}

/// The readable part of a web page: its title and paragraph text, without the page's own markup.
struct PageClip: Equatable, Sendable {
    let url: URL
    let title: String
    let paragraphs: [String]
    /// The full readable article from TriClipper.js, when the page could be rendered.
    var webClip: SharedWebClip? = nil
    /// The page showed a cookie or consent wall instead of the article (DPG Media sites such as
    /// nu.nl, AD and Tweakers): the user has to open it and accept first.
    var isBlocked = false
    /// An Apple Intelligence summary in the app's language, put above the article when ready.
    var summary: String? = nil

    /// The article's readable text, for the summary.
    var plainText: String {
        webClip.map { $0.html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) }
            ?? paragraphs.joined(separator: "\n")
    }

    /// Words of the clipped article, shown beside the link so it is clear the page comes along.
    var wordCount: Int {
        let text = webClip.map { $0.html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) }
            ?? paragraphs.joined(separator: " ")
        return text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

enum PageClipper {
    /// The article as Tri Clipper extracts it (headings, lists, images, quotes), falling back to
    /// the page's title and paragraphs as plain text when the page cannot be rendered.
    static func clip(_ url: URL) async throws -> PageClip {
        if let web = await WebPageClipper.clip(url), !web.html.isEmpty {
            return PageClip(url: url, title: web.title, paragraphs: [], webClip: web, isBlocked: isConsentWall(web, requested: url))
        }
        return try await plainClip(url)
    }

    /// A clip that landed on another site (a consent page the request was redirected to) or holds
    /// next to no text is not the article.
    static func isConsentWall(_ web: SharedWebClip, requested: URL) -> Bool {
        func site(_ host: String?) -> String {
            let parts = (host ?? "").lowercased().split(separator: ".")
            return parts.suffix(2).joined(separator: ".")
        }
        if let landed = URL(string: web.url), site(landed.host()) != site(requested.host()) { return true }
        let text = web.html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces).count < 200
    }

    static func plainClip(_ url: URL) async throws -> PageClip {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (iPhone) TriNote", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return parse(html: html, url: url)
    }

    /// Title from `<title>` (or `og:title`); paragraphs from `<article>` or `<main>` when present,
    /// otherwise the whole page. Very short paragraphs (menus, captions) are left out.
    static func parse(html: String, url: URL, maxParagraphs: Int = 40) -> PageClip {
        let title = firstMatch(#"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']*)["']"#, in: html)
            ?? firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html)
            ?? ""
        let scope = firstMatch(#"<article[^>]*>(.*?)</article>"#, in: html)
            ?? firstMatch(#"<main[^>]*>(.*?)</main>"#, in: html)
            ?? html
        let withoutCode = scope.replacingOccurrences(of: #"<(script|style)[^>]*>.*?</\1>"#, with: "", options: [.regularExpression, .caseInsensitive])
        var paragraphs: [String] = []
        for raw in allMatches(#"<p[^>]*>(.*?)</p>"#, in: withoutCode) {
            let text = plainText(raw)
            if text.count >= 40 { paragraphs.append(text) }
            if paragraphs.count == maxParagraphs { break }
        }
        return PageClip(url: url, title: plainText(title), paragraphs: paragraphs)
    }

    private static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        text = text.replacingOccurrences(of: #"&#(\d+);"#, with: "", options: .regularExpression)
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        allMatches(pattern, in: text).first
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }
}

/// Loads a page in an offscreen web view and runs TriClipper.js on it, as Safari does for the
/// share extension, so a link clipped in the app keeps the same readable article.
@MainActor
final class WebPageClipper: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Bool, Never>?

    private override init() {
        let configuration = WKWebViewConfiguration()
        // Persistent, so a cookie notice accepted once in the clip browser lets later clips through.
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    /// Runs TriClipper.js on the page a web view shows (also the visible clip browser).
    static func extract(from webView: WKWebView) async -> SharedWebClip? {
        guard let scriptURL = Bundle.main.url(forResource: "TriClipper", withExtension: "js"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let result = try? await webView.evaluateJavaScript(script + "\n;TriClipperExtract();") as? [String: Any] else {
            return nil
        }
        return SharedWebClip(dictionary: result)
    }

    static func clip(_ url: URL, timeout: Duration = .seconds(20)) async -> SharedWebClip? {
        let clipper = WebPageClipper()
        // Gives up after `timeout`: stopping the load resolves `load(_:)` with false.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            clipper.webView.stopLoading()
            clipper.finish(false)
        }
        // Cancelling the capture stops the page load at once instead of waiting for the watchdog.
        let loaded = await withTaskCancellationHandler {
            await clipper.load(url)
        } onCancel: {
            Task { @MainActor in
                clipper.webView.stopLoading()
                clipper.finish(false)
            }
        }
        watchdog.cancel()
        guard loaded else {
            clipper.webView.stopLoading()
            clipper.finish(false)
            return nil
        }
        return await extract(from: clipper.webView)
    }

    private func load(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url, timeoutInterval: 20))
        }
    }

    private func finish(_ success: Bool) {
        continuation?.resume(returning: success)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
}
