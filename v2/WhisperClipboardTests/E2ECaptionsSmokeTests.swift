import AVFoundation
import GRDB
import XCTest
@testable import WhisperClipboard

/// End-to-end smoke test for the live-captions rolling-window path against the
/// REAL cached Parakeet model — WITHOUT the system-audio tap. Feeds a decoded
/// WAV's samples straight through ``CaptionsService/captionSamplesForTesting(_:)``
/// (the same windowing logic ``consume(_:)`` runs) and asserts caption lines are
/// produced. Skipped unless WC_E2E=1 and /tmp/wc_test.wav exists.
@MainActor
final class E2ECaptionsSmokeTests: XCTestCase {

    func testCaptionWindowingProducesLinesFromRealWAV() async throws {
        guard ProcessInfo.processInfo.environment["WC_E2E"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/wc_e2e_enable") else {
            throw XCTSkip("Set WC_E2E=1 (or touch /tmp/wc_e2e_enable) to run the real-model captions test.")
        }
        let url = URL(fileURLWithPath: "/tmp/wc_test.wav")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing /tmp/wc_test.wav")
        }

        let decoded = try await AudioFileDecoder.decodeToTemporaryWAV(from: url)
        defer { try? FileManager.default.removeItem(at: decoded.url) }
        let samples = try AudioSampleConverter.readSamples(fromWAV: decoded.url)

        // A throwaway in-memory history store; captions won't be saved here anyway.
        let history = try HistoryStore(dbQueue: try DatabaseQueue(), retentionProvider: { nil })
        let service = CaptionsService(
            history: history,
            locale: { Locale(identifier: "nl-NL") },
            saveToHistory: { false },
            busyReason: { nil }
        )

        let start = Date()
        let lines = await service.captionSamplesForTesting(samples)
        let ms = Int(Date().timeIntervalSince(start) * 1000)

        print("WC_E2E_CAPTIONS duration=\(decoded.duration)s windows=\(lines.count) total=\(ms)ms")
        for (i, line) in lines.enumerated() { print("WC_E2E_CAPTIONS line[\(i)]=[\(line)]") }

        XCTAssertFalse(lines.isEmpty, "Expected at least one caption line from the WAV")
        let combined = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(combined.isEmpty)
    }
}
