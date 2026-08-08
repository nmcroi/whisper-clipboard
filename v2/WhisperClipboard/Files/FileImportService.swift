import AVFoundation
import Core
import Foundation
import Observation
import UniformTypeIdentifiers
import WhisperShared

// MARK: - Supported media types

/// The media container/codec types the file-import pipeline accepts. Mirrors the
/// Python app's `SUPPORTED_MEDIA_SUFFIXES` (mp3/mp4/m4a/wav/mov) plus a few extra
/// audio containers AVFoundation decodes trivially (aac/aiff/caf).
enum SupportedMedia {
    /// Lower-cased file extensions (no leading dot) the importer accepts.
    static let extensions: Set<String> = [
        "mp3", "mp4", "m4a", "wav", "mov", "aac", "aiff", "aif", "caf", "opus",
    ]

    /// `UTType`s for the `NSOpenPanel` allowed-content-types and drop validation.
    static let contentTypes: [UTType] = [
        .mp3, .mpeg4Movie, .mpeg4Audio, .wav, .quickTimeMovie, .aiff,
        UTType("public.aac-audio"), UTType(filenameExtension: "caf"),
        UTType(filenameExtension: "opus"),
    ].compactMap { $0 }

    /// Whether `url`'s extension is supported (pure, case-insensitive).
    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}

// MARK: - Import errors (Dutch, user-facing)

enum FileImportError: LocalizedError {
    case unsupportedType
    case fileMissing
    case decodeFailed(String)
    case transcriptionFailed(String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .unsupportedType:
            return "Kies een mp3-, mp4-, m4a-, wav- of mov-bestand."
        case .fileMissing:
            return "Het gekozen audio- of videobestand bestaat niet meer."
        case .decodeFailed(let detail):
            return "Het bestand kon niet worden gelezen: \(detail)"
        case .transcriptionFailed(let detail):
            return "Transcriptie mislukte: \(detail)"
        case .emptyTranscript:
            return "Geen spraak herkend in dit bestand."
        }
    }
}

// MARK: - Job model

/// One queued import job, observable so the Home queue panel reflects live state.
@MainActor
@Observable
final class ImportJob: Identifiable {
    enum State: Equatable {
        case waiting
        case decoding(progress: Double)
        case transcribing
        /// Running speaker diarization after transcription. `progress` is the
        /// model-download fraction on first use, or nil once models are cached.
        case diarizing(progress: Double?)
        case done
        case failed(message: String)

        var isTerminal: Bool {
            switch self {
            case .done, .failed: return true
            case .waiting, .decoding, .transcribing, .diarizing: return false
            }
        }
    }

    let id = UUID()
    let url: URL
    /// The history `source` tag for the resulting transcript ("file" for a normal
    /// import, "plaud" for a PLAUD cloud sync). Defaults to "file".
    let source: String
    /// User-facing history title. PLAUD filenames contain a date, record id and
    /// sometimes a literal `.opus`; none of that belongs in the visible title.
    var displayName: String {
        guard source == "plaud" else { return url.deletingPathExtension().lastPathComponent }
        let stem = url.deletingPathExtension().lastPathComponent
        let withoutDate = Self.plaudDate(from: stem) == nil ? stem : String(stem.dropFirst(16))
        let withoutShortID = withoutDate.replacingOccurrences(
            of: #"_[0-9a-fA-F]{8}$"#,
            with: "",
            options: .regularExpression
        )
        let cleaned = withoutShortID.replacingOccurrences(of: ".opus", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let looksTechnical = cleaned.range(of: #"^[0-9a-fA-F]{20,}$"#, options: .regularExpression) != nil
        return cleaned.isEmpty || looksTechnical ? "" : cleaned
    }

    /// Original PLAUD recording time encoded by `suggestedFilenameStem`.
    var originalRecordingDate: Date? {
        source == "plaud" ? Self.plaudDate(from: url.deletingPathExtension().lastPathComponent) : nil
    }
    var state: State

    init(url: URL, source: String = "file", state: State = .waiting) {
        self.url = url
        self.source = source
        self.state = state
    }

    private static func plaudDate(from stem: String) -> Date? {
        guard stem.count >= 15 else { return nil }
        let prefix = String(stem.prefix(15))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter.date(from: prefix)
    }
}

// MARK: - Service

/// Sequential file-import → transcription pipeline.
///
/// Jobs are queued and processed one at a time (matching the Python app's
/// "one job at a time" guard). Each job is decoded to 16 kHz mono Float32 via
/// AVFoundation, transcribed by Parakeet, stored in history, and copied to the
/// clipboard with a Dutch notification.
///
/// ## Long audio
/// FluidAudio's `AsrManager.transcribe(_ samples:)` chunks long input internally
/// via its sliding-window pipeline (see `AsrManager+Transcription`), so a 1-hour
/// recording needs no manual chunking here — we hand it the full sample array and
/// let FluidAudio window it. Decoding itself streams frame-by-frame with a bounded
/// converter buffer, so memory stays proportional to the decoded PCM, not to any
/// intermediate copies.
@MainActor
@Observable
final class FileImportService {

    /// The live job queue (newest last). The UI renders this directly.
    private(set) var jobs: [ImportJob] = []

    /// True while a job is decoding or transcribing.
    private(set) var isBusy = false

    // Dependencies.
    private let engine: ParakeetEngine
    /// Speaker diarization (who-spoke-when) for imports. Optional so tests and
    /// non-Apple-Silicon builds can omit it; when nil, imports never diarize.
    private let diarizer: DiarizationService?
    private let history: HistoryStore
    private let locale: () -> Locale
    /// Current app settings, read on demand so the personal woordenlijst
    /// (replacements) and the clean-output toggle are applied to imported files
    /// exactly as they are to dictation.
    private let settings: () -> AppSettings
    /// Guard predicate: returns a Dutch reason string when import must be refused
    /// (e.g. dictation is recording/transcribing), or nil when clear to proceed.
    private let busyReason: () -> String?
    private let notify: (String) -> Void
    private let copyToClipboard: (String) -> Void

    /// Invoked with each transcript entry just after it is stored in history, so
    /// a completed import can trigger auto-export (M7). Nil-safe. Runs on the main
    /// actor; must never throw (auto-export is best-effort).
    var onTranscriptStored: ((TranscriptEntry) -> Void)?

    /// Seconds a finished job lingers in the queue before auto-clearing.
    static let autoClearDelay: Double = 4

    init(
        engine: ParakeetEngine,
        history: HistoryStore,
        locale: @escaping () -> Locale,
        busyReason: @escaping () -> String?,
        diarizer: DiarizationService? = nil,
        settings: @escaping () -> AppSettings = { AppSettings() },
        notify: @escaping (String) -> Void = { Notifications.post($0) },
        copyToClipboard: @escaping (String) -> Void = { Clipboard.copy($0) }
    ) {
        self.engine = engine
        self.diarizer = diarizer
        self.history = history
        self.locale = locale
        self.settings = settings
        self.busyReason = busyReason
        self.notify = notify
        self.copyToClipboard = copyToClipboard
    }

    // MARK: - Public entry points

    /// Enqueues `urls` for import. Unsupported files are rejected immediately with
    /// a Dutch notification. Refuses entirely (with a notification) while dictation
    /// is active. Returns the jobs actually enqueued.
    ///
    /// `source` tags the resulting history entries ("file" for a normal import,
    /// "plaud" for a PLAUD cloud sync); it does not change the pipeline otherwise.
    @discardableResult
    func importFiles(_ urls: [URL], source: String = "file") -> [ImportJob] {
        if let reason = busyReason() {
            notify(reason)
            return []
        }

        var enqueued: [ImportJob] = []
        for url in urls {
            guard SupportedMedia.isSupported(url) else {
                notify(FileImportError.unsupportedType.errorDescription ?? "Niet-ondersteund bestand.")
                continue
            }
            let job = ImportJob(url: url, source: source)
            jobs.append(job)
            enqueued.append(job)
        }

        if !enqueued.isEmpty {
            drainQueue()
        }
        return enqueued
    }

    /// Enqueues a batch and waits until every accepted job is either safely
    /// stored or definitively failed. PLAUD uses this so it never records a
    /// download as processed merely because it entered the queue.
    func importFilesAndWait(_ urls: [URL], source: String = "file") async -> [URL] {
        let acceptedJobs = importFiles(urls, source: source)
        guard !acceptedJobs.isEmpty else { return [] }
        while acceptedJobs.contains(where: { !$0.state.isTerminal }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return acceptedJobs.compactMap { job in
            switch job.state {
            case .done:
                return job.url
            case .failed(let message)
                where job.source == "plaud"
                    && message == FileImportError.emptyTranscript.errorDescription:
                // Silence is a terminal, successfully inspected PLAUD item. It
                // must not be downloaded again every time the user dismisses it.
                return job.url
            default:
                return nil
            }
        }
    }

    /// Re-runs a failed job (retry button).
    func retry(_ job: ImportJob) {
        guard case .failed = job.state else { return }
        job.state = .waiting
        drainQueue()
    }

    /// Removes a job from the queue (manual dismiss).
    func remove(_ job: ImportJob) {
        jobs.removeAll { $0.id == job.id }
    }

    // MARK: - Queue processing

    private var isDraining = false
    private var drainTask: Task<Void, Never>?

    /// Processes waiting jobs one at a time until none remain.
    private func drainQueue() {
        guard !isDraining else { return }
        isDraining = true
        drainTask = Task { [weak self] in
            await self?.runDrainLoop()
        }
    }

    /// Stops PLAUD work immediately without disturbing ordinary user-selected
    /// imports. Used by the PLAUD Stop button and by disabling automatic sync.
    func cancelPlaudImports() {
        if jobs.contains(where: { $0.source == "plaud" && !$0.state.isTerminal }) {
            drainTask?.cancel()
        }
        jobs.removeAll { $0.source == "plaud" }
        isDraining = false
        isBusy = false
    }

    private func runDrainLoop() async {
        defer { isDraining = false; isBusy = false }
        while let job = jobs.first(where: { $0.state == .waiting }) {
            isBusy = true
            await process(job)
        }
    }

    private func process(_ job: ImportJob) async {
        var tempURL: URL?
        do {
            job.state = .decoding(progress: 0)
            // AVAssetReader-based decode: handles both audio-only containers and
            // the audio track of video containers (mp4/mov), streaming to a
            // temporary 16 kHz mono Float32 WAV (constant memory regardless of
            // file length).
            let decoded = try await AudioFileDecoder.decodeToTemporaryWAV(from: job.url) { [weak job] fraction in
                Task { @MainActor in
                    if case .decoding = job?.state { job?.state = .decoding(progress: fraction) }
                }
            }
            tempURL = decoded.url

            job.state = .transcribing
            let samples = try AudioSampleConverter.readSamples(fromWAV: decoded.url)
            let result = try await engine.transcribeSamples(samples, locale: locale())

            // Apply the same post-processing as dictation: the personal
            // woordenlijst (whole-word replacements) first, optional filler
            // removal, then optional cleanup.
            let config = settings()
            let text = TextProcessor.process(
                result.text,
                replacements: config.replacements,
                clean: config.cleanOutput,
                removeFillers: config.removeFillers,
                language: locale().language.languageCode?.identifier ?? "nl"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw FileImportError.emptyTranscript
            }

            // Optional speaker diarization. Never fails the import: on any
            // diarizer error we log and keep the transcript without speakers.
            let segments = await diarizeIfEnabled(
                job: job,
                segments: result.segments,
                samples: samples,
                duration: decoded.duration
            )

            try store(
                text: text,
                segments: segments,
                duration: decoded.duration,
                name: job.displayName,
                source: job.source,
                createdAt: job.originalRecordingDate ?? Date()
            )
            copyToClipboard(text)
            job.state = .done
            notify("\(job.url.lastPathComponent) is getranscribeerd en gekopieerd")
            scheduleAutoClear(job)
        } catch {
            if error is CancellationError {
                jobs.removeAll { $0.id == job.id }
                if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
                return
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            job.state = .failed(message: message)
            notify(message)
            if job.source == "plaud",
               message == FileImportError.emptyTranscript.errorDescription {
                scheduleSilentPlaudClear(job)
            }
        }
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    /// Minimum source duration (seconds) worth diarizing. Short clips rarely
    /// have multiple speakers and diarization on <10s is unreliable.
    private static let minDiarizeDuration: Double = 10

    /// Runs speaker diarization + merge when enabled and applicable, returning
    /// the (possibly speaker-labelled) segments. Guarantees it never throws:
    /// any failure logs and returns the original segments unchanged.
    private func diarizeIfEnabled(
        job: ImportJob,
        segments: [Core.TranscriptSegment],
        samples: [Float],
        duration: Double
    ) async -> [Core.TranscriptSegment] {
        guard settings().speakerRecognitionEnabled else { return segments }
        guard let diarizer else { return segments }
        guard duration >= Self.minDiarizeDuration else { return segments }
        guard !segments.isEmpty else { return segments }

        job.state = .diarizing(progress: nil)

        // Only surface a download fraction on first use (models not yet cached).
        let needsDownload = !DiarizationService.modelsPresentOnDisk
        let jobId = job.id
        let progressHandler: @Sendable (Double) -> Void = { [weak self] fraction in
            guard needsDownload else { return }
            Task { @MainActor [weak self] in
                guard let self, let job = self.jobs.first(where: { $0.id == jobId }) else { return }
                if case .diarizing = job.state { job.state = .diarizing(progress: fraction) }
            }
        }

        do {
            let turns = try await diarizer.diarize(samples: samples, progress: progressHandler)
            guard !turns.isEmpty else { return segments }
            return SpeakerMerge.assign(segments: segments, turns: turns)
        } catch {
            // Keep the transcript without speakers — diarization is best-effort.
            NSLog("Diarization failed for %@: %@", job.displayName, String(describing: error))
            return segments
        }
    }

    private func store(
        text: String,
        segments: [Core.TranscriptSegment],
        duration: Double,
        name: String,
        source: String = "file",
        createdAt: Date = Date()
    ) throws {
        let entry = TranscriptEntry(
            id: UUID().uuidString,
            text: text,
            createdAt: Self.timestampString(from: createdAt),
            name: name,
            pinned: false,
            language: locale().language.languageCode?.identifier ?? "nl",
            model: "parakeet-tdt-0.6b-v3",
            source: source + ".mac",
            duration: duration,
            segments: segments
        )
        try history.add(entry)
        // Fire the post-store hook (auto-export). Best-effort; the entry is
        // already safely persisted regardless of what this does.
        onTranscriptStored?(entry)
    }

    private func scheduleAutoClear(_ job: ImportJob) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoClearDelay))
            guard let self else { return }
            if job.state == .done { self.remove(job) }
        }
    }

    /// A silent PLAUD recording has been examined successfully, but produces no
    /// history entry. Show the explanation briefly, then clear it: retrying the
    /// same silence is neither useful nor compatible with deleting its local
    /// cache after it is marked processed.
    private func scheduleSilentPlaudClear(_ job: ImportJob) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoClearDelay))
            guard let self else { return }
            if case .failed(let message) = job.state,
               message == FileImportError.emptyTranscript.errorDescription {
                self.remove(job)
            }
        }
    }

    /// ISO-8601 timestamp matching the history store's format (no fractional seconds).
    static func timestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

// MARK: - Audio decoding

/// Reads a mono Float32 WAV (as produced by ``AudioFileDecoder``) back into a
/// flat sample array for handing to the transcription engine. Kept `nonisolated`
/// so it's usable from tests without the `@MainActor` service.
///
/// The actual media decode (including video-track extraction for mp4/mov) is
/// owned by ``AudioFileDecoder``, which streams to a temporary 16 kHz mono
/// Float32 WAV via `AVAssetReader`; plain `AVAudioFile` cannot open video
/// containers directly, so that decode must happen first.
enum AudioSampleConverter {
    static func readSamples(fromWAV url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw FileImportError.decodeFailed(error.localizedDescription)
        }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return []
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw FileImportError.decodeFailed(error.localizedDescription)
        }
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
}

/// Result of a media decode: a temporary 16 kHz mono Float32 WAV and the source
/// audio duration. The caller owns the temp file and must delete it.
struct DecodedMedia: Sendable {
    var url: URL
    var duration: Double
}

/// Decodes any supported media file — including the audio track of video
/// containers (mp4/mov) — to a temporary 16 kHz mono Float32 WAV using
/// `AVAssetReader`. Streaming, so memory stays bounded regardless of file length.
///
/// `AVAssetReader` reads the first audio track and outputs decompressed PCM at the
/// target format directly (16 kHz mono Float32), which we write to disk block by
/// block. Plain `AVAudioFile(forReading:)` cannot open mp4/mov, so this path is
/// the general decoder for the importer.
enum AudioFileDecoder {

    static let targetSampleRate: Double = 16_000

    /// Decodes `url` to a temp WAV. `progress` receives a 0…1 fraction as the
    /// reader advances. Non-isolated so tests can call it directly.
    static func decodeToTemporaryWAV(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> DecodedMedia {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileImportError.fileMissing
        }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw FileImportError.decodeFailed("Het bestand bevat geen audiospoor.")
        }

        let durationCM = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationCM)

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw FileImportError.decodeFailed("Kon de audio niet uitlezen.")
        }
        reader.add(output)

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wc_import_\(UUID().uuidString).wav")
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw FileImportError.decodeFailed("Kon het doelformaat niet aanmaken.")
        }
        let outFile = try AVAudioFile(forWriting: outURL, settings: outFormat.settings)

        guard reader.startReading() else {
            throw FileImportError.decodeFailed(reader.error?.localizedDescription ?? "Lezen mislukte.")
        }

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            try appendSamples(from: sampleBuffer, to: outFile, format: outFormat)

            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            if duration > 0 { progress(min(max(pts / duration, 0), 1)) }
        }

        if reader.status == .failed {
            try? FileManager.default.removeItem(at: outURL)
            throw FileImportError.decodeFailed(reader.error?.localizedDescription ?? "Decoderen mislukte.")
        }

        progress(1.0)
        return DecodedMedia(url: outURL, duration: duration > 0 ? duration : Double(outFile.length) / targetSampleRate)
    }

    /// Copies the PCM Float32 samples from a CMSampleBuffer into `outFile`.
    private static func appendSamples(
        from sampleBuffer: CMSampleBuffer,
        to outFile: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }
        let frameCount = AVAudioFrameCount(length / MemoryLayout<Float>.size)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        guard let dst = buffer.floatChannelData?[0] else { return }
        let status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: dst)
        guard status == kCMBlockBufferNoErr else {
            throw FileImportError.decodeFailed("Kon audio-samples niet kopiëren.")
        }
        try outFile.write(from: buffer)
    }
}
