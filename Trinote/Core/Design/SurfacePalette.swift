import SwiftUI
import UIKit

/// Backgrounds as one family of tinted neutrals: every surface takes the accent's hue at a very low
/// chroma and differs only in lightness (sidebar darkest, then the note column, cards, fills). Worked
/// out in OKLCH, a perceptual color space, so equal steps look equal and a red tint stays red
/// instead of turning brown, as mixing in RGB did. Graphite gives pure grays.
enum SurfacePalette {
    enum Surface {
        case sidebar, sidebarField, sidebarSelection
        case ground, canvas, card, fill, placeholder, separator
    }

    /// (lightness, chroma) per surface. Chroma is scaled to zero for graphite.
    private static func lc(_ surface: Surface, dark: Bool) -> (Double, Double) {
        if dark {
            switch surface {
            case .sidebar: return (0.175, 0.012)
            case .sidebarField: return (0.215, 0.014)
            case .sidebarSelection: return (0.245, 0.022)
            case .ground: return (0.210, 0.009)
            case .canvas: return (0.210, 0.009)
            case .card: return (0.250, 0.011)
            case .fill: return (0.270, 0.012)
            case .placeholder: return (0.250, 0.011)
            case .separator: return (0.290, 0.011)
            }
        } else {
            switch surface {
            // The sidebar stays dark in light mode, as in the v2 design, in the same hue.
            case .sidebar: return (0.255, 0.022)
            case .sidebarField: return (0.295, 0.024)
            case .sidebarSelection: return (0.330, 0.034)
            case .ground: return (0.984, 0.004)
            case .canvas: return (0.995, 0.002)
            case .card: return (1.000, 0.000)
            case .fill: return (0.954, 0.008)
            case .placeholder: return (0.930, 0.008)
            case .separator: return (0.925, 0.007)
            }
        }
    }

    static func uiColor(_ surface: Surface, accent: AppAccent, dark: Bool) -> UIColor {
        let (l, c) = lc(surface, dark: dark)
        let hue = accentHue(accent)
        let rgb = oklchToSRGB(l: l, c: accent == .graphite ? 0 : c, h: hue)
        return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    /// Follows light/dark and the accent stored in settings.
    static func dynamic(_ surface: Surface) -> UIColor {
        UIColor { traits in
            uiColor(surface, accent: currentAccent, dark: traits.userInterfaceStyle == .dark)
        }
    }

    static var currentAccent: AppAccent {
        let defaults = UserDefaults.standard
        return AppAccent.resolve(
            stored: defaults.string(forKey: AppAccent.storageKey) ?? "",
            legacyTheme: defaults.string(forKey: "colorTheme") ?? ""
        )
    }

    /// "#RRGGBB" for CSS (the note editor's canvas).
    static func hex(_ surface: Surface, accent: AppAccent, dark: Bool) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor(surface, accent: accent, dark: dark).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    // MARK: - OKLCH

    /// The accent's hue angle in OKLCH (from its light-mode value).
    static func accentHue(_ accent: AppAccent) -> Double {
        let rgb = hexToRGB(accent.lightHex)
        let lab = sRGBToOklab(rgb)
        var hue = atan2(lab.2, lab.1) * 180 / .pi
        if hue < 0 { hue += 360 }
        return hue
    }

    private static func hexToRGB(_ hex: String) -> (Double, Double, Double) {
        let digits = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    private static func toLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private static func toGamma(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    private static func sRGBToOklab(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let r = toLinear(rgb.0), g = toLinear(rgb.1), b = toLinear(rgb.2)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    static func oklchToSRGB(l: Double, c: Double, h: Double) -> (Double, Double, Double) {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        return (
            toGamma(4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S),
            toGamma(-1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S),
            toGamma(-0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S)
        )
    }
}
