import AVFoundation
import Core
import GRDB
import XCTest
import WhisperShared
@testable import WhisperClipboard

/// End-to-end smoke test against the REAL cached Parakeet model. Skipped unless
/// WC_E2E=1 is set and the test WAV exists, so it never runs in normal CI.
@MainActor
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

    /// Proves the file-import pipeline applies the personal woordenlijst to the
    /// stored transcript: a replacement whose target is a word in the file is
    /// honoured in the saved history entry. Gated identically.
    func testFileImportAppliesReplacements() async throws {
        guard ProcessInfo.processInfo.environment["WC_E2E"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/wc_e2e_enable") else {
            throw XCTSkip("Set WC_E2E=1 (or touch /tmp/wc_e2e_enable) to run the real-model end-to-end test.")
        }
        let url = URL(fileURLWithPath: "/tmp/wc_test.wav")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing /tmp/wc_test.wav")
        }

        // First transcribe raw to find a real word to target.
        let decoded = try await AudioFileDecoder.decodeToTemporaryWAV(from: url)
        defer { try? FileManager.default.removeItem(at: decoded.url) }
        let samples = try AudioSampleConverter.readSamples(fromWAV: decoded.url)
        let raw = try await ParakeetEngine().transcribeSamples(samples, locale: Locale(identifier: "nl-NL"))
        let target = raw.text
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .first(where: { $0.count > 2 })
        guard let target else { throw XCTSkip("No usable word to test a replacement against.") }
        let sentinel = "ZZQXWORD"

        let history = try HistoryStore(dbQueue: try DatabaseQueue(), retentionProvider: { nil })
        let service = FileImportService(
            engine: ParakeetEngine(),
            history: history,
            locale: { Locale(identifier: "nl-NL") },
            busyReason: { nil },
            settings: { AppSettings(replacements: [Replacement(find: target, replace: sentinel)]) },
            notify: { _ in },
            copyToClipboard: { _ in }
        )
        let jobs = service.importFiles([url])
        XCTAssertEqual(jobs.count, 1)

        // Poll until the job terminates (decode + transcribe is async).
        let deadline = Date().addingTimeInterval(120)
        while let job = jobs.first, !job.state.isTerminal, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(jobs.first?.state, .done)

        let stored = (try history.recent(1)).first
        print("WC_E2E_IMPORT replaced '\(target)' -> '\(sentinel)': \(stored?.text ?? "<nil>")")
        XCTAssertNotNil(stored)
        XCTAssertTrue(stored?.text.contains(sentinel) == true, "Expected the replacement sentinel in the stored transcript")
    }
}
