import SwiftUI
import WebKit

/// Shows a page whose cookie or consent wall kept the offscreen clipper out: the user accepts it
/// (or scrolls to the part they want) and clips what the page shows. The cookies stay, so the
/// next link from that site clips straight away.
struct ClipBrowserSheet: View {
    let url: URL
    let onClip: (PageClip) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var page = ClipBrowserPage()
    @State private var isClipping = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ClipWebView(webView: page.webView, url: url)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Text(String(localized: "Accept the site's cookie notice if it shows one, then tap Clip.", comment: "Clip browser: hint above a page behind a consent wall"))
                        .font(.footnote)
                        .foregroundStyle(Color.trinoteTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
                .navigationTitle(url.host() ?? url.absoluteString)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isClipping {
                            ProgressView()
                        } else {
                            Button {
                                Task { await clip() }
                            } label: {
                                Label(String(localized: "Clip", comment: "Clip browser: clip the page shown"), systemImage: "scissors")
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
                }
                .alert(
                    String(localized: "Nothing to Clip", comment: "Clip browser: extraction failed title"),
                    isPresented: $failed,
                    actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
                    message: { Text(String(localized: "The page has no readable article yet. Accept the cookie notice or wait until the page has loaded.", comment: "Clip browser: extraction failed message")) }
                )
        }
        // Room to read the page on iPad, where a form sheet showed a narrow strip.
        .presentationSizing(.page)
    }

    private func clip() async {
        isClipping = true
        defer { isClipping = false }
        guard let web = await WebPageClipper.extract(from: page.webView), !web.html.isEmpty,
              !PageClipper.isConsentWall(web, requested: url) else {
            failed = true
            return
        }
        onClip(PageClip(url: url, title: web.title, paragraphs: [], webClip: web))
        dismiss()
    }
}

/// Keeps one web view for the sheet's lifetime (SwiftUI may rebuild the representable).
@MainActor
final class ClipBrowserPage {
    let webView: WKWebView

    init() {
        let configuration = WKWebViewConfiguration()
        // The same store as the offscreen clipper, so an accepted notice counts for both.
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
    }
}

private struct ClipWebView: UIViewRepresentable {
    let webView: WKWebView
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        if webView.url == nil { webView.load(URLRequest(url: url)) }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
