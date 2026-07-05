import Core
import SwiftUI
import UIKit

// MARK: - Appearance mapping

extension AppSettings.AppearanceMode {
    /// The SwiftUI colour scheme to force via `.preferredColorScheme(_:)`.
    /// `.system` returns `nil` so the app follows iOS.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    /// Dutch label for the "Thema" picker.
    var label: String {
        switch self {
        case .system: return "Systeem"
        case .dark: return "Donker"
        case .light: return "Licht"
        }
    }
}

// MARK: - Hex helper

extension Color {
    /// Creates a color from a 6-digit hex string (e.g. `"0E0E10"` or `"#0E0E10"`).
    init(hex: String) {
        let (r, g, b) = Color.rgbComponents(hex: hex)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// Parses a 6-digit hex string into sRGB components in `0...1`.
    fileprivate static func rgbComponents(hex: String) -> (Double, Double, Double) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        return (r, g, b)
    }

    /// A **dynamic** color that resolves to `lightHex` under a light appearance
    /// and `darkHex` under a dark appearance. Backed by a `UIColor` dynamic
    /// provider so a single token follows the active trait collection — call
    /// sites use the same `Theme.xxx` tokens as the mac app, so views read
    /// identically across platforms.
    init(lightHex: String, darkHex: String) {
        let light = Color.uiColor(hex: lightHex)
        let dark = Color.uiColor(hex: darkHex)
        let dynamic = UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
        self.init(uiColor: dynamic)
    }

    /// An sRGB `UIColor` from a 6-digit hex string.
    fileprivate static func uiColor(hex: String) -> UIColor {
        let (r, g, b) = rgbComponents(hex: hex)
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}

/// The v2 design language ported to iOS: sleek, tight, **yellow** as the primary
/// accent and **red** as the secondary/recording accent. Hex values are
/// byte-identical to the mac `Theme` so both apps share one visual identity.
///
/// Every token is **appearance-aware** via ``SwiftUI/Color/init(lightHex:darkHex:)``.
/// Dark is the signature look and the default; light mirrors it for opt-in users.
enum Theme {

    // MARK: Surfaces

    /// App background (near-black / near-white).
    static let window = Color(lightHex: "FBFBFA", darkHex: "0E0E10")
    /// Card / raised surface.
    static let surface = Color(lightHex: "FFFFFF", darkHex: "17171A")
    /// Slightly lifted surface (hover, selected rows, input fields).
    static let surfaceHover = Color(lightHex: "F1F1EF", darkHex: "1F1F23")
    /// Subtle 1px border.
    static let border = Color(lightHex: "E3E3DF", darkHex: "26262B")
    /// Brighter border for hover / focus.
    static let borderStrong = Color(lightHex: "D0D0CB", darkHex: "35353C")

    // MARK: Text

    /// Primary text (near-white / near-black).
    static let text = Color(lightHex: "111114", darkHex: "F5F5F7")
    /// Secondary / muted text.
    static let textSecondary = Color(lightHex: "57575C", darkHex: "9A9AA2")
    /// Tertiary / faint text (timecodes, captions).
    static let textTertiary = Color(lightHex: "8A8A90", darkHex: "6A6A72")

    // MARK: Accents

    /// Primary accent for **fills / highlights** — the yellow "Kopieer" button,
    /// level bars, the record ring.
    static let accent = Color(lightHex: "FFD60A", darkHex: "FFD60A")
    /// Accent for **text / thin strokes / the wordmark period**. A darker amber on
    /// white so accent-as-text stays readable.
    static let accentText = Color(lightHex: "B58900", darkHex: "FFD60A")
    /// A dimmer yellow for large fills / hovers.
    static let accentSoft = Color(lightHex: "C9A800", darkHex: "C9A800")
    /// Secondary accent — recording state, destructive actions.
    static let danger = Color(lightHex: "E5342A", darkHex: "FF453A")
    /// A dimmer red for backgrounds.
    static let dangerSoft = Color(lightHex: "FBE4E2", darkHex: "3A1A18")

    /// Foreground color to place on top of the yellow accent fill (always dark).
    static let onAccent = Color(lightHex: "0E0E10", darkHex: "0E0E10")

    // MARK: Metrics

    enum Metrics {
        static let radius: CGFloat = 8
        static let cardRadius: CGFloat = 12
        static let hairline: CGFloat = 1
    }
}

// MARK: - Typography

/// Font helpers. UI uses bundled Inter throughout; Merriweather is available for
/// the app-title wordmark only. Falls back to the system sans / serif when the
/// bundled families are unavailable.
enum ThemeFont {
    static let hasInter = fontFamilyIsAvailable("Inter")
    static let hasMerriweather = fontFamilyIsAvailable("Merriweather")

    /// Inter for all UI text.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if hasInter {
            return .custom("Inter", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .default)
    }

    /// Merriweather for the app-title wordmark only; falls back to Inter/system.
    static func wordmark(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        if hasMerriweather {
            return .custom("Merriweather", size: size).weight(weight)
        }
        return ui(size, weight: weight)
    }

    private static func fontFamilyIsAvailable(_ family: String) -> Bool {
        // UIFont exposes families with the bundled PostScript family name once the
        // UIAppFonts entries are registered at launch.
        UIFont.familyNames.contains(family)
    }
}

// MARK: - Reusable view helpers

extension View {
    /// A standard card surface: fill, 1px border, rounded corners.
    func themeCard(radius: CGFloat = Theme.Metrics.cardRadius, border: Color = Theme.border) -> some View {
        self
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border, lineWidth: Theme.Metrics.hairline)
            )
    }
}

/// The app-title wordmark: "Whisper Clipboard" with a yellow period.
struct Wordmark: View {
    var size: CGFloat = 26

    var body: some View {
        Text.accentDotted("Whisper Clip")
            .font(ThemeFont.wordmark(size, weight: .bold))
    }
}

extension Text {
    /// The brand heading pattern: "<title>." with the trailing period in the
    /// accent colour.
    static func accentDotted(_ title: String) -> Text {
        Text("\(Text(title).foregroundStyle(Theme.text))\(Text(".").foregroundStyle(Theme.accentText))")
    }
}
