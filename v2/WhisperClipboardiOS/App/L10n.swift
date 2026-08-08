import Foundation

/// Resolves programmatically composed UI strings against the language selected
/// inside WhisperClip. SwiftUI's environment locale handles static `Text`
/// values, but Foundation otherwise keeps following the device language.
enum L10n {
    static func string(_ key: String.LocalizationValue, locale: Locale) -> String {
        let bundle = bundle(for: locale)
        return String(localized: key, bundle: bundle, locale: locale)
    }

    /// Variant voor een stabiele catalogussleutel die uit een taalneutrale
    /// toestand komt en daarom niet als compile-time `LocalizationValue` bestaat.
    static func string(dynamicKey key: String, locale: Locale) -> String {
        bundle(for: locale).localizedString(forKey: key, value: key, table: nil)
    }

    private static func bundle(for locale: Locale) -> Bundle {
        let identifier = locale.identifier.lowercased()
        let code: String
        if identifier.hasPrefix("en") {
            code = "en"
        } else if identifier.hasPrefix("de") {
            code = "de"
        } else {
            code = "nl"
        }

        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return .main
        }
        return bundle
    }
}

/// Eén opmaak voor opnameduur, gedeeld door Geschiedenis-lijst en -detail.
///
/// De vorm `m:ss` zonder eenheid was niet te onderscheiden van een tijdstip:
/// `2:21` werd gelezen als 2 uur 21 (bevinding 2026-08-02). Daarom draagt elke
/// vorm boven een minuut nu een letter.
///
/// - onder een minuut: `42 s`
/// - onder een uur: `2:32 m`
/// - een uur en langer: `1:04:06 u`
enum DurationText {
    static func string(seconds: Double, locale: Locale) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 {
            return String(
                format: L10n.string("%lld s", locale: locale),
                locale: locale,
                total
            )
        }
        if total < 3600 {
            return String(
                format: L10n.string("%@ m", locale: locale),
                locale: locale,
                String(format: "%d:%02d", total / 60, total % 60)
            )
        }
        return String(
            format: L10n.string("%@ u", locale: locale),
            locale: locale,
            String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        )
    }
}
