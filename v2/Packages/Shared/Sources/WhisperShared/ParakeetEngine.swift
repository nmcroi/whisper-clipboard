import AVFoundation
import Core
import FluidAudio
import Foundation

/// Errors from the Parakeet (FluidAudio) backend, surfaced in Dutch.
public enum ParakeetEngineError: LocalizedError {
    case unsupportedHardware
    case noNetwork
    case downloadFailed(String)
    case downloadStalled
    case modelNotLoaded
    case notRecording
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHardware:
            return "Parakeet vereist een Mac met Apple Silicon (M-serie)."
        case .noNetwork:
            return "Geen internetverbinding om het Parakeet-model te downloaden. Maak verbinding en probeer opnieuw."
        case .downloadFailed(let detail):
            return "Het Parakeet-model kon niet worden gedownload: \(detail)"
        case .downloadStalled:
            return "Download lijkt vast te zitten — controleer je verbinding en probeer opnieuw."
        case .modelNotLoaded:
            return "Het Parakeet-model is nog niet geladen."
        case .notRecording:
            return "Er loopt geen opnamesessie."
        case .transcriptionFailed(let detail):
            return "Transcriptie mislukte: \(detail)"
        }
    }
}

/// A snapshot of download byte progress, surfaced to the UI so it can show
/// "X van Y MB" and never look frozen. `downloadedBytes` is measured on disk;
/// `totalBytes` is the known model size (~460 MB for Parakeet v3).
public struct ModelDownloadByteProgress: Sendable, Equatable {
    public let downloadedBytes: Int64
    public let totalBytes: Int64

    public init(downloadedBytes: Int64, totalBytes: Int64) {
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
    }

    /// Downloaded megabytes, rounded for display (1 MB = 1_000_000 bytes to
    /// match the "~460 MB" the marketing/UI copy quotes).
    public var downloadedMB: Int { Int((Double(downloadedBytes) / 1_000_000).rounded()) }
    public var totalMB: Int { Int((Double(totalBytes) / 1_000_000).rounded()) }
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
public actor ParakeetEngine: TranscriptionEngine {

    // MARK: - Partials stream (never yields — batch engine)

    /// Present to satisfy the protocol; the batch engine produces no partials.
    /// The continuation is finished immediately so any consumer's `for await`
    /// completes at once rather than hanging.
    public nonisolated let partials: AsyncStream<StreamingPartial>

    // MARK: - Model state (kept alive across dictations)

    private var manager: AsrManager?
    private var isLoaded = false

    /// Progress reported by the last/ongoing download, surfaced via `assetStatus`.
    /// Monotonic within a download: never moves backwards so the bar can't jump.
    private var downloadProgress: Double = 0
    private var isDownloading = false

    /// Latest bytes-on-disk snapshot for the model directory, driving the
    /// "X van Y MB" text and a smooth, always-moving progress bar even when
    /// FluidAudio's per-file fraction sits still on the big encoder file.
    private var downloadedBytes: Int64 = 0

    /// Known total download size for the v3 model set (~460 MB). Used to derive
    /// a disk-based fraction and the "van Y MB" denominator. This is the
    /// compressed-on-disk size of the int8-encoder v3 repo; treated as a target,
    /// not a hard cap (the disk fraction is clamped to <1 so it never claims done
    /// before the load step).
    private static let expectedTotalBytes: Int64 = 460_000_000

    // MARK: - Recording session state

    /// Accumulated 16 kHz mono Float32 samples for the current recording.
    private var samples: [Float] = []
    private var isRecording = false

    // MARK: - Constants

    /// The v3 model wants 16 kHz mono Float32.
    private static let sampleRate: Double = 16_000

    public init() {
        let (stream, continuation) = AsyncStream<StreamingPartial>.makeStream()
        partials = stream
        // Batch engine: no partials ever. Finish now so consumers don't block.
        continuation.finish()
    }

    // MARK: - Preparation

    public func prepare() async throws {
        guard Self.isSupportedHardware else { throw ParakeetEngineError.unsupportedHardware }
        // Only load if a *valid* model is already on disk; downloading is
        // UI-driven. A partial/interrupted download can leave the required
        // .mlmodelc directories in place (so `modelsPresentOnDisk` is true)
        // while their contents are incomplete — loading that hangs or fails
        // silently (Issue 3). Validate the actual model contents first and, if
        // the model is broken, wipe it so `assetStatus` reports `.needsDownload`
        // rather than trying to load a corpse.
        guard Self.modelsPresentOnDisk else { return }
        guard await Self.modelDirectoryIsValid() else {
            Self.removeModelCache()
            return
        }
        try await loadModelsIfNeeded()
    }

    /// Loads (or reuses) the CoreML models into a long-lived `AsrManager`.
    /// Idempotent: a second call is a no-op once loaded.
    private func loadModelsIfNeeded() async throws {
        guard !isLoaded else { return }
        // Guard against a partial download bricking the load: a validation pass
        // that actually opens each .mlmodelc catches an incomplete model that
        // mere file-existence checks miss. If it fails, wipe so the caller can
        // re-download instead of hanging on a broken CoreML compile.
        if Self.modelsPresentOnDisk, await Self.modelDirectoryIsValid() == false {
            Self.removeModelCache()
            throw ParakeetEngineError.modelNotLoaded
        }
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

    public func assetStatus(for locale: Locale) async -> ModelAssetStatus {
        guard Self.isSupportedHardware else { return .unsupported }
        if isDownloading {
            return .downloading(progress: downloadProgress)
        }
        if isLoaded || Self.modelsPresentOnDisk {
            return .installed
        }
        return .needsDownload(progress: 0)
    }

    /// Byte-level progress for the active download, or `nil` when not downloading.
    /// Drives the "X van Y MB" text so the UI never looks frozen while the big
    /// ~430 MB encoder file streams in and FluidAudio's per-file fraction sits
    /// still. `downloadedBytes` is measured on disk by the poller.
    public func downloadByteProgress() async -> ModelDownloadByteProgress? {
        guard isDownloading else { return nil }
        return ModelDownloadByteProgress(
            downloadedBytes: downloadedBytes,
            totalBytes: Self.expectedTotalBytes
        )
    }

    public func downloadAssets(for locale: Locale) async throws {
        guard Self.isSupportedHardware else { throw ParakeetEngineError.unsupportedHardware }
        guard !isDownloading else { return }

        // A previous attempt may have left a partial model on disk (Issue 3):
        // wipe anything that doesn't validate before starting so the fresh
        // download isn't skipped by FluidAudio's "already present" shortcut.
        if Self.modelsPresentOnDisk, await Self.modelDirectoryIsValid() == false {
            Self.removeModelCache()
        }

        isDownloading = true
        downloadProgress = 0
        downloadedBytes = 0
        defer {
            isDownloading = false
            downloadedBytes = 0
        }

        // FluidAudio's ProgressHandler is called on an unspecified queue. Its
        // `fractionCompleted` is byte-weighted *within* the download but only
        // spans 0.0–0.5 (compile/load fills 0.5–1.0). We hop back onto the actor
        // to fold it into a monotonic overall fraction.
        let progressHandler: DownloadUtils.ProgressHandler = { [weak self] progress in
            let fraction = progress.fractionCompleted
            Task { [weak self] in await self?.setDownloadProgress(fraction) }
        }

        // Belt-and-suspenders: poll bytes-on-disk so the bar keeps moving even
        // when FluidAudio's per-file fraction is stuck on the encoder file, and
        // so the "X van Y MB" text has real numbers. Also feeds the watchdog.
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshDiskBytes()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { poller.cancel() }

        do {
            try await withDownloadWatchdog {
                try await self.performDownloadAndLoad(progressHandler: progressHandler)
            }
        } catch {
            // Corrupt / partial download: wipe the cache and retry once.
            if Self.isLikelyCorruptDownload(error) {
                Self.removeModelCache()
                downloadProgress = 0
                downloadedBytes = 0
                do {
                    try await withDownloadWatchdog {
                        try await self.performDownloadAndLoad(progressHandler: progressHandler)
                    }
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

    /// Folds FluidAudio's raw fraction into the surfaced `downloadProgress`.
    /// The bar is the max of two independent signals so it always moves and
    /// never jumps backwards:
    ///   • FluidAudio's fraction (byte-weighted download 0–0.5, compile 0.5–1),
    ///   • a disk-bytes fraction (bytes-on-disk ÷ expected total), which sweeps
    ///     smoothly during the long encoder download.
    private func setDownloadProgress(_ value: Double) {
        let fluid = min(max(value, 0), 1)
        let combined = max(fluid, diskFraction())
        // Monotonic: never regress (a per-file retry restarts FluidAudio's byte
        // counter, which would otherwise dip the bar).
        downloadProgress = max(downloadProgress, min(combined, 1))
    }

    /// Re-measures the model directory's byte size and folds it into progress.
    private func refreshDiskBytes() {
        downloadedBytes = Self.directorySize(at: Self.modelCacheDirectory)
        // Keep the bar moving off the disk signal alone even if FluidAudio is
        // quiet on the big encoder file.
        let combined = max(downloadProgress, diskFraction())
        downloadProgress = min(combined, 1)
    }

    /// Disk-derived download fraction, capped below 1 so it never claims "done"
    /// before the model has actually loaded. The download phase is treated as
    /// the first 95% of the bar; the final 5% is the CoreML compile/load.
    private func diskFraction() -> Double {
        guard Self.expectedTotalBytes > 0 else { return 0 }
        let raw = Double(downloadedBytes) / Double(Self.expectedTotalBytes)
        return min(max(raw, 0), 1) * 0.95
    }

    // MARK: - Watchdog

    /// Runs `body`, failing with `.downloadStalled` if neither the surfaced
    /// progress fraction nor the bytes-on-disk grow for longer than
    /// ``watchdogTimeout`` — instead of hanging forever on a wedged download or
    /// a silently-failing load (Issue 3). Cancels `body` when it trips.
    private func withDownloadWatchdog<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: WatchdogOutcome<T>.self) { group in
            group.addTask { .work(try await body()) }
            group.addTask { [weak self] in
                try await self?.watchForStall()
                return .stalled
            }
            defer { group.cancelAll() }

            while let outcome = try await group.next() {
                switch outcome {
                case .work(let value):
                    return value
                case .stalled:
                    throw ParakeetEngineError.downloadStalled
                }
            }
            throw ParakeetEngineError.downloadStalled
        }
    }

    private enum WatchdogOutcome<T: Sendable>: Sendable {
        case work(T)
        case stalled
    }

    /// How long the download/load may make no observable progress before the
    /// watchdog trips.
    private static let watchdogTimeout: TimeInterval = 60

    /// Sleeps in short ticks, tripping (returning) once no progress *and* no
    /// disk-byte growth has been seen for ``watchdogTimeout``. Progress or byte
    /// growth resets the stall clock. Returns normally to signal a stall; throws
    /// `CancellationError` when the work task wins the race first.
    private func watchForStall() async throws {
        let tick: UInt64 = 1_000_000_000  // 1s
        var lastProgress = downloadProgress
        var lastBytes = downloadedBytes
        var lastAdvance = Date()

        while true {
            try await Task.sleep(nanoseconds: tick)
            let sample = Self.watchdogSample(
                lastProgress: lastProgress,
                lastBytes: lastBytes,
                currentProgress: downloadProgress,
                currentBytes: downloadedBytes,
                secondsSinceLastAdvance: Date().timeIntervalSince(lastAdvance),
                timeout: Self.watchdogTimeout
            )
            if sample.advanced {
                lastProgress = downloadProgress
                lastBytes = downloadedBytes
                lastAdvance = Date()
            }
            if sample.stalled { return }
        }
    }

    // MARK: - Audio format

    public func bestAudioFormat() async -> AVAudioFormat? {
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

    public func startStreaming(locale: Locale) async throws {
        guard Self.isSupportedHardware else { throw ParakeetEngineError.unsupportedHardware }
        try await loadModelsIfNeeded()
        guard isLoaded else { throw ParakeetEngineError.modelNotLoaded }

        samples.removeAll(keepingCapacity: true)
        isRecording = true
    }

    public func feed(_ buffer: AudioBufferBox) async {
        guard isRecording else { return }
        guard let chunk = Self.floatSamples(from: buffer.buffer) else { return }
        samples.append(contentsOf: chunk)
    }

    public func finalize() async throws -> TranscriptionResult {
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

    public func cancel() async {
        isRecording = false
        samples.removeAll(keepingCapacity: false)
    }

    /// Transcribes pre-decoded 16 kHz mono Float32 samples (M3 file import).
    /// FluidAudio chunks long input internally via its sliding-window pipeline,
    /// so no manual chunking is needed even for hour-long recordings.
    public func transcribeSamples(_ samples: [Float], locale: Locale) async throws -> TranscriptionResult {
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

    public func transcribeFile(at url: URL, locale: Locale) async throws -> TranscriptionResult {
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

    /// Deep validation of the on-disk model: opens each required `.mlmodelc`
    /// via FluidAudio's `isModelValid`, which catches a partial/interrupted
    /// download whose directories exist but whose CoreML contents are incomplete
    /// (the Issue 3 brick). Returns `false` on any load failure. Slower than
    /// `modelsExist` (it compiles the models), so it is only called at the
    /// download/load decision points, not on every status poll.
    private static func modelDirectoryIsValid() async -> Bool {
        ((try? await AsrModels.isModelValid(version: .v3)) ?? false)
    }

    /// Total byte size of everything under `dir` (recursively). Used to measure
    /// download progress on disk independently of FluidAudio's own reporting.
    /// Returns 0 if the directory doesn't exist yet. `public` so it is unit-
    /// testable against a fixture directory.
    public static func directorySize(at dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Pure watchdog decision, factored out for unit testing. Given the last
    /// observed progress/byte samples and how long since the last observed
    /// advance, decides whether the download has *advanced* (reset the clock)
    /// and whether it has *stalled* (exceeded the timeout with no advance).
    ///
    /// - Returns: `advanced` — progress fraction or disk bytes grew since the
    ///   last sample; `stalled` — no advance for at least `timeout` seconds.
    /// `public` so the decision logic is unit-testable without a live download.
    public static func watchdogSample(
        lastProgress: Double,
        lastBytes: Int64,
        currentProgress: Double,
        currentBytes: Int64,
        secondsSinceLastAdvance: TimeInterval,
        timeout: TimeInterval
    ) -> (advanced: Bool, stalled: Bool) {
        let advanced = currentProgress > lastProgress || currentBytes > lastBytes
        let stalled = !advanced && secondsSinceLastAdvance >= timeout
        return (advanced, stalled)
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
        // Already a typed engine error (e.g. the watchdog's `.downloadStalled`):
        // pass it straight through so its Dutch message survives.
        if let engineError = error as? ParakeetEngineError { return engineError }
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
