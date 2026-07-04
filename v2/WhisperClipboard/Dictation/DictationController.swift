import AVFoundation
import Combine
import Core
import Foundation

/// Orchestrates the dictation lifecycle: idle → recording → transcribing →
/// ready, mirroring the guard semantics of the Python `WhisperClipboardApp`.
///
/// Guards enforced (matching the Python app):
///  - ignore *start* while transcribing or while the model is loading/downloading
///  - ignore *stop* when not recording
///  - a 250 ms debounce on transitions to swallow hotkey bounce
@MainActor
final class DictationController: ObservableObject {

    // MARK: - Phase

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case finished
    }

    @Published private(set) var phase: Phase = .idle
    /// Live streaming preview for the HUD (finalized + volatile tail).
    @Published private(set) var livePartial = StreamingPartial(finalizedText: "", volatileText: "")
    /// Elapsed recording time in seconds, ticked while recording.
    @Published private(set) var elapsed: Double = 0
    /// Last completed run's latency figures (for the debug HUD line).
    @Published private(set) var lastMetrics = LatencyMetrics()

    /// Whether the model is ready to record right now.
    var isReadyToRecord: Bool {
        modelManager.status.isReady && phase == .idle
    }

    let audioEngine: AudioEngine
    let modelManager: EngineModelManager

    private let engine: any TranscriptionEngine
    private let settingsProvider: () -> AppSettings
    private let onStateChange: (AppState) -> Void
    /// Invoked with the finished, post-processed transcript so a completed
    /// dictation can be persisted to the history store. Nil-safe (M0/M1 wiring).
    var onTranscriptCompleted: ((TranscriptCompletion) -> Void)?
    /// Returns true when a file import is running, so dictation refuses to start
    /// (mirrors the Python "one job at a time" guard). Nil-safe.
    var importBusyProvider: (() -> Bool)?
    /// Delivers the processed transcript for direct insertion into the target app
    /// (captured at `start()`). Returns the outcome so the HUD line can reflect it.
    /// Nil-safe: when unset, dictation stays clipboard-only.
    var insertionHandler: ((_ text: String, _ target: InsertionTarget?) -> InsertionOutcome)?
    /// Captures the frontmost app at recording start (before the HUD appears).
    var captureInsertionTarget: (() -> InsertionTarget?)?
    /// Called just before a recording actually starts, so live captions can be
    /// paused (they do not auto-resume). Nil-safe.
    var onWillStartRecording: (() -> Void)?

    /// The frontmost app captured when the current run started.
    private var capturedInsertionTarget: InsertionTarget?
    /// The insertion outcome of the most recent completed run (drives the HUD line).
    @Published private(set) var lastInsertionOutcome: InsertionOutcome?

    /// The payload handed to `onTranscriptCompleted` after a successful run.
    struct TranscriptCompletion {
        let text: String
        let segments: [Core.TranscriptSegment]
        let duration: Double
        let language: String
        let model: String
        let source: String
    }

    private let latency = LatencyRecorder()
    private var debouncer = TransitionDebouncer(interval: 0.25)

    private var feedTask: Task<Void, Never>?
    private var partialsTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var hudDismissTask: Task<Void, Never>?

    /// Identifies the current recording session. `start()` mints a fresh token;
    /// `stop()`/`handleFailure()` bump it. `beginSession()` checks it after every
    /// `await` so a stop that landed during the async streaming-start window
    /// aborts the half-started capture instead of orphaning a live mic tap.
    private var sessionToken = UUID()

    init(
        engine: any TranscriptionEngine,
        audioEngine: AudioEngine,
        modelManager: EngineModelManager,
        settingsProvider: @escaping () -> AppSettings,
        onStateChange: @escaping (AppState) -> Void
    ) {
        self.engine = engine
        self.audioEngine = audioEngine
        self.modelManager = modelManager
        self.settingsProvider = settingsProvider
        self.onStateChange = onStateChange
    }

    // MARK: - Public control (hotkey / menu)

    /// Toggle-mode entry point.
    func toggle() {
        switch phase {
        case .idle, .finished:
            start()
        case .recording:
            stop()
        case .transcribing:
            // Busy: mirror Python "Still transcribing. Please wait."
            break
        }
    }

    /// Push-to-talk press.
    func pushToTalkDown() {
        guard phase == .idle || phase == .finished else { return }
        start()
    }

    /// Push-to-talk release.
    func pushToTalkUp() {
        guard phase == .recording else { return }
        stop()
    }

    // MARK: - Start

    func start() {
        guard debouncer.shouldAccept(now: nowSeconds()) else { return }
        guard phase == .idle || phase == .finished else { return }

        // Guard: model still loading/downloading → notify, mirror Python.
        guard modelManager.status.isReady else {
            Notifications.post("Spraakmodel wordt nog geladen")
            return
        }

        // Guard: a file import is running → refuse, mirror Python one-job-at-a-time.
        if importBusyProvider?() == true {
            Notifications.post("Wacht tot de huidige opname of transcriptie klaar is")
            return
        }

        // Pause live captions (if running); they don't auto-resume afterwards.
        onWillStartRecording?()

        // Capture the frontmost app now, before the (non-activating) HUD shows,
        // so we know where a later direct insertion should paste.
        capturedInsertionTarget = captureInsertionTarget?()

        hudDismissTask?.cancel()
        phase = .recording
        livePartial = StreamingPartial(finalizedText: "", volatileText: "")
        elapsed = 0
        onStateChange(.recording)
        latency.begin()

        let token = UUID()
        sessionToken = token
        Task { await beginSession(token: token) }
    }

    private func beginSession(token: UUID) async {
        let locale = Locale(identifier: settingsProvider().language.isEmpty ? "nl-NL" : settingsProvider().language)

        do {
            try await engine.startStreaming(locale: locale)
        } catch {
            await handleFailure(error)
            return
        }

        // If a stop/failure landed while startStreaming was awaiting, this session
        // is stale: undo the engine start and bail before touching the mic.
        guard token == sessionToken else {
            await engine.cancel()
            return
        }

        let format = await engine.bestAudioFormat()
        // Re-check after the (awaited) format query too.
        guard token == sessionToken else {
            await engine.cancel()
            return
        }

        let stream: AsyncStream<AudioBufferBox>
        do {
            if let format {
                stream = try await audioEngine.start(convertingTo: format)
            } else {
                stream = try await audioEngine.start()
            }
        } catch {
            await engine.cancel()
            await handleFailure(error)
            return
        }

        // A stop that raced audioEngine.start(): the mic tap is now live but the
        // normal stop path already finalized. Tear the capture down here so it
        // isn't left running with no consumer.
        guard token == sessionToken else {
            audioEngine.stop()
            await engine.cancel()
            return
        }

        Notifications.post("Opname gestart")
        startElapsedTicker()
        observePartials()

        feedTask = Task { [engine] in
            for await box in stream {
                await engine.feed(box)
            }
        }
    }

    // MARK: - Stop

    func stop() {
        guard debouncer.shouldAccept(now: nowSeconds()) else { return }
        guard phase == .recording else { return }

        // Invalidate the current session so a beginSession() still in its async
        // startup window aborts instead of committing (and orphaning) a mic tap.
        sessionToken = UUID()

        latency.markStop()
        phase = .transcribing
        onStateChange(.transcribing)

        audioEngine.stop()
        stopElapsedTicker()

        Task { await finishSession() }
    }

    private func finishSession() async {
        await feedTask?.value
        feedTask = nil

        let result: TranscriptionResult
        do {
            result = try await engine.finalize()
        } catch {
            // Engine failure mid-finalize: keep whatever partials produced.
            let salvaged = livePartial.finalizedText
            await completeTranscription(
                text: salvaged,
                segments: [],
                salvagedFromError: true
            )
            return
        }

        latency.markFinalized()
        await completeTranscription(text: result.text, segments: result.segments, salvagedFromError: false)
    }

    private func completeTranscription(
        text: String,
        segments: [Core.TranscriptSegment],
        salvagedFromError: Bool
    ) async {
        partialsTask?.cancel()
        partialsTask = nil

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Zero speech → no clipboard write, mirror Python "Geen spraak herkend".
            Notifications.post("Geen spraak herkend")
            onStateChange(.ready)
            finishHUD(success: false)
            return
        }

        let settings = settingsProvider()
        let processed = TextProcessor.process(
            trimmed,
            replacements: settings.replacements,
            clean: settings.cleanOutput,
            removeFillers: settings.removeFillers,
            language: settings.language.isEmpty ? "nl" : settings.language
        )

        Clipboard.copy(processed)
        latency.markClipboard()
        lastMetrics = latency.metrics

        // Direct insertion (M5): if wired + enabled, attempt to paste the text
        // into the app that was frontmost when recording started. On any skip or
        // failure the text simply remains on the clipboard (already copied above).
        let outcome = insertionHandler?(processed, capturedInsertionTarget)
        lastInsertionOutcome = outcome
        capturedInsertionTarget = nil
        switch outcome {
        case .inserted:
            NSLog("Insertion: ingevoegd in doel-app")
        case .insertionFailed:
            Notifications.post("Tekst staat op je klembord (invoegen niet mogelijk)")
        case .clipboardOnly, nil:
            break
        }

        // Persist the completed transcript (history store). Duration is the last
        // ticked recording elapsed; source is always mic for hotkey/menu dictation.
        onTranscriptCompleted?(
            TranscriptCompletion(
                text: processed,
                segments: segments,
                duration: elapsed,
                language: settings.language.isEmpty ? "nl" : settings.language,
                model: "parakeet-tdt-0.6b-v3",
                source: "mic"
            )
        )

        livePartial = StreamingPartial(finalizedText: processed, volatileText: "")
        // The insertionFailed case already posted its own notification above.
        switch outcome {
        case .inserted:
            Notifications.post("Tekst ingevoegd")
        case .insertionFailed:
            break
        case .clipboardOnly, nil:
            Notifications.post("Tekst staat op je klembord")
        }
        onStateChange(.ready)
        finishHUD(success: true)
    }

    // MARK: - Failure

    private func handleFailure(_ error: Error) async {
        // Invalidate the session so any concurrent beginSession() bails.
        sessionToken = UUID()
        feedTask?.cancel(); feedTask = nil
        partialsTask?.cancel(); partialsTask = nil
        stopElapsedTicker()
        audioEngine.cancel()

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Notifications.post(message)
        onStateChange(.error(message))
        finishHUD(success: false)
    }

    // MARK: - Partials & elapsed

    private func observePartials() {
        partialsTask = Task { [weak self, engine] in
            for await partial in engine.partials {
                guard let self else { break }
                await MainActor.run {
                    if partial.finalizedText.isEmpty == false || partial.volatileText.isEmpty == false {
                        self.latency.markFirstPartial()
                    }
                    self.livePartial = partial
                }
            }
        }
    }

    private func startElapsedTicker() {
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.elapsed = self.audioEngine.elapsed
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopElapsedTicker() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    // MARK: - HUD lifecycle

    private func finishHUD(success: Bool) {
        phase = .finished
        // Reset to idle after the HUD's brief confirmation window.
        hudDismissTask?.cancel()
        // Success linger is user-configurable (Settings); error linger stays a
        // fixed, shorter duration regardless of that preference.
        let lingerMs: Int
        if success {
            let seconds = min(10.0, max(1.0, settingsProvider().hudLingerSeconds))
            lingerMs = Int(seconds * 1000)
        } else {
            lingerMs = 1500
        }
        hudDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(lingerMs))
            guard let self, !Task.isCancelled else { return }
            self.phase = .idle
        }
    }

    // MARK: - Helpers

    private func nowSeconds() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    #if DEBUG
    /// Debug helper preserved from M0: steps through states without real audio.
    func simulateStateCycle() {
        let sequence: [AppState] = [.loadingModel, .ready, .recording, .transcribing, .ready]
        Task { @MainActor in
            for state in sequence {
                onStateChange(state)
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }
    #endif
}
