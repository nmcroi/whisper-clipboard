import Core
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Appearance mapping

extension AppSettings.AppearanceMode {
    /// The SwiftUI colour scheme to force via `.preferredColorScheme(_:)`.
    /// `.system` returns `nil` so the app follows macOS.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    #if canImport(AppKit)
    /// The `NSAppearance` to pin on AppKit windows/panels (HUD, caption overlay,
    /// status-item menu) so their `Theme` dynamic colors resolve to the chosen
    /// palette. `.system` returns `nil` → follow the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
    #endif
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
    /// and `darkHex` under a dark appearance. Backed by a dynamic-provider
    /// `NSColor` so a single token follows the active window/panel appearance —
    /// existing `Theme.xxx` call sites don't change; they just render correctly
    /// per the current colour scheme. Falls back to a static color off AppKit.
    init(lightHex: String, darkHex: String) {
        #if canImport(AppKit)
        let light = Color.nsColor(hex: lightHex)
        let dark = Color.nsColor(hex: darkHex)
        let dynamic = NSColor(name: nil) { appearance in
            // `.darkAqua` (and its vibrant/high-contrast variants) → dark palette;
            // everything else (aqua/light) → light palette.
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
        self.init(nsColor: dynamic)
        #else
        self.init(hex: darkHex)
        #endif
    }

    #if canImport(AppKit)
    /// A calibrated-sRGB `NSColor` from a 6-digit hex string.
    fileprivate static func nsColor(hex: String) -> NSColor {
        let (r, g, b) = rgbComponents(hex: hex)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
    #endif
}

/// The v2 design language: sleek, tight, **yellow** as the primary accent and
/// **red** as the secondary/recording accent. No blue tones anywhere.
///
/// Every token is **appearance-aware**: it resolves to a dark value under a dark
/// appearance and a light value under a light appearance (see
/// ``SwiftUI/Color/init(lightHex:darkHex:)``). The dark palette — near-black
/// surfaces, white text — is the signature look and the default; the light
/// palette — near-white surfaces, black text, the same yellow/red accents —
/// mirrors it for users who opt in via the "Thema" picker.
///
/// Think Linear / Raycast polish: subtle 1px borders over heavy shadows,
/// 8/12px radii, tight spacing.
enum Theme {

    // MARK: Surfaces

    /// App window background (near-black / near-white).
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
    /// level bars, the stop ring. Bright yellow in both modes (black text on it
    /// reads great on both a dark and a white surface).
    static let accent = Color(lightHex: "FFD60A", darkHex: "FFD60A")
    /// Accent for **text / thin strokes / the wordmark period**. Bright yellow on
    /// dark, but a darker readable amber on white (bright yellow text on white is
    /// unreadable). Use this wherever the accent appears AS text or a hairline.
    static let accentText = Color(lightHex: "B58900", darkHex: "FFD60A")
    /// A dimmer yellow for large fills / hovers.
    static let accentSoft = Color(lightHex: "C9A800", darkHex: "C9A800")
    /// Secondary accent — recording state, destructive actions. A touch deeper in
    /// light mode for contrast on white.
    static let danger = Color(lightHex: "E5342A", darkHex: "FF453A")
    /// A dimmer red for backgrounds.
    static let dangerSoft = Color(lightHex: "FBE4E2", darkHex: "3A1A18")

    /// Foreground color to place on top of the yellow accent fill (always dark,
    /// for contrast against bright yellow in both modes).
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
        #if canImport(AppKit)
        return NSFontManager.shared.availableFontFamilies.contains(family)
        #else
        return false
        #endif
    }
}

// MARK: - Reusable view helpers

extension View {
    /// A standard dark card surface: fill, 1px border, rounded corners.
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
    /// accent colour. Built with Text interpolation — the `Text + Text`
    /// operator is deprecated on macOS 26.
    static func accentDotted(_ title: String) -> Text {
        Text("\(Text(title).foregroundStyle(Theme.text))\(Text(".").foregroundStyle(Theme.accentText))")
    }
}
