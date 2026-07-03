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

        hudDismissTask?.cancel()
        phase = .recording
        livePartial = StreamingPartial(finalizedText: "", volatileText: "")
        elapsed = 0
        onStateChange(.recording)
        latency.begin()

        Task { await beginSession() }
    }

    private func beginSession() async {
        let locale = Locale(identifier: settingsProvider().language.isEmpty ? "nl-NL" : settingsProvider().language)

        do {
            try await engine.startStreaming(locale: locale)
        } catch {
            await handleFailure(error)
            return
        }

        let format = await engine.bestAudioFormat()
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
            clean: settings.cleanOutput
        )

        Clipboard.copy(processed)
        latency.markClipboard()
        lastMetrics = latency.metrics

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
        Notifications.post("Tekst staat op je klembord")
        onStateChange(.ready)
        finishHUD(success: true)
    }

    // MARK: - Failure

    private func handleFailure(_ error: Error) async {
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
        // Linger ~3s so the user can read the completion state (their request).
        let lingerMs = success ? 3000 : 1500
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
