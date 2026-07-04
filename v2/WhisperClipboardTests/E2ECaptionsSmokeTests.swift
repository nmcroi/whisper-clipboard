import AVFoundation
import Core
import GRDB
import XCTest
import WhisperShared
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
        let run = await service.captionRunForTesting(samples)
        let ms = Int(Date().timeIntervalSince(start) * 1000)

        print("WC_E2E_CAPTIONS duration=\(decoded.duration)s finals=\(run.finalLines.count) volatile=\(run.volatileUpdates.count) total=\(ms)ms")
        for (i, line) in run.volatileUpdates.enumerated() { print("WC_E2E_CAPTIONS volatile[\(i)]=[\(line)]") }
        for (i, line) in run.finalLines.enumerated() { print("WC_E2E_CAPTIONS final[\(i)]=[\(line)]") }

        XCTAssertFalse(run.finalLines.isEmpty, "Expected at least one final caption line from the WAV")
        let combined = run.finalLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(combined.isEmpty)
    }

    /// Proves the personal woordenlijst is applied to caption lines end-to-end:
    /// a replacement whose target is a common Dutch word is honoured in the
    /// produced lines. Gated identically to the smoke test above.
    func testCaptionsApplyReplacements() async throws {
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
        let history = try HistoryStore(dbQueue: try DatabaseQueue(), retentionProvider: { nil })

        // Baseline: find a whole word that actually appears in the transcript.
        let plain = CaptionsService(
            history: history,
            locale: { Locale(identifier: "nl-NL") },
            saveToHistory: { false },
            busyReason: { nil }
        )
        let baseline = await plain.captionSamplesForTesting(samples)
        let words = baseline
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 2 }
        guard let target = words.first else {
            throw XCTSkip("Transcript produced no usable word to test a replacement against.")
        }
        let sentinel = "ZZQXWORD"

        let withRules = CaptionsService(
            history: history,
            locale: { Locale(identifier: "nl-NL") },
            saveToHistory: { false },
            busyReason: { nil },
            replacements: { [Replacement(find: target, replace: sentinel)] }
        )
        let replaced = await withRules.captionSamplesForTesting(samples)
        let combined = replaced.joined(separator: " ")
        print("WC_E2E_CAPTIONS replaced '\(target)' -> '\(sentinel)': \(combined)")
        XCTAssertTrue(combined.contains(sentinel), "Expected the replacement sentinel in the caption output")
    }
}
