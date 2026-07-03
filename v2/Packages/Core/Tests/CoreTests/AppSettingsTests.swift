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

    /// Default HUD linger is 3 seconds (matches the previous hardcoded value).
    @Test func defaultHudLingerSecondsIsThree() {
        #expect(AppSettings().hudLingerSeconds == 3.0)
    }

    /// A settings.json written before `hudLingerSeconds` existed (an older
    /// on-disk file missing the key) must still decode, falling back to the
    /// default rather than failing the whole load.
    @Test func hudLingerSecondsFallsBackToDefaultWhenMissingFromJSON() throws {
        let json = """
        {"hotkeyMode":"toggle","language":"nl","engine":"parakeet","cleanOutput":true,"replacements":[],"directInsertion":false,"insertionDeniedBundleIds":[],"saveRecordings":false,"saveCaptions":false,"initialPrompt":""}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.hudLingerSeconds == 3.0)
    }

    /// An explicit HUD linger value round-trips through JSON coding.
    @Test func hudLingerSecondsRoundTripsThroughCoding() throws {
        var settings = AppSettings()
        settings.hudLingerSeconds = 6.5

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.hudLingerSeconds == 6.5)
    }

    /// Live caption translation is OFF by default (opt-in).
    @Test func defaultTranslateCaptionsIsOff() {
        #expect(AppSettings().translateCaptionsToDutch == false)
    }

    /// An older settings.json missing `translateCaptionsToDutch` still decodes,
    /// falling back to the default rather than failing the whole load.
    @Test func translateCaptionsFallsBackToDefaultWhenMissingFromJSON() throws {
        let json = """
        {"hotkeyMode":"toggle","language":"nl","engine":"parakeet","cleanOutput":true,"replacements":[],"directInsertion":false,"insertionDeniedBundleIds":[],"saveRecordings":false,"saveCaptions":false,"initialPrompt":""}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.translateCaptionsToDutch == false)
    }

    /// An explicit translate-captions value round-trips through JSON coding.
    @Test func translateCaptionsRoundTripsThroughCoding() throws {
        var settings = AppSettings()
        settings.translateCaptionsToDutch = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.translateCaptionsToDutch == true)
    }
}
