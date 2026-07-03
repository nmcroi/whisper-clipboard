import AVFoundation
import Core
import FluidAudio
import Foundation

/// Errors from the Parakeet (FluidAudio) backend, surfaced in Dutch.
enum ParakeetEngineError: LocalizedError {
    case unsupportedHardware
    case noNetwork
    case downloadFailed(String)
    case modelNotLoaded
    case notRecording
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedHardware:
            return "Parakeet vereist een Mac met Apple Silicon (M-serie)."
        case .noNetwork:
            return "Geen internetverbinding om het Parakeet-model te downloaden. Maak verbinding en probeer opnieuw."
        case .downloadFailed(let detail):
            return "Het Parakeet-model kon niet worden gedownload: \(detail)"
        case .modelNotLoaded:
            return "Het Parakeet-model is nog niet geladen."
        case .notRecording:
            return "Er loopt geen opnamesessie."
        case .transcriptionFailed(let detail):
            return "Transcriptie mislukte: \(detail)"
        }
    }
}

/// NVIDIA Parakeet TDT 0.6b v3 (multilingual, incl. Dutch) via the FluidAudio
/// Swift package, running Apple-Silicon CoreML on-device.
///
/// ## Streaming vs batch — why this engine is batch-only
/// FluidAudio only exposes true low-latency streaming (`StreamingAsrManager` /
/// Parakeet EOU, Nemotron, Unified) for **English** models. The multilingual v3
/// model this app needs for Dutch is an *offline* encoder; it has no cache-aware
/// streaming path. So we accumulate 16 kHz mono Float32 during recording and run
/// **one** `AsrManager.transcribe(_:decoderState:)` in ``finalize()``. At the
/// model's ~100x realtime factor a 30 s clip transcribes in well under the
/// 1.5 s stop→clipboard budget. In this mode we emit **no** partials — the HUD
/// already shows the live level meter and elapsed time.
///
/// An actor so the sample buffer, the loaded models and the asset status live on
/// a single isolation domain. The models/manager are loaded once and kept alive
/// across dictations (pre-warm).
actor ParakeetEngine: TranscriptionEngine {

    // MARK: - Partials stream (never yields — batch engine)

    /// Present to satisfy the protocol; the batch engine produces no partials.
    /// The continuation is finished immediately so any consumer's `for await`
    /// completes at once rather than hanging.
    nonisolated let partials: AsyncStream<StreamingPartial>

    // MARK: - Model state (kept alive across dictations)

    private var manager: AsrManager?
    private var isLoaded = false

    /// Progress reported by the last/ongoing download, surfaced via `assetStatus`.
    private var downloadProgress: Double = 0
    private var isDownloading = false

    // MARK: - Recording session state

    /// Accumulated 16 kHz mono Float32 samples for the current recording.
    private var samples: [Float] = []
    private var isRecording = false

    // MARK: - Constants

    /// The v3 model wants 16 kHz mono Float32.
    private static let sampleRate: Double = 16_000

    init() {
        let (stream, continuation) = AsyncStream<StreamingPartial>.makeStream()
        partials = stream
        // Batch engine: no partials ever. Finish now so consumers don't block.
        continuation.finish()
    }

    // MARK: - Preparation

    func prepare() async throws {
        guard Self.isSupportedHardware else { throw ParakeetEngineError.unsupportedHardware }
        // Only load if the model is already on disk; downloading is UI-driven.
        guard Self.modelsPresentOnDisk else { return }
        try await loadModelsIfNeeded()
    }

    /// Loads (or reuses) the CoreML models into a long-lived `AsrManager`.
    /// Idempotent: a second call is a no-op once loaded.
    private func loadModelsIfNeeded() async throws {
        guard !isLoaded else { return }
        do {
            // Models are already on disk here, so this only loads (no network).
            let models = try await AsrModels.loadFromCache(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
            self.isLoaded = true
        } catch {
            throw ParakeetEngineError.downloadFailed(error.localizedDescription)
        }
    }

    // MARK: - Asset management

    func assetStatus(for locale: Locale) async -> ModelAssetStatus {
        guard Self.isSupportedHardware else { return .unsupported }
        if isDownloading {
            return .downloading(progress: downloadProgress)
        }
        if isLoaded || Self.modelsPresentOnDisk {
            return .installed
        }
        return .needsDownload(progress: 0)
    }

    func downloadAssets(for locale: Locale) async throws {
        guard Self.isSupportedHardware else { throw ParakeetEngineError.unsupportedHardware }
        guard !isDownloading else { return }

        isDownloading = true
        downloadProgress = 0
        defer { isDownloading = false }

        // Progress handler is called on an unspecified queue; it only mutates a
        // Double, which we hop back onto the actor to store.
        let progressHandler: DownloadUtils.ProgressHandler = { [weak self] progress in
            let fraction = progress.fractionCompleted
            Task { [weak self] in await self?.setDownloadProgress(fraction) }
        }

        do {
            try await performDownloadAndLoad(progressHandler: progressHandler)
        } catch {
            // Corrupt / partial download: wipe the cache and retry once.
            if Self.isLikelyCorruptDownload(error) {
                Self.removeModelCache()
                do {
                    try await performDownloadAndLoad(progressHandler: progressHandler)
                } catch {
                    throw Self.mapDownloadError(error)
                }
            } else {
                throw Self.mapDownloadError(error)
            }
        }
    }

    /// Downloads (if needed) and loads the models into a live manager.
    private func performDownloadAndLoad(progressHandler: @escaping DownloadUtils.ProgressHandler) async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: progressHandler)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        self.isLoaded = true
        self.downloadProgress = 1
    }

    private func setDownloadProgress(_ value: Double) {
        downloadProgress = min(max(value, 0), 1)
    }

    // MARK: - Audio format

    func bestAudioFormat() async -> AVAudioFormat? {
        // 16 kHz mono Float32 — exactly what the v3 model consumes, so the
        // AudioEngine converter delivers ready-to-use samples.
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    // MARK: - Recording

    func startStreaming(locale: Locale) async throws {
        guard Self.isSupportedHardware else { throw ParakeetEngineError.unsupportedHardware }
        try await loadModelsIfNeeded()
        guard isLoaded else { throw ParakeetEngineError.modelNotLoaded }

        samples.removeAll(keepingCapacity: true)
        isRecording = true
    }

    func feed(_ buffer: AudioBufferBox) async {
        guard isRecording else { return }
        guard let chunk = Self.floatSamples(from: buffer.buffer) else { return }
        samples.append(contentsOf: chunk)
    }

    func finalize() async throws -> TranscriptionResult {
        guard isRecording else { throw ParakeetEngineError.notRecording }
        isRecording = false

        guard let manager else { throw ParakeetEngineError.modelNotLoaded }

        let captured = samples
        samples.removeAll(keepingCapacity: true)

        // Too little audio to transcribe: return empty (the controller then
        // reports "Geen spraak herkend").
        guard captured.count >= Int(Self.sampleRate * 0.3) else {
            return .empty
        }

        do {
            // `language: nil` → v3 multilingual auto-detection.
            var state = TdtDecoderState.make(decoderLayers: 2)
            let result = try await manager.transcribe(captured, decoderState: &state, language: nil)
            let segments = Self.segments(from: result)
            return TranscriptionResult(text: result.text, segments: segments)
        } catch {
            throw ParakeetEngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    func cancel() async {
        isRecording = false
        samples.removeAll(keepingCapacity: false)
    }

    /// Transcribes pre-decoded 16 kHz mono Float32 samples (M3 file import).
    /// FluidAudio chunks long input internally via its sliding-window pipeline,
    /// so no manual chunking is needed even for hour-long recordings.
    func transcribeSamples(_ samples: [Float], locale: Locale) async throws -> TranscriptionResult {
        guard Self.isSupportedHardware else { throw ParakeetEngineError.unsupportedHardware }
        try await loadModelsIfNeeded()
        guard let manager else { throw ParakeetEngineError.modelNotLoaded }

        guard samples.count >= Int(Self.sampleRate * 0.3) else { return .empty }

        do {
            var state = TdtDecoderState.make(decoderLayers: 2)
            let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
            return TranscriptionResult(text: result.text, segments: Self.segments(from: result))
        } catch {
            throw ParakeetEngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    func transcribeFile(at url: URL, locale: Locale) async throws -> TranscriptionResult {
        guard Self.isSupportedHardware else { throw ParakeetEngineError.unsupportedHardware }
        try await loadModelsIfNeeded()
        guard let manager else { throw ParakeetEngineError.modelNotLoaded }
        do {
            var state = TdtDecoderState.make(decoderLayers: 2)
            let result = try await manager.transcribe(url, decoderState: &state, language: nil)
            return TranscriptionResult(text: result.text, segments: Self.segments(from: result))
        } catch {
            throw ParakeetEngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Result mapping

    /// Maps FluidAudio token timings onto Core segments. FluidAudio reports
    /// per-token (SentencePiece) timings; we coalesce them into whitespace-
    /// delimited word segments so downstream export/history matches the Apple
    /// engine's granularity. Falls back to a single full-range segment when no
    /// timings are available.
    private static func segments(from result: ASRResult) -> [Core.TranscriptSegment] {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // No timings: one segment spanning the whole clip.
            return [Core.TranscriptSegment(start: 0, end: result.duration, text: text)]
        }

        return wordSegments(from: timings)
    }

    /// Coalesces per-token timings into word segments. FluidAudio marks a word
    /// boundary with a leading space in the token piece (SentencePiece "▁",
    /// already normalized to a space by FluidAudio). A new word starts whenever
    /// a token begins with whitespace; intra-word tokens extend the current one.
    private static func wordSegments(from timings: [TokenTiming]) -> [Core.TranscriptSegment] {
        var segments: [Core.TranscriptSegment] = []
        var currentText = ""
        var currentStart = 0.0
        var currentEnd = 0.0

        func flush() {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            segments.append(Core.TranscriptSegment(start: currentStart, end: currentEnd, text: trimmed))
        }

        for timing in timings {
            let piece = timing.token
            let startsWord = piece.first?.isWhitespace ?? false

            if startsWord || currentText.isEmpty {
                if !currentText.isEmpty { flush() }
                currentText = piece
                currentStart = timing.startTime
                currentEnd = timing.endTime
            } else {
                currentText += piece
                currentEnd = timing.endTime
            }
        }
        flush()
        return segments
    }

    // MARK: - Sample extraction

    /// Extracts mono Float32 samples from a 16 kHz buffer. The buffer arrives
    /// already converted by ``AudioEngine`` to the format `bestAudioFormat()`
    /// requested, so this is a straight copy of channel 0.
    private static func floatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }

    // MARK: - Hardware / cache helpers

    /// FluidAudio's Parakeet CoreML models require Apple Silicon at runtime.
    private static var isSupportedHardware: Bool {
        SystemInfo.isAppleSilicon
    }

    private static var modelCacheDirectory: URL {
        AsrModels.defaultCacheDirectory(for: .v3)
    }

    private static var modelsPresentOnDisk: Bool {
        AsrModels.modelsExist(at: modelCacheDirectory, version: .v3)
    }

    private static func removeModelCache() {
        // FluidAudio lays the repo out one directory *below* the passed cache
        // dir (see AsrModels.download: it strips the last path component and
        // appends the repo folder). Remove the whole FluidAudio Models dir to
        // guarantee a clean re-download of partial files.
        let dir = modelCacheDirectory
        try? FileManager.default.removeItem(at: dir)
    }

    /// A partial/corrupt download typically surfaces as a load/compile failure
    /// rather than a URL error; those are the ones a wipe-and-retry can fix.
    private static func isLikelyCorruptDownload(_ error: Error) -> Bool {
        if error is AsrModelsError { return true }
        if let asrError = error as? ASRError {
            switch asrError {
            case .modelLoadFailed, .modelCompilationFailed:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Distinguishes a no-network failure (offline) from other download errors
    /// so the user gets an actionable Dutch message.
    private static func mapDownloadError(_ error: Error) -> ParakeetEngineError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed:
                return .noNetwork
            default:
                return .downloadFailed(error.localizedDescription)
            }
        }
        return .downloadFailed(error.localizedDescription)
    }
}
