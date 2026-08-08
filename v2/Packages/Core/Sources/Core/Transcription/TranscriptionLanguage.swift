import Foundation

/// De taalkeuze voor een opname. `automatic` laat het meertalige model zelf
/// detecteren; de overige waarden geven het model een script-/taalhint en worden
/// als stabiele BCP-47-code bij het transcript bewaard.
public enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case dutch = "nl"
    case english = "en"
    case german = "de"

    public var id: String { rawValue }

    public var locale: Locale {
        switch self {
        case .automatic: Locale(identifier: "und")
        case .dutch: Locale(identifier: "nl_NL")
        case .english: Locale(identifier: "en_US")
        case .german: Locale(identifier: "de_DE")
        }
    }

    /// Leest zowel nieuwe codes als oudere opgeslagen locale-identifiers.
    public init(locale: Locale) {
        let identifier = locale.identifier.lowercased()
        if identifier == "und" || identifier == "auto" || identifier.isEmpty {
            self = .automatic
        } else if identifier.hasPrefix("nl") {
            self = .dutch
        } else if identifier.hasPrefix("de") {
            self = .german
        } else if identifier.hasPrefix("en") {
            self = .english
        } else {
            self = .automatic
        }
    }

    public init(metadataCode: String) {
        switch metadataCode.lowercased().split(separator: "-").first.map(String.init) {
        case "nl": self = .dutch
        case "en": self = .english
        case "de": self = .german
        case "auto", "und": self = .automatic
        default: self = .automatic
        }
    }
}
