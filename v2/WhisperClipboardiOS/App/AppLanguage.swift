import Foundation

/// Taal van de interface. `system` volgt uitsluitend de drie ondersteunde
/// talen en valt voor alle overige systeeminstellingen terug op Nederlands.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case dutch = "nl"
    case english = "en"
    case german = "de"

    var id: String { rawValue }

    func pickerLabel(in interfaceLanguage: AppLanguage) -> String {
        switch self {
        case .system: L10n.string( "Systeem", locale: interfaceLanguage.locale)
        case .dutch: "Nederlands"
        case .english: "English"
        case .german: "Deutsch"
        }
    }

    var resolvedCode: String {
        guard self == .system else { return rawValue }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "nl"
        if preferred.hasPrefix("en") { return "en" }
        if preferred.hasPrefix("de") { return "de" }
        return "nl"
    }

    var locale: Locale { Locale(identifier: resolvedCode) }

    var speechLanguage: String {
        switch resolvedCode {
        case "en": "en-US"
        case "de": "de-DE"
        default: "nl-NL"
        }
    }
}
