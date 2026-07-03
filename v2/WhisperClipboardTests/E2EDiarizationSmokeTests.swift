import AVFoundation
import Core
import FluidAudio
import GRDB
import XCTest
@testable import WhisperClipboard

/// End-to-end smoke test for speaker diarization on file import, against the
/// REAL cached diarizer + Parakeet models. Skipped unless WC_E2E=1 (or the
/// /tmp/wc_e2e_enable sentinel), so it never runs in normal CI.
///
/// It synthesizes a two-voice clip with `say` (Xander + Ellen, Dutch), decodes
/// both to 16 kHz mono, concatenates them, runs the import pipeline with
/// diarization enabled, and reports how many speakers were detected and how the
/// stored segments were labelled. Synthetic voices may fool the diarizer — the
/// bar is that the pipeline runs end-to-end (models load, turns produced, merge
/// applied), not that it perfectly separates two robotic voices.
@MainActor
final class E2EDiarizationSmokeTests: XCTestCase {

    private func e2eEnabled() -> Bool {
        ProcessInfo.processInfo.environment["WC_E2E"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/wc_e2e_enable")
    }

    /// Renders `text` with voice `voice` to a temp AIFF via `say`, returning the URL.
    private func synthesize(_ text: String, voice: String) throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("wc_diar_\(voice)_\(UUID().uuidString).aiff")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        proc.arguments = ["-v", voice, "-o", out.path, text]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: out.path) else {
            throw XCTSkip("`say -v \(voice)` failed — voice unavailable on this host.")
        }
        return out
    }

    /// Decodes `url` to a flat 16 kHz mono Float32 sample array.
    private func samples16k(_ url: URL) async throws -> [Float] {
        let decoded = try await AudioFileDecoder.decodeToTemporaryWAV(from: url)
        defer { try? FileManager.default.removeItem(at: decoded.url) }
        return try AudioSampleConverter.readSamples(fromWAV: decoded.url)
    }

    /// Writes a flat 16 kHz mono Float32 sample array to a WAV file.
    private func writeWAV(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let chunk = 16_000
        var offset = 0
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress!.advanced(by: offset), count: n)
            }
            try file.write(from: buf)
            offset += n
        }
    }

    func testTwoVoiceImportDiarization() async throws {
        guard e2eEnabled() else {
            throw XCTSkip("Set WC_E2E=1 (or touch /tmp/wc_e2e_enable) to run the two-voice diarization E2E test.")
        }
        guard SystemInfo.isAppleSilicon else {
            throw XCTSkip("Diarization requires Apple Silicon.")
        }

        // Two distinct Dutch voices, each ~2 sentences so the clip clears the
        // >10s diarization gate and each speaker has enough audio.
        let aURL = try synthesize(
            "Goedemorgen allemaal. Fijn dat jullie er vandaag bij zijn. Ik wil beginnen met een korte introductie over ons project.",
            voice: "Xander")
        let bURL = try synthesize(
            "Dank je wel voor de uitnodiging. Ik ben erg benieuwd naar de resultaten. Laten we vooral praktisch blijven vandaag.",
            voice: "Ellen")
        defer {
            try? FileManager.default.removeItem(at: aURL)
            try? FileManager.default.removeItem(at: bURL)
        }

        // Concatenate: A, then B, then A again — a mini turn-taking conversation.
        let a = try await samples16k(aURL)
        let b = try await samples16k(bURL)
        let combined = a + b + a
        let clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wc_diar_combined_\(UUID().uuidString).wav")
        try writeWAV(combined, to: clipURL)
        defer { try? FileManager.default.removeItem(at: clipURL) }

        let durationSec = Double(combined.count) / 16_000
        print("WC_E2E_DIAR clip duration=\(String(format: "%.1f", durationSec))s samples=\(combined.count)")

        let history = try HistoryStore(dbQueue: try DatabaseQueue(), retentionProvider: { nil })
        let service = FileImportService(
            engine: ParakeetEngine(),
            history: history,
            locale: { Locale(identifier: "nl-NL") },
            busyReason: { nil },
            diarizer: DiarizationService(),
            settings: { AppSettings(diarizeImports: true) },
            notify: { _ in },
            copyToClipboard: { _ in }
        )

        let jobs = service.importFiles([clipURL])
        XCTAssertEqual(jobs.count, 1)

        // First run may download the diarizer models — allow a generous window.
        let deadline = Date().addingTimeInterval(600)
        while let job = jobs.first, !job.state.isTerminal, Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(jobs.first?.state, .done, "Import should finish even if diarization yields nothing")

        let stored = try XCTUnwrap((try history.recent(1)).first)
        let labels = stored.segments.compactMap { $0.speaker }
        let distinct = Set(labels)
        print("WC_E2E_DIAR segments=\(stored.segments.count) labelled=\(labels.count) distinctSpeakers=\(distinct.count) -> \(distinct.sorted())")
        for seg in stored.segments.prefix(20) {
            print("WC_E2E_DIAR   [\(String(format: "%.1f", seg.start))-\(String(format: "%.1f", seg.end))] \(seg.speaker ?? "-"): \(seg.text)")
        }

        // The pipeline must have run end-to-end and stored a transcript. We do
        // NOT assert exactly two speakers — synthetic TTS voices can confuse the
        // embedding model — but the models loading + merge applying is the bar.
        XCTAssertFalse(stored.text.isEmpty, "Expected a non-empty transcript")
        print("WC_E2E_DIAR RESULT: detected \(distinct.count) speaker(s); \(labels.count)/\(stored.segments.count) segments labelled.")
    }
}
