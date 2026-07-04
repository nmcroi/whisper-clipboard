import AVFoundation
import Combine
import Core
import Foundation
import NaturalLanguage

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

    // MARK: - Translation (Part B)

    /// Whether live translation of FINAL lines to Dutch is on. Initialised from
    /// settings; the overlay header toggle flips it live (and persists via
    /// ``onTranslateToggle``).
    @Published var translateEnabled = false {
        didSet {
            guard translateEnabled != oldValue else { return }
            if !translateEnabled { translationHint = nil }
            // Skip persistence for an internal session-reset (see `stop()`): the
            // user's saved preference must survive stopping captions.
            guard !suppressTranslatePersist else { return }
            onTranslateToggle(translateEnabled)
        }
    }
    /// When true, a `translateEnabled` change does NOT persist via
    /// ``onTranslateToggle`` — used to reset the live toggle on `stop()` without
    /// clobbering the user's saved preference (which is re-read on the next start).
    private var suppressTranslatePersist = false
    /// A one-line Dutch hint shown once when translation is unavailable (missing
    /// language pack). Cleared when translation succeeds or is turned off.
    @Published private(set) var translationHint: String?
    /// FINAL lines awaiting translation, drained by the overlay's `.translationTask`
    /// (which owns the `TranslationSession`). Each entry is a line id + its text.
    @Published private(set) var pendingTranslations: [PendingTranslation] = []

    /// A caption line queued for Dutch translation.
    struct PendingTranslation: Identifiable, Equatable, Sendable {
        let id: UUID       // matches the CaptionLine id
        let text: String
    }

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
    /// The personal woordenlijst applied to every caption line (whole-word,
    /// case-insensitive). Read on demand so edits take effect immediately.
    private let replacements: () -> [Replacement]
    /// Whether to strip conservative filler words ("eh", "uh"…) from each caption
    /// line. Read on demand so the toggle takes effect immediately.
    private let removeFillers: () -> Bool
    private let notify: (String) -> Void
    /// Reads the persisted translate-to-Dutch setting (refreshed on each start).
    private let translateToDutch: () -> Bool
    /// Persists the live translate toggle back to settings when flipped in the
    /// overlay header. No-op by default (tests / previews).
    private let onTranslateToggle: (Bool) -> Void

    // MARK: - Session state

    private var tap: SystemAudioTap?
    private var feedTask: Task<Void, Never>?
    /// All FINAL lines pushed this session, for the saved transcript.
    private var sessionLines: [String] = []
    /// The id of the in-progress (volatile) line currently shown, if any. Its text
    /// is re-transcribed in place while its window stays open.
    private var volatileLineID: UUID?
    /// The most recent in-flight volatile re-transcription, tracked so a slow one
    /// can be cancelled on stop and never overlaps the next tick.
    private var volatileTask: Task<Void, Never>?
    /// True while a volatile re-transcription is running (non-overlap guard).
    private var isTranscribingVolatile = false
    /// Set by a completed volatile pass when its text ends on sentence-final
    /// punctuation with enough audio buffered; consumed on the next loop turn to
    /// close the window eagerly (Part A). Only read/written on the consume task.
    private var pendingEagerClose = false
    /// The most recent FINAL line's text, for near-duplicate suppression and
    /// seam-overlap trimming (Part A hygiene).
    private var previousFinalText: String?

    init(
        history: HistoryStore,
        locale: @escaping () -> Locale,
        saveToHistory: @escaping () -> Bool,
        busyReason: @escaping () -> String?,
        replacements: @escaping () -> [Replacement] = { [] },
        removeFillers: @escaping () -> Bool = { false },
        translateToDutch: @escaping () -> Bool = { false },
        onTranslateToggle: @escaping (Bool) -> Void = { _ in },
        engine: ParakeetEngine = ParakeetEngine(),
        notify: @escaping (String) -> Void = { Notifications.post($0) }
    ) {
        self.engine = engine
        self.history = history
        self.locale = locale
        self.saveToHistory = saveToHistory
        self.busyReason = busyReason
        self.replacements = replacements
        self.removeFillers = removeFillers
        self.translateToDutch = translateToDutch
        self.onTranslateToggle = onTranslateToggle
        self.notify = notify
        // NB: do NOT call `translateToDutch()` here — the provider may resolve
        // against not-yet-initialised state (see AppEnvironment's deferred binding
        // pattern). The real value is picked up on the first `start()`.
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
        sessionLines.removeAll()
        lines = []
        volatileLineID = nil
        isTranscribingVolatile = false
        pendingEagerClose = false
        previousFinalText = nil
        pendingTranslations = []
        translationHint = nil
        // Refresh the toggle from persisted settings (may have changed while the
        // overlay was down). Assign only on change so we don't re-persist.
        let persisted = translateToDutch()
        if translateEnabled != persisted { translateEnabled = persisted }

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

        volatileTask?.cancel()
        volatileTask = nil
        isTranscribingVolatile = false
        feedTask?.cancel()
        feedTask = nil
        tap?.stop()
        tap = nil

        // Reset the live translate toggle (without persisting) so the overlay's
        // `.onChange(of: translateEnabled)` drives `translationConfig = nil`,
        // cancelling the view's `.translationTask` and releasing the
        // TranslationSession + its 0.12s poll loop. The saved preference is
        // untouched and re-applied on the next `start()`.
        if translateEnabled {
            suppressTranslatePersist = true
            translateEnabled = false
            suppressTranslatePersist = false
        }
        pendingTranslations = []
        translationHint = nil

        saveTranscriptIfNeeded()
    }

    private func handleStartFailure(_ error: SystemAudioTapError) {
        errorMessage = error.errorDescription
        if case .permissionDenied = error {
            permissionDenied = true
        }
    }

    // MARK: - Consumption

    /// Drains the tap stream with pseudo-streaming captioning:
    ///
    /// - While a window is OPEN, every ~0.6 s (and never overlapping) it snapshots
    ///   the accumulated samples and re-transcribes them, updating the current
    ///   caption line IN PLACE as a volatile (dimmed) line.
    /// - When the window CLOSES (silence / max / hard cap / eager sentence-final
    ///   punctuation), it transcribes the full window one last time and replaces
    ///   the volatile line as FINAL (full white), then starts the next window.
    ///
    /// Parakeet runs many times realtime, so re-transcribing a ≤10 s window every
    /// second is cheap; the non-overlap guard skips a tick if the previous
    /// transcription is still running.
    private func consume(_ stream: AsyncStream<AudioBufferBox>) async {
        var accumulator = CaptionWindowAccumulator(sampleRate: 16_000)
        var planner = CaptionTickPlanner()
        planner.reset()

        for await box in stream {
            if Task.isCancelled { break }
            guard let chunk = Self.floatSamples(from: box.buffer) else { continue }
            accumulator.append(chunk)

            // Eager close (Part A): a completed volatile pass may have flagged that
            // its text ends on sentence-final punctuation with enough audio buffered.
            // Honour that here, on the loop, so the accumulator is only ever mutated
            // from this task.
            let eagerClose = pendingEagerClose
            pendingEagerClose = false

            if (eagerClose && accumulator.secondsBuffered >= CaptionText.eagerCloseMinSeconds)
                || accumulator.shouldCut,
               let window = accumulator.cut() {
                // Window closed: cancel any in-flight volatile pass and finalize.
                volatileTask?.cancel()
                isTranscribingVolatile = false
                await finalizeWindow(window)
                planner.reset()
            } else if planner.shouldTick(now: Date(), inFlight: isTranscribingVolatile),
                      let snapshot = accumulator.snapshot() {
                // Window still open: fire a non-blocking volatile re-transcription.
                planner.didTick()
                startVolatileTranscription(of: snapshot, secondsBuffered: accumulator.secondsBuffered)
            }
        }

        // Final flush of any trailing audio when the stream ends naturally.
        volatileTask?.cancel()
        isTranscribingVolatile = false
        if !Task.isCancelled, let tail = accumulator.drain() {
            await finalizeWindow(tail)
        }
    }

    /// Re-transcribes an open window's snapshot and updates the current volatile
    /// line in place. Runs as a detached-from-the-loop task so the consume loop
    /// keeps ingesting audio; the non-overlap flag prevents pile-ups.
    private func startVolatileTranscription(of window: [Float], secondsBuffered: Double) {
        isTranscribingVolatile = true
        volatileTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isTranscribingVolatile = false }
            let text = await self.transcribe(window)
            guard !Task.isCancelled, self.isRunning, let text, !CaptionText.isJunk(text) else { return }
            self.updateVolatileLine(text)
            // Flag an eager sentence-final close for the consume loop to honour.
            if CaptionText.shouldEagerClose(after: text, secondsBuffered: secondsBuffered) {
                self.pendingEagerClose = true
            }
        }
    }

    /// Transcribes one closed window and commits it as a FINAL caption line
    /// (replacing the volatile line if one is showing).
    private func finalizeWindow(_ window: [Float]) async {
        let text = await transcribe(window)
        guard isRunning, let text, !text.isEmpty else {
            // Nothing usable: drop any dangling volatile line so it doesn't linger.
            clearVolatileLine()
            return
        }
        commitFinalLine(text)
    }

    /// Runs the engine on a window and applies the personal woordenlijst. Returns
    /// `nil` on failure (a single bad window must not kill the session).
    private func transcribe(_ window: [Float]) async -> String? {
        do {
            let result = try await engine.transcribeSamples(window, locale: locale())
            let processed = applyCaptionProcessing(result.text)
            return processed.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Applies the caption line pipeline: personal woordenlijst first, then
    /// optional conservative filler removal. Captions never run the full
    /// `cleanText` sentence pass (lines are short, streaming fragments), so this
    /// mirrors the two steps that are meaningful per-window.
    private func applyCaptionProcessing(_ text: String) -> String {
        var processed = TextProcessor.applyReplacements(text, replacements())
        if removeFillers() {
            processed = TextProcessor.removeFillers(
                processed,
                language: locale().language.languageCode?.identifier ?? "nl"
            )
        }
        return processed
    }

    // MARK: - Line emission

    /// Max caption lines kept on screen (newest last): up to 2 final lines plus
    /// at most one trailing volatile line.
    private static let displayCapacity = 3

    /// Updates (or creates) the current volatile line's text in place. Applies the
    /// no-regress rule so a shorter re-transcription can't flicker over a longer
    /// one. The volatile line is ALWAYS the last row (never reordered).
    private func updateVolatileLine(_ text: String) {
        guard isRunning else { return }
        if let id = volatileLineID, let index = lines.firstIndex(where: { $0.id == id }) {
            guard CaptionText.shouldReplaceVolatile(current: lines[index].text, with: text) else { return }
            lines[index].text = text
        } else {
            let line = CaptionLine(text: text, isFinal: false)
            volatileLineID = line.id
            appendBounded(line)
        }
    }

    /// Commits `text` as a final line, applying Part-A hygiene:
    ///
    /// 1. Trim any exact seam-overlap with the previous final line.
    /// 2. Drop junk (empty / punctuation-only) results.
    /// 3. Drop near-duplicates of the previous final line.
    ///
    /// Surviving text promotes the volatile line in place (never reordered) if one
    /// is showing, else appends a fresh final line, and records it in the session
    /// transcript for the optional saved history entry.
    private func commitFinalLine(_ rawText: String) {
        guard isRunning else { return }

        let trimmed = CaptionText.trimSeamOverlap(rawText, previousFinal: previousFinalText)
        if CaptionText.isJunk(trimmed) || CaptionText.isNearDuplicate(trimmed, of: previousFinalText) {
            // Nothing new to show: drop the dangling volatile line so it doesn't
            // linger as a half-finalized artifact.
            clearVolatileLine()
            return
        }

        let finalID: UUID
        if let id = volatileLineID, let index = lines.firstIndex(where: { $0.id == id }) {
            lines[index].text = trimmed
            lines[index].isFinal = true
            finalID = id
        } else {
            let line = CaptionLine(text: trimmed, isFinal: true)
            finalID = line.id
            appendBounded(line)
        }
        volatileLineID = nil
        previousFinalText = trimmed
        sessionLines.append(trimmed)
        translateFinalIfEnabled(lineID: finalID, text: trimmed)
    }

    /// Appends a line and trims the display to ``displayCapacity`` (newest last).
    private func appendBounded(_ line: CaptionLine) {
        var next = lines
        next.append(line)
        if next.count > Self.displayCapacity {
            next.removeFirst(next.count - Self.displayCapacity)
        }
        lines = next
    }

    /// Drops a dangling volatile line (used when a window finalizes to nothing).
    private func clearVolatileLine() {
        guard let id = volatileLineID else { return }
        lines.removeAll { $0.id == id }
        volatileLineID = nil
    }

    // MARK: - Translation (Part B)

    /// Queues a finalized line for Dutch translation when the toggle is on and the
    /// text is not already Dutch. The overlay's `.translationTask` drains
    /// ``pendingTranslations`` with its `TranslationSession`.
    private func translateFinalIfEnabled(lineID: UUID, text: String) {
        guard translateEnabled else { return }
        guard !CaptionText.detectedIsDutch(text) else { return }
        pendingTranslations.append(PendingTranslation(id: lineID, text: text))
    }

    /// Called by the overlay after its session has translated a queued line.
    /// Applies the Dutch text to the matching line (kept in place) and dequeues it.
    func applyTranslation(lineID: UUID, dutch: String) {
        if let index = lines.firstIndex(where: { $0.id == lineID }) {
            lines[index].translation = dutch
        }
        pendingTranslations.removeAll { $0.id == lineID }
        translationHint = nil
    }

    /// Called by the overlay when a queued translation could not be produced
    /// (typically the language pack is not installed). Dequeues the line, leaves
    /// the original text intact, and surfaces a one-time Dutch hint.
    func failTranslation(lineID: UUID, unavailable: Bool) {
        pendingTranslations.removeAll { $0.id == lineID }
        if unavailable, translationHint == nil {
            translationHint = "Vertaling niet beschikbaar. Installeer het Nederlandse taalpakket via Systeeminstellingen › Algemeen › Taal en regio › Vertaaltalen."
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
    /// The lines a pseudo-streaming caption run produced, for tests.
    struct CaptionRunResult: Sendable {
        /// The finalized caption lines, in order (post-replacement).
        var finalLines: [String]
        /// Every volatile (in-progress) line update observed, in order. Useful to
        /// show that captions update in place before a window closes.
        var volatileUpdates: [String]
    }

    /// Runs the pseudo-streaming caption path over pre-decoded 16 kHz mono Float32
    /// samples, returning both the volatile in-progress updates and the finalized
    /// lines. Used by the E2E test to validate captioning end-to-end without the
    /// system-audio tap. This mirrors ``consume(_:)`` but is fully deterministic:
    /// a volatile pass runs on every window snapshot (no wall-clock cadence) so the
    /// test sees the in-place updates regardless of transcription speed.
    func captionRunForTesting(
        _ samples: [Float],
        chunkFrames: Int = 4096,
        sampleRate: Double = 16_000
    ) async -> CaptionRunResult {
        var accumulator = CaptionWindowAccumulator(sampleRate: sampleRate)
        var finalLines: [String] = []
        var volatileUpdates: [String] = []
        var sawVolatileSinceCut = false

        func transcribe(_ window: [Float]) async -> String? {
            guard let result = try? await engine.transcribeSamples(window, locale: locale()) else { return nil }
            let processed = applyCaptionProcessing(result.text)
            let text = processed.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        var index = 0
        while index < samples.count {
            let end = min(index + chunkFrames, samples.count)
            accumulator.append(Array(samples[index..<end]))
            index = end

            if accumulator.shouldCut, let window = accumulator.cut() {
                if let text = await transcribe(window) { finalLines.append(text) }
                sawVolatileSinceCut = false
            } else if !sawVolatileSinceCut, let snapshot = accumulator.snapshot() {
                // One volatile pass per open window (deterministic stand-in for the
                // ~0.9 s cadence used live).
                if let text = await transcribe(snapshot) {
                    volatileUpdates.append(text)
                    sawVolatileSinceCut = true
                }
            }
        }
        if let tail = accumulator.drain(), let text = await transcribe(tail) {
            finalLines.append(text)
        }
        return CaptionRunResult(finalLines: finalLines, volatileUpdates: volatileUpdates)
    }

    /// Back-compat convenience: the finalized caption lines only.
    func captionSamplesForTesting(
        _ samples: [Float],
        chunkFrames: Int = 4096,
        sampleRate: Double = 16_000
    ) async -> [String] {
        await captionRunForTesting(samples, chunkFrames: chunkFrames, sampleRate: sampleRate).finalLines
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
