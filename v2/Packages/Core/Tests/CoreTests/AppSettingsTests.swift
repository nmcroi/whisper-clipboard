import Testing
import Foundation
@testable import Core

@Suite struct AppSettingsTests {

    /// Parakeet (multilingual, Dutch-capable) is the primary engine: Apple's
    /// SpeechTranscriber offers no Dutch on the target machine, so the default
    /// must be `.parakeet`. This test pins that intentional choice.
    @Test func defaultEngineIsParakeet() {
        #expect(AppSettings().engine == .parakeet)
    }

    @Test func defaultLanguageIsDutch() {
        #expect(AppSettings().language == "nl")
    }

    /// Persisted settings survive a JSON round-trip, and an explicit engine
    /// choice is preserved (not silently reset to the default).
    @Test func engineRoundTripsThroughCoding() throws {
        var settings = AppSettings()
        settings.engine = .appleSpeech

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.engine == .appleSpeech)
    }

    /// The engine enum's raw values are the stable identifiers persisted to
    /// disk; they must not drift.
    @Test func engineRawValuesAreStable() {
        #expect(AppSettings.Engine.appleSpeech.rawValue == "appleSpeech")
        #expect(AppSettings.Engine.parakeet.rawValue == "parakeet")
    }
}
