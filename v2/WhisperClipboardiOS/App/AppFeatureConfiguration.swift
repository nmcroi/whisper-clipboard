import Core
import Foundation

/// Eén compile-time bron voor productverschillen. Schermcode vraagt deze
/// configuratie niet verspreid op; code die Public echt niet mag bevatten wordt
/// daarnaast met dezelfde compilation condition uitgesloten.
enum AppFeatureConfiguration {
    #if WHISPERCLIP_PUBLIC
    static let includesPlaud = false
    static let productVariant = "public"
    static let defaultTranscriptionLanguage = TranscriptionLanguage.automatic
    #else
    static let includesPlaud = true
    static let productVariant = "personal"
    static let defaultTranscriptionLanguage = TranscriptionLanguage.dutch
    #endif

    static let visibleProductName = "WhisperClip"
}
