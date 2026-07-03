import AVFoundation
import XCTest
@testable import WhisperClipboard

// MARK: - Supported extensions

final class SupportedMediaTests: XCTestCase {
    func testAcceptsCoreExtensions() {
        for ext in ["mp3", "mp4", "m4a", "wav", "mov"] {
            XCTAssertTrue(SupportedMedia.isSupported(URL(fileURLWithPath: "/tmp/clip.\(ext)")), "\(ext) should be supported")
        }
    }

    func testAcceptsExtraAudioContainers() {
        for ext in ["aac", "aiff", "aif", "caf"] {
            XCTAssertTrue(SupportedMedia.isSupported(URL(fileURLWithPath: "/tmp/clip.\(ext)")))
        }
    }

    func testCaseInsensitive() {
        XCTAssertTrue(SupportedMedia.isSupported(URL(fileURLWithPath: "/tmp/CLIP.MP3")))
        XCTAssertTrue(SupportedMedia.isSupported(URL(fileURLWithPath: "/tmp/Clip.WaV")))
    }

    func testRejectsUnsupported() {
        for ext in ["txt", "pdf", "mkv", "flac", "png", ""] {
            XCTAssertFalse(SupportedMedia.isSupported(URL(fileURLWithPath: "/tmp/x.\(ext)")))
        }
    }
}

// MARK: - Job state transitions

@MainActor
final class ImportJobStateTests: XCTestCase {
    func testTerminalStates() {
        XCTAssertTrue(ImportJob.State.done.isTerminal)
        XCTAssertTrue(ImportJob.State.failed(message: "x").isTerminal)
        XCTAssertFalse(ImportJob.State.waiting.isTerminal)
        XCTAssertFalse(ImportJob.State.decoding(progress: 0.5).isTerminal)
        XCTAssertFalse(ImportJob.State.transcribing.isTerminal)
    }

    func testJobStartsWaiting() {
        let job = ImportJob(url: URL(fileURLWithPath: "/tmp/a.wav"))
        XCTAssertEqual(job.state, .waiting)
    }

    func testDisplayNameIsStem() {
        let job = ImportJob(url: URL(fileURLWithPath: "/tmp/interview 2.m4a"))
        XCTAssertEqual(job.displayName, "interview 2")
    }

    func testDecodingProgressEquatable() {
        XCTAssertEqual(ImportJob.State.decoding(progress: 0.5), .decoding(progress: 0.5))
        XCTAssertNotEqual(ImportJob.State.decoding(progress: 0.5), .decoding(progress: 0.6))
    }
}

// MARK: - Service queue behavior (no AVFoundation / no engine)

@MainActor
final class FileImportServiceQueueTests: XCTestCase {

    /// Builds a service whose engine is never reached (guards fire first).
    private func makeService(busyReason: @escaping () -> String?) -> (FileImportService, Box) {
        let box = Box()
        // A history store backed by an in-memory queue.
        let history = try! HistoryStore(dbQueue: try! .init(), retentionProvider: { nil })
        let service = FileImportService(
            engine: ParakeetEngine(),
            history: history,
            locale: { Locale(identifier: "nl-NL") },
            busyReason: busyReason,
            notify: { box.notifications.append($0) },
            copyToClipboard: { box.clipboard = $0 }
        )
        return (service, box)
    }

    final class Box {
        var notifications: [String] = []
        var clipboard: String?
    }

    func testRefusesWhenBusy() {
        let (service, box) = makeService(busyReason: { "Wacht tot de huidige opname of transcriptie klaar is" })
        let enqueued = service.importFiles([URL(fileURLWithPath: "/tmp/a.wav")])
        XCTAssertTrue(enqueued.isEmpty)
        XCTAssertTrue(service.jobs.isEmpty)
        XCTAssertEqual(box.notifications, ["Wacht tot de huidige opname of transcriptie klaar is"])
    }

    func testRejectsUnsupportedWithNotification() {
        let (service, box) = makeService(busyReason: { nil })
        let enqueued = service.importFiles([URL(fileURLWithPath: "/tmp/a.txt")])
        XCTAssertTrue(enqueued.isEmpty)
        XCTAssertEqual(box.notifications.first, FileImportError.unsupportedType.errorDescription)
    }

    func testEnqueuesSupportedFiles() {
        let (service, _) = makeService(busyReason: { nil })
        // Non-existent files: they enqueue, then fail during decode (async).
        let enqueued = service.importFiles([
            URL(fileURLWithPath: "/tmp/a.wav"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
        ])
        XCTAssertEqual(enqueued.count, 2)
        XCTAssertEqual(service.jobs.count, 2)
    }

    func testRemoveJob() {
        let (service, _) = makeService(busyReason: { nil })
        let jobs = service.importFiles([URL(fileURLWithPath: "/tmp/a.wav")])
        service.remove(jobs[0])
        XCTAssertTrue(service.jobs.isEmpty)
    }
}

// MARK: - Decode helper against a synthesized WAV

final class AudioDecoderTests: XCTestCase {

    /// Writes a `seconds`-long 440 Hz sine at `sampleRate` mono Float32 WAV.
    private func makeSineWAV(seconds: Double, sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wc_decode_\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let ptr = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            ptr[i] = Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate)) * 0.5
        }
        try file.write(from: buffer)
        return url
    }

    /// Decodes via the real pipeline (AVAssetReader → temp WAV → sample read),
    /// cleaning up the temp file, and returns (samples, duration).
    private func decodeSamples(
        url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> (samples: [Float], duration: Double) {
        let decoded = try await AudioFileDecoder.decodeToTemporaryWAV(from: url, progress: progress)
        defer { try? FileManager.default.removeItem(at: decoded.url) }
        let samples = try AudioSampleConverter.readSamples(fromWAV: decoded.url)
        return (samples, decoded.duration)
    }

    func testDecodesToSixteenKhzMono() async throws {
        // 2s at 44.1kHz → expect ~2s of 16kHz samples (~32000).
        let url = try makeSineWAV(seconds: 2, sampleRate: 44_100)
        defer { try? FileManager.default.removeItem(at: url) }

        let (samples, duration) = try await decodeSamples(url: url)

        XCTAssertEqual(duration, 2.0, accuracy: 0.05)
        // 16 kHz * 2s = 32000, allow converter edge tolerance.
        XCTAssertEqual(Double(samples.count), 32_000, accuracy: 2_000)
        XCTAssertFalse(samples.isEmpty)
    }

    func testAlreadySixteenKhzPassesThrough() async throws {
        let url = try makeSineWAV(seconds: 1, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let (samples, duration) = try await decodeSamples(url: url)
        XCTAssertEqual(duration, 1.0, accuracy: 0.05)
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 1_500)
    }

    func testReportsProgress() async throws {
        let url = try makeSineWAV(seconds: 3, sampleRate: 44_100)
        defer { try? FileManager.default.removeItem(at: url) }

        final class Box: @unchecked Sendable { var last: Double = 0 }
        let box = Box()
        _ = try await decodeSamples(url: url) { box.last = $0 }
        XCTAssertEqual(box.last, 1.0, accuracy: 0.001)
    }

    func testMissingFileThrows() async {
        let url = URL(fileURLWithPath: "/tmp/nope_\(UUID().uuidString).wav")
        do {
            _ = try await AudioFileDecoder.decodeToTemporaryWAV(from: url)
            XCTFail("Expected a fileMissing error")
        } catch let error as FileImportError {
            XCTAssertEqual(error, .fileMissing)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

extension FileImportError: Equatable {
    public static func == (lhs: FileImportError, rhs: FileImportError) -> Bool {
        lhs.errorDescription == rhs.errorDescription
    }
}
