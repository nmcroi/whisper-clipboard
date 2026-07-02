import SwiftUI

// MARK: - Palette

extension Color {
    /// Creates a color from a 6-digit hex string (e.g. `"042648"` or `"#042648"`).
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

/// The NightStory brand palette.
enum NightStory {
    static let marine = Color(hex: "042648")
    static let terra = Color(hex: "d97757")
    static let bg = Color(hex: "faf9f5")
    static let card = Color(hex: "fffdf9")
    static let sand = Color(hex: "e3dacc")
    static let softblue = Color(hex: "6a9bcc")
    static let teal = Color(hex: "03739a")
    static let terradark = Color(hex: "b05638")
    static let warm = Color(hex: "eba882")
    static let lightterra = Color(hex: "fde1c6")
    static let sage = Color(hex: "b2c6bf")
    static let lavender = Color(hex: "d0cddb")
}

// MARK: - Design tokens

enum NightStoryMetrics {
    static let cornerRadius: CGFloat = 8
    static let cardCornerRadius: CGFloat = 12
}

extension View {
    /// Subtle card-level shadow token.
    func nightStoryShadowSmall() -> some View {
        shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
    }

    /// Elevated shadow token (hover / prominent surfaces).
    func nightStoryShadowMedium() -> some View {
        shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Typography

/// Font helpers. Uses bundled Merriweather (headings) and Inter (body).
/// If the fonts are unavailable, falls back to the system serif / sans design.
enum NightStoryFont {
    /// Whether the custom brand fonts registered successfully.
    static let hasMerriweather = fontFamilyIsAvailable("Merriweather")
    static let hasInter = fontFamilyIsAvailable("Inter")

    /// Serif heading font (Merriweather), falling back to the system serif.
    static func heading(size: CGFloat, weight: Font.Weight = .bold) -> Font {
        if hasMerriweather {
            return .custom("Merriweather", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    /// Sans body font (Inter), falling back to the system sans.
    static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if hasInter {
            return .custom("Inter", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .default)
    }

    private static func fontFamilyIsAvailable(_ family: String) -> Bool {
        #if canImport(AppKit)
        return NSFontManager.shared.availableFontFamilies.contains(family)
        #else
        return false
        #endif
    }
}
