import SwiftUI
import UIKit

/// Colors of the TriNote v2 redesign (canvas "TriNote UX redesign": sidebar · list · editor), each
/// with a light and a dark value. Use these instead of system grouped colors so the whole app shares
/// one palette.
extension Color {
    /// Note lists and settings: a warm off-white, a soft graphite in dark mode.
    static let trinoteGround = Color(uiColor: SurfacePalette.dynamic(.ground))
    /// Grouped cards (settings, sheets).
    static let trinoteCard = Color(uiColor: SurfacePalette.dynamic(.card))
    /// Chips, table headers, icon tiles and other quiet fills.
    static let trinoteFill = Color(uiColor: SurfacePalette.dynamic(.fill))
    /// Image placeholders and thumbnails that are still loading.
    static let trinotePlaceholder = Color(uiColor: SurfacePalette.dynamic(.placeholder))
    static let trinoteTextPrimary = Color(light: "#1D1D1F", dark: "#ECEBE7")
    static let trinoteTextSecondary = Color(light: "#6E6C68", dark: "#A3A19C")
    /// Dates, counts and other tertiary text.
    static let trinoteTextTertiary = Color(light: "#8A8884", dark: "#8C8A85")
    /// Note-type glyphs in lists.
    static let trinoteIcon = Color(light: "#6E6C68", dark: "#A3A19C")
    static let trinoteSeparator = Color(uiColor: SurfacePalette.dynamic(.separator))
    static let trinoteSyncOK = Color(light: "#2F8A4E", dark: "#4CC27A")
    static let trinoteDestructive = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemRed : UIColor(trinoteHex: "#C4312B")
    })

    /// One fixed color, the same in both appearances.
    init(fixed hex: String) {
        self.init(light: hex, dark: hex)
    }

    /// A color that follows the current light/dark appearance.
    init(light: String, dark: String) {
        self.init(uiColor: UIColor { traits in
            UIColor(trinoteHex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

/// The user-selectable accent (v2 Appearance artboard). Stored under `AppAccent.storageKey` and
/// applied app-wide with `.tint()`.
enum AppAccent: String, CaseIterable, Identifiable {
    case lagoon, red, blue, indigo, purple, amber, orange, graphite

    static let storageKey = "appAccent"
    static let `default`: AppAccent = .lagoon

    var id: String { rawValue }

    private var values: (light: String, dark: String, lightTint: String, darkTint: String) {
        switch self {
        case .lagoon: ("#1E6A73", "#6BC1C9", "#E3F0F1", "#1B3134")
        case .red: ("#C8463D", "#E8786F", "#F8E6E4", "#3A2321")
        case .blue: ("#3A5BA0", "#8FA8E0", "#E8EDF7", "#1F2A40")
        case .indigo: ("#4B4AA8", "#A3A2EC", "#ECECF8", "#262640")
        case .purple: ("#6B4FA0", "#B39DE0", "#F0EBF7", "#2E2640")
        case .amber: ("#A6620F", "#E8A34E", "#F7EEE2", "#3A2D1C")
        case .orange: ("#B4532A", "#E8946B", "#F8EBE4", "#3D2A20")
        case .graphite: ("#4A4A4E", "#C2C2C8", "#EDEDEE", "#2E2E31")
        }
    }

    var lightHex: String { values.light }
    var darkHex: String { values.dark }
    var tintLightHex: String { values.lightTint }
    var tintDarkHex: String { values.darkTint }

    var color: Color { Color(light: lightHex, dark: darkHex) }
    /// Selected rows and chips.
    var tint: Color { Color(light: tintLightHex, dark: tintDarkHex) }

    var localizedTitle: String {
        switch self {
        case .lagoon: String(localized: "Lagoon", comment: "Accent color name")
        case .red: String(localized: "Red", comment: "Accent color name")
        case .blue: String(localized: "Blue", comment: "Accent color name")
        case .indigo: String(localized: "Indigo", comment: "Accent color name")
        case .purple: String(localized: "Purple", comment: "Accent color name")
        case .amber: String(localized: "Amber", comment: "Accent color name")
        case .orange: String(localized: "Orange", comment: "Accent color name")
        case .graphite: String(localized: "Graphite", comment: "Accent color name")
        }
    }

    /// The stored accent; v1 accents that are gone map to their nearest v2 color, and someone who
    /// never chose one gets the closest match to the color theme they used before the redesigns.
    static func resolve(stored: String, legacyTheme: String) -> AppAccent {
        if let accent = AppAccent(rawValue: stored) { return accent }
        switch stored {
        case "teal": return .lagoon
        case "pink": return .red
        case "olive": return .amber
        default: break
        }
        switch ColorTheme(rawValue: legacyTheme) {
        case .ocean: return .blue
        case .forest: return .lagoon
        case .sunset: return .orange
        case .lavender: return .purple
        case .slate: return .graphite
        case .rose: return .red
        case .default, nil: return .default
        }
    }
}

/// The sidebar is dark in both themes: deep petrol in light mode, near-black in dark mode. Its
/// controls render in dark mode, so its colors are chosen from the app's real appearance.
struct SidebarPalette {
    let background: Color
    let field: Color
    let selection: Color
    let text: Color
    let secondary: Color
    let icon: Color

    /// A dark sidebar tinted with the accent, so it matches whichever accent is chosen (a fixed
    /// teal clashed with red or amber). In dark mode it stays close to the note column's gray, just
    /// darker; in light mode it is a deeper, more tinted dark, as in the v2 design.
    init(appearance: ColorScheme, accent: AppAccent = .lagoon) {
        let dark = appearance == .dark
        let tint = dark ? accent.darkHex : accent.lightHex
        func mix(_ base: String, _ amount: Double) -> Color { Color(fixed: Self.blend(base, tint, amount)) }
        func surface(_ s: SurfacePalette.Surface) -> Color { Color(uiColor: SurfacePalette.uiColor(s, accent: accent, dark: dark)) }
        background = surface(.sidebar)
        field = surface(.sidebarField)
        selection = surface(.sidebarSelection)
        text = Color(fixed: "#ECEBE7")
        secondary = dark ? mix("#A3A19C", 0.08) : mix("#A8A6A1", 0.12)
        icon = dark ? mix("#B5B3AE", 0.10) : mix("#BAB8B3", 0.14)
    }

    /// `base` with `amount` (0…1) of `tint` mixed in, as a hex color.
    static func blend(_ base: String, _ tint: String, _ amount: Double) -> String {
        func rgb(_ hex: String) -> [Double] {
            let digits = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            var value: UInt64 = 0
            Scanner(string: digits).scanHexInt64(&value)
            return [Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF)]
        }
        let mixed = zip(rgb(base), rgb(tint)).map { Int(($0 * (1 - amount) + $1 * amount).rounded()) }
        return String(format: "#%02X%02X%02X", mixed[0], mixed[1], mixed[2])
    }
}

extension ShapeStyle where Self == Color {
    /// Foreground on a filled accent control: white in light mode, a dark ink in dark mode (§1).
    static var trinoteOnAccent: Color { Color(light: "#FFFFFF", dark: "#08292D") }
}

private extension UIColor {
    convenience init(trinoteHex hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
