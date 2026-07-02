import Core
import Foundation

/// Pure decision logic for which transcription engine is active, factored out so
/// it can be unit-tested without the Speech framework or any model on disk.
///
/// Rule: honour the user's `settings.engine`, except that Apple Speech is only
/// viable when its on-device model supports the configured language. When the
/// user picked `.appleSpeech` but the language is unsupported, fall back to
/// Parakeet (the multilingual primary) and surface a one-line Dutch notice.
enum EngineSelector {

    struct Decision: Equatable {
        var engine: AppSettings.Engine
        /// A user-facing notice when the selection differs from what was asked,
        /// or `nil` when the requested engine is used as-is.
        var notice: String?
    }

    /// - Parameters:
    ///   - requested: The engine chosen in settings.
    ///   - language: The configured language identifier (e.g. "nl", "nl-NL").
    ///   - appleSupportedLanguageCodes: The set of ISO language codes Apple's
    ///     `SpeechTranscriber` supports on this machine (e.g. `["en", "de", …]`).
    ///     Pass the language codes of `SpeechTranscriber.supportedLocales`.
    static func decide(
        requested: AppSettings.Engine,
        language: String,
        appleSupportedLanguageCodes: Set<String>
    ) -> Decision {
        switch requested {
        case .parakeet:
            return Decision(engine: .parakeet, notice: nil)
        case .appleSpeech:
            let code = languageCode(from: language)
            if appleSupportedLanguageCodes.contains(code) {
                return Decision(engine: .appleSpeech, notice: nil)
            }
            return Decision(
                engine: .parakeet,
                notice: "Apple-spraakherkenning ondersteunt ‘\(code)’ niet — Parakeet actief"
            )
        }
    }

    /// Normalizes "nl", "nl-NL", "nl_NL" → "nl".
    static func languageCode(from language: String) -> String {
        let trimmed = language.isEmpty ? "nl" : language
        let normalized = trimmed.replacingOccurrences(of: "_", with: "-")
        return normalized.split(separator: "-").first.map(String.init) ?? normalized
    }
}
