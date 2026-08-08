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

/// Een na een procesonderbreking teruggevonden microfoonopname. Alleen de
/// transcriptie en minimale metadata verlaten de herstelroutine; de aanroeper
/// verwijdert de tijdelijke audio pas na duurzame opslag van het transcript.
public struct RecoveredRecording: Sendable, Equatable {
    public let recoveryID: String
    public let result: TranscriptionResult
    public let createdAt: Date
    public let duration: Double
    public let language: TranscriptionLanguage

    public init(
        recoveryID: String,
        result: TranscriptionResult,
        createdAt: Date,
        duration: Double,
        language: TranscriptionLanguage
    ) {
        self.recoveryID = recoveryID
        self.result = result
        self.createdAt = createdAt
        self.duration = duration
        self.language = language
    }
}

public struct RecordingRecoveryBatch: Sendable, Equatable {
    public let recordings: [RecoveredRecording]
    public let failedCount: Int

    public init(recordings: [RecoveredRecording], failedCount: Int) {
        self.recordings = recordings
        self.failedCount = failedCount
    }
}

/// NVIDIA Parakeet TDT 0.6b v3 (multilingual, incl. Dutch) via the FluidAudio
/// Swift package, running Apple-Silicon CoreML on-device.
///
/// ## Streaming vs batch — why this engine is batch-only
/// FluidAudio only exposes true low-latency streaming (`StreamingAsrManager` /
/// Parakeet EOU, Nemotron, Unified) for **English** models. The multilingual v3
/// model this app needs for Dutch is an *offline* encoder; it has no cache-aware
/// streaming path. We therefore spool 16 kHz mono audio to one protected
/// temporary file during capture and run one
/// `AsrManager.transcribe(_:decoderState:)` call in ``finalize()``. FluidAudio
/// handles long files through its disk-backed path, so memory does not grow with
/// the recording duration. At the model's ~100x realtime factor a 30 s clip
/// transcribes in well under the 1.5 s stop→clipboard budget. In this mode we
/// emit **no** partials — the HUD
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

    /// Lopende microfoonopnamen worden naar één tijdelijk, beschermd CAF-bestand
    /// geschreven. Zo groeit het werkgeheugen niet met de opnameduur; FluidAudio
    /// gebruikt bij lange bestanden daarna zijn disk-backed transcriptiepad.
    private var recordingFile: AVAudioFile?
    private var recordingFileURL: URL?
    private var recordedSampleCount = 0
    private var recordingWriteError: String?
    private var isRecording = false
    /// Taalhint van de lopende opname. `nil` betekent echte automatische
    /// meertalige detectie; NL/EN/DE sturen FluidAudio's v3-tokenfilter.
    private var recordingLanguage: Language?

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

        try await downloadWithRetry(progressHandler: progressHandler)
    }

    /// Drives the download/load through a bounded retry-with-backoff loop so a
    /// stalled or dropped connection recovers on its own instead of surfacing a
    /// hard failure to the UI — the fix for the ~425 MB encoder file that
    /// reliably stalls partway on iOS over wifi/cellular.
    ///
    /// ## Why retrying makes progress (no in-process resume-data plumbing)
    /// FluidAudio owns the actual transport (`URLSession.download(for:)`, no
    /// resume data) and is a vendored SPM dependency we can't edit. But its
    /// `downloadRepo` **skips any file already on disk** and only moves a file
    /// to its final path once fully downloaded. So every file that *did*
    /// complete (preprocessor, decoder, joint, vocab — and the encoder itself
    /// once it finally lands) persists across attempts; a retry re-lists the
    /// repo, finds those present, and only re-fetches what's still missing. Each
    /// attempt therefore gives the big encoder file a fresh full watchdog window
    /// rather than restarting the *whole* model set from zero. This is the
    /// feasible recovery given a third-party downloader without resume support.
    ///
    /// Progress is deliberately **not** reset between attempts: `downloadProgress`
    /// is monotonic and the disk-bytes poller keeps measuring real bytes-on-disk,
    /// so the bar and the "X van Y MB" text continue from where they were instead
    /// of snapping back to 0% on each retry.
    private func downloadWithRetry(progressHandler: @escaping DownloadUtils.ProgressHandler) async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await withDownloadWatchdog {
                    try await self.performDownloadAndLoad(progressHandler: progressHandler)
                }
                return
            } catch {
                // A partial/corrupt on-disk model can't be resumed — it must be
                // wiped so the next attempt re-downloads cleanly. That resets the
                // disk-bytes signal, so drop the surfaced fraction too (the bar is
                // monotonic and would otherwise stay pinned high over an empty
                // cache).
                if Self.isLikelyCorruptDownload(error) {
                    Self.removeModelCache()
                    downloadProgress = 0
                    downloadedBytes = 0
                }

                // Out of attempts, or an error a retry can't fix (e.g. offline
                // with no connectivity): surface it in Dutch.
                guard attempt < Self.maxDownloadAttempts, Self.isRecoverableDownloadError(error) else {
                    throw Self.mapDownloadError(error)
                }

                // Back off before the next attempt: 2s, 4s, 8s… capped. Gives a
                // flaky connection a moment to recover rather than hammering it.
                let backoff = Self.retryBackoff(forAttempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
    }

    // MARK: - Retry policy

    /// How many download/load attempts to make before surfacing a final failure.
    /// The first is the initial try; the rest are watchdog/network-triggered
    /// retries with backoff.
    static let maxDownloadAttempts = 5

    /// Exponential backoff (seconds) before retry `attempt` (1-based): 2, 4, 8,
    /// 16… capped at 30s so a long-flaky connection still retries reasonably
    /// promptly. `public`/`static` so it is unit-testable in isolation.
    public static func retryBackoff(forAttempt attempt: Int) -> TimeInterval {
        let raw = pow(2.0, Double(max(attempt, 1))) // attempt 1 → 2s
        return min(raw, 30)
    }

    /// Whether a failed attempt is worth retrying. Retryable: the stall-watchdog
    /// firing (`.downloadStalled`), a corrupt/partial download (a wipe-and-retry
    /// fixes it), and transient network errors (connection lost/timeout/host
    /// unreachable). Not retryable: a hard offline state with no route to the
    /// network, which no amount of retrying will fix — surface it immediately so
    /// the user knows to reconnect. `public`/`static` so the classification is
    /// unit-testable without a live download.
    public static func isRecoverableDownloadError(_ error: Error) -> Bool {
        // The watchdog tripping is the primary retry trigger — the attempt got
        // stuck, so cancel and try again with a fresh window.
        if let engineError = error as? ParakeetEngineError {
            switch engineError {
            case .downloadStalled:
                return true
            case .noNetwork:
                // Fully offline: retrying without connectivity is pointless.
                return false
            default:
                return false
            }
        }
        if isLikelyCorruptDownload(error) { return true }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                // No network at all: don't burn retries on it.
                return false
            case NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorResourceUnavailable,
                 NSURLErrorSecureConnectionFailed:
                // Transient connectivity blips: a resume/retry can recover.
                return true
            default:
                return false
            }
        }
        return false
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

        removeRecordingFile()
        guard let format = await bestAudioFormat() else {
            throw ParakeetEngineError.transcriptionFailed("Audioformaat niet beschikbaar")
        }
        let language = TranscriptionLanguage(locale: locale)
        let fileURL = Self.makeRecordingFileURL(language: language)
        do {
            recordingFile = try AVAudioFile(
                forWriting: fileURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw ParakeetEngineError.transcriptionFailed(error.localizedDescription)
        }
        recordingFileURL = fileURL
        recordedSampleCount = 0
        recordingWriteError = nil
        recordingLanguage = Self.languageHint(for: language.locale)
        isRecording = true
    }

    /// Schrijffout van de lopende opname, of `nil` zolang alles goed gaat. De
    /// app-laag pollt dit tijdens het opnemen (bestaande ticker) zodat de
    /// gebruiker gewaarschuwd wordt in plaats van tien minuten in een dode
    /// recorder te praten (bevinding 2026-08-03).
    public var recordingWriteFailure: String? { recordingWriteError }

    /// Wanneer `true` laat ``finalize()`` het tijdelijke opnamebestand ná een
    /// geslaagde transcriptie staan en geeft het pad terug, zodat de aanroeper er
    /// een blijvende kopie van kan maken. Standaard `false`: dan blijft het
    /// gedrag ongewijzigd en wordt de audio opgeruimd.
    private var preserveFinishedRecording = false

    public func setPreserveFinishedRecording(_ preserve: Bool) {
        preserveFinishedRecording = preserve
    }

    public func feed(_ buffer: AudioBufferBox) async {
        // Bewust géén guard op `recordingWriteError`: één mislukte write mag de
        // rest van de sessie niet stilleggen, want dan blijft de opname wel
        // lopen terwijl er niets meer op schijf komt. We blijven schrijven zodat
        // een tijdelijke fout vanzelf herstelt en bewaren alleen de eerste fout
        // als melding (bevinding 2026-08-03).
        guard isRecording, let recordingFile else { return }
        do {
            try recordingFile.write(from: buffer.buffer)
            recordedSampleCount += Int(buffer.buffer.frameLength)
        } catch {
            if recordingWriteError == nil {
                recordingWriteError = error.localizedDescription
            }
        }
    }

    public func finalize() async throws -> TranscriptionResult {
        guard isRecording else { throw ParakeetEngineError.notRecording }
        isRecording = false

        guard let manager else { throw ParakeetEngineError.modelNotLoaded }

        let fileURL = recordingFileURL
        let capturedSampleCount = recordedSampleCount
        let writeError = recordingWriteError
        let language = recordingLanguage
        // AVAudioFile sluit en flushes zodra de laatste sterke referentie weg is.
        recordingFile = nil
        recordingFileURL = nil
        recordedSampleCount = 0
        recordingWriteError = nil
        recordingLanguage = nil

        guard let fileURL else {
            throw ParakeetEngineError.transcriptionFailed("Tijdelijke audio ontbreekt")
        }
        // Geen blanket `defer` meer op het verwijderen: die gooide de enige kopie
        // van de opname óók weg bij een mislukte transcriptie, waardoor
        // `recoverOrphanedRecordings` bij de volgende start niets meer kon
        // aanbieden (bevinding 2026-08-03). Elk pad verwijdert nu expliciet.

        // Te weinig audio om te transcriberen: leeg resultaat (de controller
        // meldt dan "Geen spraak herkend"). Hier valt niets te herstellen, dus
        // het bestand mag weg.
        //
        // Eén uitzondering: ging het schrijven al bij de eerste buffers mis, dan
        // is er geen spraak omdát de opname stukliep. Dat moet als storing
        // terugkomen en niet als "je hebt niets gezegd" (bevinding 2026-08-03).
        guard capturedSampleCount >= Int(Self.sampleRate * 0.3) else {
            try? FileManager.default.removeItem(at: fileURL)
            guard let writeError else { return .empty }
            return TranscriptionResult(text: "", segments: [], partialFailure: writeError)
        }

        do {
            var state = TdtDecoderState.make(decoderLayers: 2)
            let result = try await manager.transcribe(
                fileURL,
                decoderState: &state,
                language: language
            )
            let segments = Self.segments(from: result)
            // Pas ná een geslaagde transcriptie verwijderen — tenzij de aanroeper
            // een kopie wil bewaren. Dan blijft het bestand staan en wordt hij er
            // eigenaar van (bevinding 2026-08-03).
            guard !preserveFinishedRecording else {
                return TranscriptionResult(
                    text: result.text,
                    segments: segments,
                    audioDuration: Double(capturedSampleCount) / Self.sampleRate,
                    partialFailure: writeError,
                    preservedAudioURL: fileURL
                )
            }
            try? FileManager.default.removeItem(at: fileURL)
            // Een schrijffout onderweg maakt de opname niet waardeloos: wat wél
            // is weggeschreven is nu getranscribeerd, en de storing gaat als
            // melding mee in plaats van als throw (bevinding 2026-08-03).
            return TranscriptionResult(
                text: result.text,
                segments: segments,
                audioDuration: Double(capturedSampleCount) / Self.sampleRate,
                partialFailure: writeError
            )
        } catch {
            // Bestand bewust laten staan zodat `recoverOrphanedRecordings` de
            // opname bij een volgende start opnieuw kan aanbieden
            // (bevinding 2026-08-03).
            throw ParakeetEngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    public func cancel() async {
        isRecording = false
        recordingLanguage = nil
        removeRecordingFile()
    }

    /// Herstelt tijdelijke microfoonaudio die alleen kan zijn achtergebleven
    /// doordat het proces tijdens een opname is beëindigd. Geslaagde en te korte
    /// bestanden worden verwijderd; een technisch mislukt bestand blijft staan
    /// zodat een volgende appstart opnieuw kan proberen.
    public func recoverOrphanedRecordings(
        defaultLocale: Locale
    ) async throws -> RecordingRecoveryBatch {
        let urls = Self.orphanedRecordingURLs()
        guard !urls.isEmpty else {
            return RecordingRecoveryBatch(recordings: [], failedCount: 0)
        }

        try await loadModelsIfNeeded()
        guard let manager else { throw ParakeetEngineError.modelNotLoaded }

        var recovered: [RecoveredRecording] = []
        var failedCount = 0
        for url in urls {
            do {
                let audioFile = try AVAudioFile(forReading: url)
                let sampleRate = audioFile.processingFormat.sampleRate
                let duration = sampleRate > 0 ? Double(audioFile.length) / sampleRate : 0
                guard duration >= 0.3 else {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }

                let language = Self.recordingLanguage(
                    from: url,
                    fallback: TranscriptionLanguage(locale: defaultLocale)
                )
                var state = TdtDecoderState.make(decoderLayers: 2)
                let raw = try await manager.transcribe(
                    url,
                    decoderState: &state,
                    language: Self.languageHint(for: language.locale)
                )
                let result = TranscriptionResult(
                    text: raw.text,
                    segments: Self.segments(from: raw)
                )
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let createdAt = attributes?[.creationDate] as? Date ?? Date()
                recovered.append(RecoveredRecording(
                    recoveryID: url.lastPathComponent,
                    result: result,
                    createdAt: createdAt,
                    duration: duration,
                    language: language
                ))
            } catch {
                failedCount += 1
            }
        }
        return RecordingRecoveryBatch(recordings: recovered, failedCount: failedCount)
    }

    /// Verwijdert één eerder getranscribeerd herstelbestand pas nadat de
    /// aanroeper het transcript duurzaam heeft opgeslagen. De vaste prefix en
    /// bestandsnaamcontrole voorkomen dat een ander tijdelijk bestand geraakt.
    public func discardRecoveredRecording(id: String) {
        guard id.hasPrefix(Self.recordingFilePrefix),
              URL(fileURLWithPath: id).lastPathComponent == id else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: url)
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
            let result = try await manager.transcribe(
                samples,
                decoderState: &state,
                language: Self.languageHint(for: locale)
            )
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
            let result = try await manager.transcribe(
                url,
                decoderState: &state,
                language: Self.languageHint(for: locale)
            )
            return TranscriptionResult(text: result.text, segments: Self.segments(from: result))
        } catch {
            throw ParakeetEngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// FluidAudio v3 ondersteunt een script-/taalhint. Voor `und` en onbekende
    /// talen blijft die bewust `nil`, zodat automatische detectie actief blijft.
    public static func languageHint(for locale: Locale) -> Language? {
        switch TranscriptionLanguage(locale: locale) {
        case .automatic: nil
        case .dutch: .dutch
        case .english: .english
        case .german: .german
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

    // MARK: - Tijdelijke microfoonaudio

    static let recordingFilePrefix = "whisperclip-live-recording-"

    static func makeRecordingFileURL(language: TranscriptionLanguage) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(recordingFilePrefix)\(language.rawValue)-\(UUID().uuidString).caf"
            )
    }

    private func removeRecordingFile() {
        recordingFile = nil
        if let recordingFileURL {
            try? FileManager.default.removeItem(at: recordingFileURL)
        }
        recordingFileURL = nil
        recordedSampleCount = 0
        recordingWriteError = nil
    }

    private static func orphanedRecordingURLs() -> [URL] {
        let directory = FileManager.default.temporaryDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return [] }
        return urls.filter { $0.lastPathComponent.hasPrefix(recordingFilePrefix) }
            .sorted { lhs, rhs in
                let left = try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate
                let right = try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate
                return (left ?? .distantPast) < (right ?? .distantPast)
            }
    }

    static func recordingLanguage(
        from url: URL,
        fallback: TranscriptionLanguage
    ) -> TranscriptionLanguage {
        let filename = url.deletingPathExtension().lastPathComponent
        guard filename.hasPrefix(recordingFilePrefix) else { return fallback }
        let suffix = filename.dropFirst(recordingFilePrefix.count)
        guard let code = suffix.split(separator: "-").first, !code.isEmpty else {
            return fallback
        }
        let value = String(code)
        guard TranscriptionLanguage.allCases.contains(where: { $0.rawValue == value }) else {
            return fallback
        }
        return TranscriptionLanguage(metadataCode: value)
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
