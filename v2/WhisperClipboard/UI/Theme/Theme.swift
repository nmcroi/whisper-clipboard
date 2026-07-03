import SwiftUI

// MARK: - Hex helper

extension Color {
    /// Creates a color from a 6-digit hex string (e.g. `"0E0E10"` or `"#0E0E10"`).
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// The v2 design language: dark, sleek, tight. Near-black surfaces, white
/// primary text, gray secondary, **yellow** as the primary accent and **red**
/// as the secondary/recording accent. No blue tones anywhere.
///
/// Think Linear / Raycast polish: subtle 1px borders over heavy shadows,
/// 8/12px radii, tight spacing.
enum Theme {

    // MARK: Surfaces

    /// App window background (near-black).
    static let window = Color(hex: "0E0E10")
    /// Card / raised surface.
    static let surface = Color(hex: "17171A")
    /// Slightly lifted surface (hover, selected rows, input fields).
    static let surfaceHover = Color(hex: "1F1F23")
    /// Subtle 1px border.
    static let border = Color(hex: "26262B")
    /// Brighter border for hover / focus.
    static let borderStrong = Color(hex: "35353C")

    // MARK: Text

    /// Primary text (white).
    static let text = Color(hex: "F5F5F7")
    /// Secondary / muted text.
    static let textSecondary = Color(hex: "9A9AA2")
    /// Tertiary / faint text (timecodes, captions).
    static let textTertiary = Color(hex: "6A6A72")

    // MARK: Accents

    /// Primary accent — actions, highlights, active states, the brand period.
    static let accent = Color(hex: "FFD60A")
    /// A dimmer yellow for large fills / hovers.
    static let accentSoft = Color(hex: "C9A800")
    /// Secondary accent — recording state, destructive actions.
    static let danger = Color(hex: "FF453A")
    /// A dimmer red for backgrounds.
    static let dangerSoft = Color(hex: "3A1A18")

    /// Foreground color to place on top of the yellow accent (dark, for contrast).
    static let onAccent = Color(hex: "0E0E10")

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
        (
            Text("Whisper Clipboard")
                .foregroundStyle(Theme.text)
            + Text(".")
                .foregroundStyle(Theme.accent)
        )
        .font(ThemeFont.wordmark(size, weight: .bold))
    }
}
