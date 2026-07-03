import AVFoundation
import XCTest
@testable import WhisperClipboard

/// End-to-end smoke test against the REAL cached Parakeet model. Skipped unless
/// WC_E2E=1 is set and the test WAV exists, so it never runs in normal CI.
final class E2EImportSmokeTests: XCTestCase {

    func testDecodeAndTranscribeRealFile() async throws {
        guard ProcessInfo.processInfo.environment["WC_E2E"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/wc_e2e_enable") else {
            throw XCTSkip("Set WC_E2E=1 (or touch /tmp/wc_e2e_enable) to run the real-model end-to-end test.")
        }
        let url = URL(fileURLWithPath: "/tmp/wc_test.wav")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing /tmp/wc_test.wav")
        }

        let decodeStart = Date()
        let decoded = try await AudioFileDecoder.decodeToTemporaryWAV(from: url)
        let samples = try AudioSampleConverter.readSamples(fromWAV: decoded.url)
        let decodeMs = Date().timeIntervalSince(decodeStart) * 1000
        defer { try? FileManager.default.removeItem(at: decoded.url) }

        let engine = ParakeetEngine()
        let transcribeStart = Date()
        let result = try await engine.transcribeSamples(samples, locale: Locale(identifier: "nl-NL"))
        let transcribeMs = Date().timeIntervalSince(transcribeStart) * 1000

        print("WC_E2E duration=\(decoded.duration)s samples=\(samples.count) decode=\(Int(decodeMs))ms transcribe=\(Int(transcribeMs))ms")
        print("WC_E2E text=[\(result.text)]")
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
