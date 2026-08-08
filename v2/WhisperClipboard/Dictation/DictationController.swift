import AVFoundation
import Combine
import Core
import Foundation
import WhisperShared

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
        /// Model laden en microfoon openen. Er wordt nog niets vastgelegd. Dit
        /// was eerder meteen `.recording`, waardoor de HUD een rode stip, een
        /// teller op 0:00 en "Spreek nu…" toonde terwijl er niets binnenkwam —
        /// op een koude start seconden lang (bevinding 2026-08-03).
        case preparing
        case recording
        /// Gebruikerspauze: de mic-tap is eraf (er wordt niets vastgelegd), maar
        /// de sessie leeft door — hervatten gaat verder in dezelfde opname.
        case paused
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
    /// De `snapshot` is het klembord zoals het was VÓÓR onze transcriptie erop
    /// kwam (gemaakt vlak vóór `Clipboard.copy`), zodat de restore-stap het echte
    /// vorige klembord van de gebruiker kan terugzetten.
    var insertionHandler: ((_ text: String, _ target: InsertionTarget?, _ snapshot: InsertionService.PasteboardSnapshot?) -> InsertionOutcome)?
    /// Maakt een momentopname van het huidige klembord VÓÓRDAT de transcriptie
    /// erop wordt gezet. Nil-safe: zonder handler is er geen snapshot en valt de
    /// insertion-restore terug op leegmaken.
    var pasteboardSnapshotProvider: (() -> InsertionService.PasteboardSnapshot?)?
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
        /// The full 16 kHz mono Float32 recording, retained for an optional
        /// speaker-recognition (diarization) pass done AFTER the text already
        /// reached the clipboard. `nil` when the captured audio wasn't in the
        /// diarizer's format (e.g. the Apple Speech engine negotiated a different
        /// rate) — the consumer then simply skips diarization.
        let samples: [Float]?
        /// Het bewaarde opnamebestand, als de gebruiker audio wil bewaren. De
        /// ontvanger verplaatst het naar de Recordings-map zodra het transcript
        /// werkelijk is opgeslagen, en ruimt het anders op — zodat er nooit een
        /// weesbestand blijft slingeren (bevinding 2026-08-03).
        let preservedAudioURL: URL?
    }

    /// Accumulates the recording's 16 kHz mono Float32 samples during a run, so a
    /// completed dictation can be diarized without re-decoding. Only created when
    /// the negotiated capture format matches the diarizer's requirement (16 kHz,
    /// mono, Float32) — i.e. the Parakeet path. Reset at each start.
    private var sampleCollector: SampleCollector?
    /// Whether the current session's capture format is the 16 kHz mono Float32 the
    /// diarizer needs. Set once the audio format is negotiated in `beginSession`.
    private var samplesAreDiarizable = false

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

        // Valt de opname stil — apparaatwissel, slaapstand, of de engine die
        // zichzelf stopt — dan ronden we af en bewaren we wat er is, in plaats
        // van een teller te laten doortellen boven een dode microfoon
        // (bevinding 2026-08-03).
        self.audioEngine.onInterruption = { [weak self] reason in
            self?.handleCaptureInterruption(reason)
        }
    }

    /// De opname is onderbroken. Alles tot dit moment is al weggeschreven, dus
    /// stoppen levert een bruikbaar transcript op; doorgaan zou alleen lege tijd
    /// toevoegen.
    private func handleCaptureInterruption(_ reason: AudioEngine.InterruptionReason) {
        guard phase == .recording || phase == .paused else { return }

        let explanation: String
        switch reason {
        case .configurationChanged:
            explanation = "Het geluidsapparaat is gewijzigd."
        case .systemWillSleep, .systemDidWake:
            explanation = "De Mac ging in slaapstand."
        case .engineStopped:
            explanation = "De opname is door het systeem gestopt."
        case .noBuffers(let seconds):
            explanation = "Er kwam \(Int(seconds.rounded())) seconden geen geluid meer binnen."
        }

        Notifications.postCritical(
            "\(explanation) De opname is afgerond en wat er is opgenomen wordt bewaard."
        )
        stop()
    }

    // MARK: - Public control (hotkey / menu)

    /// Toggle-mode entry point.
    func toggle() {
        switch phase {
        case .idle, .finished:
            start()
        case .recording, .paused:
            // De hotkey tijdens een pauze rondt gewoon af: de opname bevat dan
            // alles tot het pauzemoment.
            stop()
        case .preparing:
            // Model laadt en de microfoon gaat open. Een tweede tik zou de
            // sessie halverwege afbreken; negeren is hier het veilige gedrag.
            break
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
        guard phase == .recording || phase == .paused else { return }
        stop()
    }

    // MARK: - Pauze (HUD-knop)

    /// Pauzeert de lopende opname: capture stopt onmiddellijk, de sessie blijft
    /// staan. Genegeerd zolang de mic nog niet echt live is (start-venster).
    func pauseRecording() {
        guard debouncer.shouldAccept(now: nowSeconds()) else { return }
        guard phase == .recording, audioEngine.isRunning else { return }
        audioEngine.pause()
        phase = .paused
    }

    /// Hervat een gepauzeerde opname in dezelfde sessie. Lukt het hervatten van
    /// de audio-engine niet (input verdwenen), dan wordt de opname netjes
    /// afgerond met alles tot het pauzemoment.
    func resumeRecording() {
        guard debouncer.shouldAccept(now: nowSeconds()) else { return }
        guard phase == .paused else { return }
        if audioEngine.resume() {
            phase = .recording
        } else {
            Notifications.post("Hervatten mislukt — opname wordt afgerond")
            performStop()
        }
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
        phase = .preparing
        livePartial = StreamingPartial(finalizedText: "", volatileText: "")
        sampleCollector = nil
        samplesAreDiarizable = false
        elapsed = 0
        onStateChange(.loadingModel)
        latency.begin()

        let token = UUID()
        sessionToken = token
        Task { await beginSession(token: token) }
    }

    private func beginSession(token: UUID) async {
        let locale = Locale(identifier: settingsProvider().language.isEmpty ? "nl-NL" : settingsProvider().language)

        // De tijd tussen de sneltoets en een lopende microfoon is de vertraging
        // die de gebruiker voelt. Meten in plaats van gissen: bij een trage start
        // staat de verdeling over de drie stappen in het log
        // (bevinding 2026-08-04).
        let t0 = DispatchTime.now().uptimeNanoseconds
        func msSince(_ mark: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - mark) / 1_000_000
        }

        do {
            try await engine.startStreaming(locale: locale)
        } catch {
            await handleFailure(error)
            return
        }
        let modelMs = msSince(t0)

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

        // Only retain samples for the optional post-dictation diarization pass
        // when the engine negotiated exactly the diarizer's format (16 kHz mono
        // Float32 — the Parakeet path). For any other format we skip capture, and
        // diarization is skipped downstream (no re-decode, no wrong-rate turns).
        // Ook de instelling meetellen, niet alleen het audioformaat: zonder deze
        // controle werd élke dictatie volledig in RAM meegeschreven (~230 MB per
        // uur) terwijl sprekerherkenning uit stond en die samples nooit werden
        // gebruikt (bevinding 2026-08-03).
        samplesAreDiarizable = Self.isDiarizerFormat(format)
            && settingsProvider().speakerRecognitionEnabled

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

        let totalMs = msSince(t0)
        if totalMs > 400 {
            NSLog(
                "DictationController: start duurde %.0f ms (model %.0f ms, microfoon %.0f ms)",
                totalMs,
                modelMs,
                totalMs - modelMs
            )
        }

        // Pas hier loopt de microfoon werkelijk; vanaf nu mag de app zeggen dat
        // er wordt opgenomen.
        phase = .recording
        onStateChange(.recording)

        Notifications.post("Opname gestart")
        startElapsedTicker()
        observePartials()

        // When diarization is possible for this run, tee each buffer's samples
        // into a collector alongside feeding the engine. The collector is touched
        // only from this single serial loop, so its appends are race-free; we read
        // it back on the main actor after `feedTask` finishes (in `finishSession`).
        let capture = samplesAreDiarizable ? SampleCollector() : nil
        sampleCollector = capture
        feedTask = Task { [engine] in
            for await box in stream {
                capture?.append(from: box.buffer)
                await engine.feed(box)
            }
        }
    }

    /// True when `format` is exactly the 16 kHz mono Float32 the diarizer models
    /// consume — matching ``ParakeetEngine/bestAudioFormat()``.
    private static func isDiarizerFormat(_ format: AVAudioFormat?) -> Bool {
        guard let format else { return false }
        return format.commonFormat == .pcmFormatFloat32
            && format.channelCount == 1
            && Int(format.sampleRate) == 16_000
    }

    // MARK: - Stop

    func stop() {
        guard debouncer.shouldAccept(now: nowSeconds()) else { return }
        performStop()
    }

    /// Het eigenlijke stop-pad, zonder debounce-guard — ook gebruikt door het
    /// mislukt-hervatten-pad (dat mag nooit door de debouncer gedropt worden,
    /// anders blijft de sessie in een kapotte pauze hangen).
    private func performStop() {
        guard phase == .recording || phase == .paused else { return }

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

        // The feed loop has finished, so the collector is no longer being written:
        // safe to read the retained samples for the optional diarization pass.
        let samples = samplesAreDiarizable ? sampleCollector?.samples : nil
        sampleCollector = nil

        let result: TranscriptionResult
        do {
            result = try await engine.finalize()
        } catch {
            // Hier stond een "redding" van `livePartial.finalizedText`. Die
            // string is bij Parakeet altijd leeg — de partials-stream wordt in
            // `ParakeetEngine.init` meteen afgesloten — dus liep dit onvermijdelijk
            // uit op "Geen spraak herkend", terwijl de werkelijke fout nergens
            // werd getoond. Een mislukte transcriptie van een lang gesprek zag er
            // zo uit alsof je niets had gezegd (bevinding 2026-08-03).
            //
            // De opname zelf is nu niet meer weg: `finalize()` laat het tijdelijke
            // bestand bij een fout staan, zodat de volgende start het opnieuw
            // aanbiedt.
            failFinalize(error)
            return
        }

        latency.markFinalized()
        await completeTranscription(
            text: result.text,
            segments: result.segments,
            samples: samples,
            audioDuration: result.audioDuration,
            partialFailure: result.partialFailure,
            preservedAudioURL: result.preservedAudioURL
        )
    }

    /// Een mislukte transcriptie: toon de echte fout en meld dat de opname
    /// bewaard is gebleven voor een nieuwe poging.
    private func failFinalize(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Notifications.postCritical(
            "De transcriptie is mislukt: \(message) "
                + "De opname is bewaard en wordt bij de volgende start opnieuw aangeboden."
        )
        phase = .idle
        onStateChange(.ready)
        finishHUD(success: false)
    }

    /// De parameter `salvagedFromError` is verdwenen: hij werd in deze functie
    /// nooit uitgelezen en het bijbehorende reddingspad bestond alleen op papier
    /// (bevinding 2026-08-03).
    private func completeTranscription(
        text: String,
        segments: [Core.TranscriptSegment],
        samples: [Float]?,
        audioDuration: Double = 0,
        partialFailure: String? = nil,
        preservedAudioURL: URL? = nil
    ) async {
        partialsTask?.cancel()
        partialsTask = nil

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Er komt geen item, dus ook geen plek om bewaarde audio aan te
            // hangen: opruimen in plaats van laten slingeren.
            if let preservedAudioURL {
                try? FileManager.default.removeItem(at: preservedAudioURL)
            }
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

        // Neem het klembord van de gebruiker vast VÓÓRDAT we onze transcriptie
        // erop schrijven. Anders zou de insertion-restore straks onze eigen tekst
        // als "vorige inhoud" opslaan en het echte klembord van de gebruiker
        // wissen. Nil-safe: zonder provider blijft alles bij het oude.
        let pasteboardSnapshot = pasteboardSnapshotProvider?()

        Clipboard.copy(processed)
        latency.markClipboard()
        lastMetrics = latency.metrics

        // Direct insertion (M5): if wired + enabled, attempt to paste the text
        // into the app that was frontmost when recording started. On any skip or
        // failure the text simply remains on the clipboard (already copied above).
        let outcome = insertionHandler?(processed, capturedInsertionTarget, pasteboardSnapshot)
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

        // Opslaan gebeurt hieronder meteen, vóór het klaarmelden.
        //
        // Voorheen ging dit naar een volgende main-actor beurt om de gevoelde
        // stop→klaar-tijd te drukken. Op dat moment is het tijdelijke
        // geluidsbestand echter al opgeruimd door `finalize()`, en bestaat de
        // tekst nog nergens op schijf. Een crash in dat gaatje kostte de hele
        // opname — precies wat er op 3 augustus 2026 gebeurde met een lang
        // gesprek. De winst was bovendien klein: opslaan is één lokale
        // SQLite-insert, en het echte schijfwerk (diarisatie, export) draaide
        // toch al op een eigen taak.
        // De klok op het scherm loopt door zolang de opname "aan" staat, ook als
        // de microfoon geen buffers meer levert. Wijkt de werkelijk opgenomen
        // audio daar merkbaar van af, dan is er audio verloren gegaan en hoort
        // de gebruiker dat te weten (bevinding 2026-08-03). We bewaren dan ook
        // de échte duur, niet de klok.
        let wallClock = elapsed
        let trustedDuration = audioDuration > 0 ? audioDuration : wallClock
        if audioDuration > 0, wallClock - audioDuration > max(5, wallClock * 0.05) {
            NSLog(
                "DictationController: audio gap — klok %.1fs, opgenomen %.1fs",
                wallClock,
                audioDuration
            )
            Notifications.postCritical(
                "Let op: er is minder audio opgenomen dan de teller aangaf "
                    + "(\(Int(audioDuration.rounded())) s van \(Int(wallClock.rounded())) s). "
                    + "De microfoon lijkt tijdens de opname te zijn weggevallen."
            )
        }

        // Een schrijffout onderweg: wat er is, is getranscribeerd, maar de
        // gebruiker moet weten dat het verslag niet compleet is.
        if let partialFailure {
            Notifications.postCritical(
                "Een deel van de audio ging tijdens de opname verloren "
                    + "(\(partialFailure)). De tekst bevat alleen wat er is opgenomen."
            )
        }

        let completion = TranscriptCompletion(
            text: processed,
            segments: segments,
            duration: trustedDuration,
            language: settings.language.isEmpty ? "nl" : settings.language,
            model: "parakeet-tdt-0.6b-v3",
            // `AppEnvironment.saveCompletedTranscript` plakt hier ".mac" achter,
            // dus dit blijft de kale bron.
            source: "mic",
            // Only carry samples through when the segments are non-empty (a
            // salvaged/empty-segment run has nothing to attach speakers to).
            samples: segments.isEmpty ? nil : samples,
            preservedAudioURL: preservedAudioURL
        )

        // Eerst vastleggen, dan pas klaarmelden.
        onTranscriptCompleted?(completion)

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

/// Accumulates 16 kHz mono Float32 samples from the dictation capture, for the
/// optional post-dictation speaker-recognition pass. Written from a single serial
/// feed loop only (never concurrently), then read once that loop has finished, so
/// it needs no internal locking. Marked `@unchecked Sendable` to cross into the
/// (non-actor) feed `Task`; the single-writer/read-after-completion discipline
/// above makes that safe.
private final class SampleCollector: @unchecked Sendable {
    private(set) var samples: [Float] = []

    /// Appends channel 0 of a 16 kHz mono Float32 buffer.
    func append(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
}
