import SwiftUI

/// The typeface choice (Settings › Theme & accent › Font). It sets the headings (notebook and note
/// titles, the sidebar's name, large titles) and the body text of the app's own screens.
enum AppFont: String, CaseIterable, Identifiable {
    /// The v2 design: New York headings over SF body text.
    case design
    case newYork
    case sfPro
    case rounded
    case mono

    static let storageKey = "appFont"
    static let `default`: AppFont = .design

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .design: String(localized: "Classic", comment: "Font choice: serif headings, sans-serif text")
        case .newYork: String(localized: "New York", comment: "Font choice: serif throughout")
        case .sfPro: String(localized: "SF Pro", comment: "Font choice: system sans-serif throughout")
        case .rounded: String(localized: "Rounded", comment: "Font choice: SF Rounded")
        case .mono: String(localized: "Mono", comment: "Font choice: SF Mono")
        }
    }

    var localizedSummary: String {
        switch self {
        case .design: String(localized: "Serif headings, clean text", comment: "Font choice description")
        case .newYork: String(localized: "Serif everywhere, like a book", comment: "Font choice description")
        case .sfPro: String(localized: "The system font everywhere", comment: "Font choice description")
        case .rounded: String(localized: "Soft, rounded letters", comment: "Font choice description")
        case .mono: String(localized: "Fixed width, like a terminal", comment: "Font choice description")
        }
    }

    /// Headings.
    var displayDesign: Font.Design {
        switch self {
        case .design, .newYork: .serif
        case .sfPro: .default
        case .rounded: .rounded
        case .mono: .monospaced
        }
    }

    /// Everything else on the app's own screens.
    var bodyDesign: Font.Design {
        switch self {
        case .design, .sfPro: .default
        case .newYork: .serif
        case .rounded: .rounded
        case .mono: .monospaced
        }
    }

    /// The same choice for note pages (reader and editor), as a CSS `font-family`.
    var cssFontFamily: String { Self.cssFontFamily(for: bodyDesign) }

    static func cssFontFamily(for design: Font.Design) -> String {
        switch design {
        case .serif: #""New York", ui-serif, Georgia, serif"#
        case .rounded: #"ui-rounded, "SF Pro Rounded", -apple-system, sans-serif"#
        case .monospaced: #"ui-monospace, "SF Mono", Menlo, monospace"#
        default: #"-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif"#
        }
    }

    static var current: AppFont {
        AppFont(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .default
    }
}

extension EnvironmentValues {
    /// The chosen typeface; set at the app's root from `AppFont.storageKey`.
    @Entry var appFont: AppFont = .default
}

extension Font {
    /// A heading in the chosen typeface (`AppFont.displayDesign`). Pair it with `.fontDesign` (see
    /// `headingFont`): an app-wide `.fontDesign` otherwise overrides the design given here.
    static func trinoteHeading(_ size: CGFloat, weight: Font.Weight = .bold, font: AppFont) -> Font {
        .system(size: size, weight: weight, design: font.displayDesign)
    }
}

private struct HeadingFont: ViewModifier {
    @Environment(\.appFont) private var appFont
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: weight))
            .fontDesign(appFont.displayDesign)
    }
}

extension View {
    /// A heading in the chosen typeface; overrides the body design set at the app's root.
    func headingFont(_ size: CGFloat, weight: Font.Weight = .bold) -> some View {
        modifier(HeadingFont(size: size, weight: weight))
    }
}

/// A heading that wraps like a sentence: SwiftUI's Text won't leave one word alone on the last
/// line and pushes the word before it down too ("Bloempotten / uit Sonsbeek" with room to spare
/// on the first line, TestFlight feedback). UILabel lets that rule be switched off.
struct WrappingHeading: View {
    let text: String
    let size: CGFloat
    var weight: UIFont.Weight = .bold
    let color: Color
    @Environment(\.appFont) private var appFont

    var body: some View {
        WrappingHeadingLabel(text: text, size: size, weight: weight, color: color)
            .alignmentGuide(.firstTextBaseline) { _ in
                WrappingHeadingLabel.font(size: size, weight: weight, design: appFont.displayDesign).ascender
            }
            .accessibilityElement()
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}

struct WrappingHeadingLabel: UIViewRepresentable {
    let text: String
    let size: CGFloat
    var weight: UIFont.Weight = .bold
    let color: Color
    @Environment(\.appFont) private var appFont

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.lineBreakStrategy = []
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        label.textColor = UIColor(color)
        label.font = Self.font(size: size, weight: weight, design: appFont.displayDesign)
    }

    /// The heading font as UIKit sees it; also where the first line's baseline sits, so the note
    /// icon beside it can line up (`firstTextBaseline`).
    static func font(size: CGFloat, weight: UIFont.Weight, design: Font.Design) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        let system: UIFontDescriptor.SystemDesign? = switch design {
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        default: nil
        }
        guard let system, let descriptor = font.fontDescriptor.withDesign(system) else { return font }
        return UIFont(descriptor: descriptor, size: size)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: proposal.width ?? fitted.width, height: fitted.height)
    }
}
