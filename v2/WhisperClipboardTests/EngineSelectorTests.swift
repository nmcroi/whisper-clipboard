import XCTest
import Core
@testable import WhisperClipboard

final class EngineSelectorTests: XCTestCase {

    // MARK: - Parakeet requested

    func testParakeetRequestedAlwaysUsesParakeetWithNoNotice() {
        let decision = EngineSelector.decide(
            requested: .parakeet,
            language: "nl",
            appleSupportedLanguageCodes: ["en", "de"]
        )
        XCTAssertEqual(decision.engine, .parakeet)
        XCTAssertNil(decision.notice)
    }

    func testParakeetRequestedUnaffectedEvenIfAppleSupportsLanguage() {
        let decision = EngineSelector.decide(
            requested: .parakeet,
            language: "en",
            appleSupportedLanguageCodes: ["en"]
        )
        XCTAssertEqual(decision.engine, .parakeet)
        XCTAssertNil(decision.notice)
    }

    // MARK: - Apple Speech requested, language supported

    func testAppleRequestedAndSupportedUsesApple() {
        let decision = EngineSelector.decide(
            requested: .appleSpeech,
            language: "en-US",
            appleSupportedLanguageCodes: ["en", "de"]
        )
        XCTAssertEqual(decision.engine, .appleSpeech)
        XCTAssertNil(decision.notice)
    }

    // MARK: - Apple Speech requested, language NOT supported → fall back

    func testAppleRequestedButDutchUnsupportedFallsBackToParakeet() {
        let decision = EngineSelector.decide(
            requested: .appleSpeech,
            language: "nl",
            appleSupportedLanguageCodes: ["en", "de", "fr"]
        )
        XCTAssertEqual(decision.engine, .parakeet)
        XCTAssertEqual(decision.notice, "Apple-spraakherkenning ondersteunt ‘nl’ niet — Parakeet actief")
    }

    func testFallbackNoticeUsesLanguageCodeNotFullIdentifier() {
        let decision = EngineSelector.decide(
            requested: .appleSpeech,
            language: "nl-NL",
            appleSupportedLanguageCodes: ["en"]
        )
        XCTAssertEqual(decision.engine, .parakeet)
        XCTAssertEqual(decision.notice, "Apple-spraakherkenning ondersteunt ‘nl’ niet — Parakeet actief")
    }

    func testEmptyLanguageDefaultsToDutch() {
        let decision = EngineSelector.decide(
            requested: .appleSpeech,
            language: "",
            appleSupportedLanguageCodes: ["en"]
        )
        // Empty language defaults to "nl", which is unsupported here.
        XCTAssertEqual(decision.engine, .parakeet)
        XCTAssertEqual(decision.notice, "Apple-spraakherkenning ondersteunt ‘nl’ niet — Parakeet actief")
    }

    // MARK: - languageCode normalization

    func testLanguageCodeNormalization() {
        XCTAssertEqual(EngineSelector.languageCode(from: "nl"), "nl")
        XCTAssertEqual(EngineSelector.languageCode(from: "nl-NL"), "nl")
        XCTAssertEqual(EngineSelector.languageCode(from: "nl_NL"), "nl")
        XCTAssertEqual(EngineSelector.languageCode(from: "en-US"), "en")
        XCTAssertEqual(EngineSelector.languageCode(from: ""), "nl")
    }
}
