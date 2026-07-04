import Core
import FluidAudio
import Foundation
import WhisperShared

/// Errors from the FluidAudio diarizer backend, surfaced in Dutch.
enum DiarizationError: LocalizedError {
    case unsupportedHardware
    case modelNotLoaded
    case diarizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedHardware:
            return "Sprekerherkenning vereist een Mac met Apple Silicon (M-serie)."
        case .modelNotLoaded:
            return "Het sprekermodel is nog niet geladen."
        case .diarizationFailed(let detail):
            return "Sprekerherkenning mislukte: \(detail)"
        }
    }
}

/// Wraps FluidAudio's `DiarizerManager` (Pyannote segmentation + WeSpeaker
/// embedding CoreML models) to answer "who spoke when" for a decoded audio clip.
///
/// ## Model cache & size
/// The two CoreML models live in the same Application Support cache FluidAudio
/// uses for the ASR models:
/// `~/Library/Application Support/FluidAudio/Models/speaker-diarization/`
/// (`pyannote_segmentation.mlmodelc` ≈5.7 MB + `wespeaker_v2.mlmodelc` ≈8.1 MB,
/// plus small JSON config — ~14 MB total). Far smaller than the ~460 MB
/// Parakeet v3 ASR model, so first-use download is quick.
///
/// ## Memory
/// A single `DiarizerManager` is loaded once and kept alive (the CoreML models
/// stay resident, a few tens of MB). Diarization streams the input in 10-second
/// chunks internally, so peak memory is bounded by one chunk plus the input
/// sample array, not by any O(n²) blow-up.
///
/// An actor so the loaded manager and download state live on one isolation
/// domain, mirroring ``ParakeetEngine``.
actor DiarizationService {

    private var manager: DiarizerManager?
    private var isLoaded = false

    private var downloadProgress: Double = 0
    private var isDownloading = false

    /// 16 kHz mono Float32 — the rate the decode pipeline already produces and
    /// the rate the diarizer models expect.
    private static let sampleRate = 16_000

    // MARK: - Availability

    /// Whether the diarizer models are already on disk (no network needed).
    static var modelsPresentOnDisk: Bool {
        let dir = modelCacheDirectory
        return DiarizerModels.requiredModelNames.allSatisfy { name in
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
        }
    }

    /// `~/Library/Application Support/FluidAudio/Models/speaker-diarization-coreml/`
    static var modelCacheDirectory: URL {
        DiarizerModels.defaultModelsDirectory()
    }

    /// Current asset status, so UI/pipeline can decide whether a download is
    /// needed before running.
    func assetStatus() -> ModelAssetStatus {
        guard SystemInfo.isAppleSilicon else { return .unsupported }
        if isDownloading { return .downloading(progress: downloadProgress) }
        if isLoaded || Self.modelsPresentOnDisk { return .installed }
        return .needsDownload(progress: 0)
    }

    // MARK: - Loading

    /// Ensures the diarizer models are downloaded (if needed) and loaded into a
    /// live manager. Idempotent. `progress` receives a 0…1 download fraction.
    func ensureReady(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard SystemInfo.isAppleSilicon else { throw DiarizationError.unsupportedHardware }
        guard !isLoaded else { return }

        isDownloading = !Self.modelsPresentOnDisk
        downloadProgress = 0
        defer { isDownloading = false }

        let handler: DownloadUtils.ProgressHandler = { p in
            let fraction = p.fractionCompleted
            progress(fraction)
        }

        do {
            // `DiarizerModels.download` downloads on demand and always loads;
            // when the files already exist it just loads them (no network).
            let models = try await DiarizerModels.download(progressHandler: handler)
            let manager = DiarizerManager(config: .default)
            manager.initialize(models: consume models)
            self.manager = manager
            self.isLoaded = true
            self.downloadProgress = 1
        } catch {
            throw DiarizationError.diarizationFailed(error.localizedDescription)
        }
    }

    // MARK: - Diarization

    /// Runs diarization on 16 kHz mono Float32 samples and returns the speaker
    /// turns (start/end/rawSpeakerId), sorted by start time. Loads the models
    /// first if necessary.
    func diarize(
        samples: [Float],
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [SpeakerTurn] {
        try await ensureReady(progress: progress)
        guard let manager else { throw DiarizationError.modelNotLoaded }

        do {
            let result = try manager.performCompleteDiarization(
                samples,
                sampleRate: Self.sampleRate
            )
            return result.segments
                .map {
                    SpeakerTurn(
                        start: Double($0.startTimeSeconds),
                        end: Double($0.endTimeSeconds),
                        speakerId: $0.speakerId
                    )
                }
                .sorted { $0.start < $1.start }
        } catch {
            throw DiarizationError.diarizationFailed(error.localizedDescription)
        }
    }
}
