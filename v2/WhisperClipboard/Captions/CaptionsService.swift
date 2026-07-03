import AVFoundation
import Combine
import Core
import Foundation

/// @MainActor orchestrator for live captions from system audio (M6).
///
/// Captures all system audio via ``SystemAudioTap``, feeds it through the pure
/// ``CaptionWindowAccumulator`` rolling-window logic, and transcribes each cut
/// window with a **dedicated** ``ParakeetEngine`` instance (kept separate from
/// the dictation engine so the two never contend for model/decoder state).
///
/// ## Latency tradeoff
/// The multilingual Parakeet model is batch-only, so captions are produced one
/// rolling window at a time (~3 s windows, or cut earlier on a natural pause).
/// Expect a ~1–3 s delay between speech and its caption line. This is documented
/// on ``CaptionWindowAccumulator``.
///
/// ## Mutual exclusion
/// Captions do **not** block dictation. Instead, when the user starts dictating
/// (or a file import runs), captions PAUSE automatically via ``stop()`` and do
/// **not** auto-resume — simpler and more predictable than juggling audio
/// routing between two simultaneous capture paths.
@MainActor
final class CaptionsService: ObservableObject {

    // MARK: - Observable state

    /// The most recent caption lines (newest last), bounded to ~3.
    @Published private(set) var lines: [CaptionLine] = []
    /// Whether a caption session is currently running.
    @Published private(set) var isRunning = false
    /// A one-line Dutch error, set when a session fails to start (e.g. permission).
    @Published var errorMessage: String?
    /// Set when the failure was specifically a system-audio permission denial, so
    /// the UI can offer a "Open Systeeminstellingen" button.
    @Published private(set) var permissionDenied = false

    // MARK: - Dependencies

    /// A dedicated engine instance — never the dictation engine — so caption
    /// transcription cannot disturb an in-flight dictation's model state.
    private let engine: ParakeetEngine
    private let history: HistoryStore
    private let locale: () -> Locale
    /// Persist the full session transcript to history on stop when true.
    private let saveToHistory: () -> Bool
    /// Reason string when captions must be refused (dictation/import busy), else nil.
    private let busyReason: () -> String?
    private let notify: (String) -> Void

    // MARK: - Session state

    private var tap: SystemAudioTap?
    private var feedTask: Task<Void, Never>?
    /// All lines pushed this session, for the saved transcript.
    private var sessionLines: [String] = []
    private var lineBuffer = CaptionLineBuffer(capacity: 3)

    init(
        history: HistoryStore,
        locale: @escaping () -> Locale,
        saveToHistory: @escaping () -> Bool,
        busyReason: @escaping () -> String?,
        engine: ParakeetEngine = ParakeetEngine(),
        notify: @escaping (String) -> Void = { Notifications.post($0) }
    ) {
        self.engine = engine
        self.history = history
        self.locale = locale
        self.saveToHistory = saveToHistory
        self.busyReason = busyReason
        self.notify = notify
    }

    // MARK: - Lifecycle

    /// Starts a caption session. Refuses (and notifies) while dictation or import
    /// is busy. On a permission failure, sets ``errorMessage`` +
    /// ``permissionDenied`` for the UI explainer rather than notifying.
    func start() {
        guard !isRunning else { return }

        if let reason = busyReason() {
            notify(reason)
            return
        }

        errorMessage = nil
        permissionDenied = false
        lineBuffer.clear()
        sessionLines.removeAll()
        lines = []

        let tap = SystemAudioTap()
        let stream: AsyncStream<AudioBufferBox>
        do {
            stream = try tap.start()
        } catch let error as SystemAudioTapError {
            handleStartFailure(error)
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        self.tap = tap
        isRunning = true

        // Pre-warm the caption engine's model (idempotent; models already on disk
        // for dictation to be usable at all).
        Task { try? await engine.prepare() }

        feedTask = Task { [weak self] in
            await self?.consume(stream)
        }
    }

    /// Stops the current session, tearing down the tap and optionally saving the
    /// full transcript to history.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        feedTask?.cancel()
        feedTask = nil
        tap?.stop()
        tap = nil

        saveTranscriptIfNeeded()
    }

    private func handleStartFailure(_ error: SystemAudioTapError) {
        errorMessage = error.errorDescription
        if case .permissionDenied = error {
            permissionDenied = true
        }
    }

    // MARK: - Consumption

    /// Drains the tap stream, running the rolling-window logic and transcribing
    /// each cut window on the (actor) engine. Runs until the stream finishes or
    /// the task is cancelled.
    private func consume(_ stream: AsyncStream<AudioBufferBox>) async {
        var accumulator = CaptionWindowAccumulator(sampleRate: 16_000)

        for await box in stream {
            if Task.isCancelled { break }
            guard let chunk = Self.floatSamples(from: box.buffer) else { continue }
            accumulator.append(chunk)

            if accumulator.shouldCut, let window = accumulator.cut() {
                await transcribeAndEmit(window)
            }
        }

        // Final flush of any trailing audio when the stream ends naturally.
        if !Task.isCancelled, let tail = accumulator.drain() {
            await transcribeAndEmit(tail)
        }
    }

    /// Transcribes one window and pushes the resulting non-empty text as the
    /// current caption line.
    private func transcribeAndEmit(_ window: [Float]) async {
        let text: String
        do {
            let result = try await engine.transcribeSamples(window, locale: locale())
            text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // A single failed window shouldn't kill the session; skip it.
            return
        }
        guard !text.isEmpty else { return }
        emit(line: text)
    }

    /// Appends a caption line to the display buffer and the session transcript.
    private func emit(line text: String) {
        guard isRunning else { return }
        if lineBuffer.push(text) {
            sessionLines.append(text)
            lines = lineBuffer.lines
        }
    }

    // MARK: - History

    private func saveTranscriptIfNeeded() {
        guard saveToHistory() else { return }
        let transcript = sessionLines
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }

        let entry = TranscriptEntry(
            id: UUID().uuidString,
            text: transcript,
            createdAt: Self.timestampString(from: Date()),
            name: "Live ondertitels",
            pinned: false,
            language: locale().language.languageCode?.identifier ?? "nl",
            model: "parakeet-tdt-0.6b-v3",
            source: "captions",
            duration: 0,
            segments: []
        )
        do {
            try history.add(entry)
        } catch {
            NSLog("CaptionsService: failed to save transcript: %@", String(describing: error))
        }
    }

    // MARK: - Testable windowing (no Core Audio)

    /// Runs the exact rolling-window path over pre-decoded 16 kHz mono Float32
    /// samples, returning the caption lines produced. Used by the E2E test to
    /// validate captioning end-to-end without the system-audio tap. `feedChunk`
    /// mirrors the tap's buffer cadence.
    ///
    /// This is the same logic ``consume(_:)`` runs, factored so a test can drive
    /// it deterministically with a real cached Parakeet model.
    func captionSamplesForTesting(
        _ samples: [Float],
        chunkFrames: Int = 4096,
        sampleRate: Double = 16_000
    ) async -> [String] {
        var accumulator = CaptionWindowAccumulator(sampleRate: sampleRate)
        var produced: [String] = []

        func transcribe(_ window: [Float]) async {
            guard let result = try? await engine.transcribeSamples(window, locale: locale()) else { return }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { produced.append(text) }
        }

        var index = 0
        while index < samples.count {
            let end = min(index + chunkFrames, samples.count)
            accumulator.append(Array(samples[index..<end]))
            index = end
            if accumulator.shouldCut, let window = accumulator.cut() {
                await transcribe(window)
            }
        }
        if let tail = accumulator.drain() {
            await transcribe(tail)
        }
        return produced
    }

    // MARK: - Helpers

    private static func floatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }

    private static func timestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
