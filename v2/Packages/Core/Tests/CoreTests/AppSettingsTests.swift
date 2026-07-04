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

    // MARK: - Appearance

    /// Dark is the app's signature look and stays the default; light/system are
    /// opt-in via the "Thema" picker.
    @Test func defaultAppearanceIsDark() {
        #expect(AppSettings().appearance == .dark)
    }

    /// The appearance raw values are the stable identifiers persisted to disk;
    /// they must not drift.
    @Test func appearanceRawValuesAreStable() {
        #expect(AppSettings.AppearanceMode.system.rawValue == "system")
        #expect(AppSettings.AppearanceMode.dark.rawValue == "dark")
        #expect(AppSettings.AppearanceMode.light.rawValue == "light")
    }

    /// An older settings.json written before the `appearance` key existed still
    /// decodes, falling back to the `.dark` default rather than failing the load.
    @Test func appearanceFallsBackToDarkWhenMissingFromJSON() throws {
        let json = """
        {"hotkeyMode":"toggle","language":"nl","engine":"parakeet","cleanOutput":true,"replacements":[],"directInsertion":false,"insertionDeniedBundleIds":[],"saveRecordings":false,"saveCaptions":false,"initialPrompt":""}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.appearance == .dark)
    }

    /// An explicit appearance choice round-trips through JSON coding (not reset
    /// to the default).
    @Test func appearanceRoundTripsThroughCoding() throws {
        for mode in AppSettings.AppearanceMode.allCases {
            var settings = AppSettings()
            settings.appearance = mode
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            #expect(decoded.appearance == mode)
        }
    }

    // MARK: - Automation fields (M7)

    /// All automation features default to OFF / empty (opt-in).
    @Test func automationDefaultsAreOff() {
        let d = AppSettings()
        #expect(d.removeFillers == false)
        #expect(d.autoExportEnabled == false)
        #expect(d.autoExportDirectory == "")
        #expect(d.autoExportFormat == "md")
        #expect(d.watchedFolders == [])
    }

    /// An older settings.json missing all the new automation keys still decodes,
    /// each falling back to its default rather than failing the whole load.
    @Test func automationFieldsFallBackWhenMissingFromJSON() throws {
        let json = """
        {"hotkeyMode":"toggle","language":"nl","engine":"parakeet","cleanOutput":true,"replacements":[],"directInsertion":false,"insertionDeniedBundleIds":[],"saveRecordings":false,"saveCaptions":false,"initialPrompt":""}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.removeFillers == false)
        #expect(decoded.autoExportEnabled == false)
        #expect(decoded.autoExportDirectory == "")
        #expect(decoded.autoExportFormat == "md")
        #expect(decoded.watchedFolders == [])
    }

    /// Explicit automation values round-trip through JSON coding.
    @Test func automationFieldsRoundTripThroughCoding() throws {
        var settings = AppSettings()
        settings.removeFillers = true
        settings.autoExportEnabled = true
        settings.autoExportDirectory = "/Users/x/Transcripts"
        settings.autoExportFormat = "srt"
        settings.watchedFolders = ["/Users/x/Inbox", "/Users/x/Recordings"]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.removeFillers == true)
        #expect(decoded.autoExportEnabled == true)
        #expect(decoded.autoExportDirectory == "/Users/x/Transcripts")
        #expect(decoded.autoExportFormat == "srt")
        #expect(decoded.watchedFolders == ["/Users/x/Inbox", "/Users/x/Recordings"])
    }

    // MARK: - PLAUD sync fields

    /// PLAUD sync defaults to OFF, 15-minute interval, 30-day window, no email (opt-in).
    @Test func plaudDefaultsAreOff() {
        let d = AppSettings()
        #expect(d.plaudSyncEnabled == false)
        #expect(d.plaudSyncIntervalMinutes == 15)
        #expect(d.plaudSyncWindowDays == 30)
        #expect(d.plaudEmail == "")
    }

    /// An older settings.json missing the PLAUD keys still decodes, each field
    /// falling back to its default rather than failing the whole load. In
    /// particular, a file written before `plaudSyncWindowDays` existed must fall
    /// back to the 30-day default (not 0/all-history).
    @Test func plaudFieldsFallBackWhenMissingFromJSON() throws {
        let json = """
        {"hotkeyMode":"toggle","language":"nl","engine":"parakeet","cleanOutput":true,"replacements":[],"directInsertion":false,"insertionDeniedBundleIds":[],"saveRecordings":false,"saveCaptions":false,"initialPrompt":""}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.plaudSyncEnabled == false)
        #expect(decoded.plaudSyncIntervalMinutes == 15)
        #expect(decoded.plaudSyncWindowDays == 30)
        #expect(decoded.plaudEmail == "")
    }

    /// A settings.json that carries the other PLAUD keys but predates
    /// `plaudSyncWindowDays` still decodes the window to its 30-day default.
    @Test func plaudSyncWindowDaysFallsBackToDefaultWhenMissingFromJSON() throws {
        let json = """
        {"plaudSyncEnabled":true,"plaudSyncIntervalMinutes":60,"plaudEmail":"a@b.nl"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.plaudSyncEnabled == true)
        #expect(decoded.plaudSyncIntervalMinutes == 60)
        #expect(decoded.plaudSyncWindowDays == 30)
    }

    /// Explicit PLAUD values round-trip through JSON coding, including the window
    /// (and its "all history" sentinel, 0).
    @Test func plaudFieldsRoundTripThroughCoding() throws {
        var settings = AppSettings()
        settings.plaudSyncEnabled = true
        settings.plaudSyncIntervalMinutes = 30
        settings.plaudSyncWindowDays = 90
        settings.plaudEmail = "niels@example.com"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.plaudSyncEnabled == true)
        #expect(decoded.plaudSyncIntervalMinutes == 30)
        #expect(decoded.plaudSyncWindowDays == 90)
        #expect(decoded.plaudEmail == "niels@example.com")
    }

    /// The "all history" sentinel (0) round-trips and is not confused with the
    /// missing-key fallback (30).
    @Test func plaudSyncWindowDaysZeroRoundTrips() throws {
        var settings = AppSettings()
        settings.plaudSyncWindowDays = 0
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.plaudSyncWindowDays == 0)
    }
}
