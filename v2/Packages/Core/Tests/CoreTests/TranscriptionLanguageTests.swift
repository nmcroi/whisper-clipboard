import Foundation
import Testing
@testable import Core

@Suite("Transcriptietaalmetadata")
struct TranscriptionLanguageTests {
    @Test func stableCodesAndDefaultsStayCompatible() {
        #expect(TranscriptionLanguage.allCases.map(\.rawValue) == ["auto", "nl", "en", "de"])
        #expect(TranscriptionLanguage(metadataCode: "") == .automatic)
        #expect(TranscriptionLanguage(metadataCode: "onbekend") == .automatic)
    }

    @Test func metadataAcceptsBareAndRegionalCodes() {
        #expect(TranscriptionLanguage(metadataCode: "nl-NL") == .dutch)
        #expect(TranscriptionLanguage(metadataCode: "en-US") == .english)
        #expect(TranscriptionLanguage(metadataCode: "de-DE") == .german)
        #expect(TranscriptionLanguage(metadataCode: "und") == .automatic)
    }

    @Test func localesRoundTripToTheIntendedHint() {
        for language in TranscriptionLanguage.allCases {
            #expect(TranscriptionLanguage(locale: language.locale) == language)
        }
    }
}
