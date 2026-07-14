import AVFoundation
import Core
import Foundation
import WhisperShared

/// Bestuurt een notulen-opname op de Mac: opnemen (met pauze) → lokaal
/// transcriberen → opslaan in de Geschiedenis (bron "meeting") → transcript
/// beschikbaar maken voor de mail-stap.
///
/// Bewust een eigen, kleine controller naast ``DictationController``: notulen
/// zijn geen dictaat — er wordt NIETS naar het klembord geschreven, niets
/// ingevoegd en er verschijnt geen HUD. Hij gebruikt een eigen ``AudioEngine``
/// (microfoon-tap) maar deelt de ``ParakeetEngine``; wederzijdse uitsluiting
/// met dicteren/import/ondertitels loopt via ``busyReason`` en de
/// busy-providers in `AppEnvironment`.
@MainActor
final class MeetingController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case recording
        case paused
        case transcribing
        /// Transcript klaar (staat in ``transcript`` en in de Geschiedenis).
        case finished
    }

    @Published private(set) var phase: Phase = .idle
    /// Verstreken opnametijd, exclusief pauzes (getickt tijdens de opname).
    @Published private(set) var elapsed: Double = 0
    /// Het afgeronde, verwerkte verslag; nil zolang er geen is.
    @Published private(set) var transcript: String?
    /// Nederlandse foutmelding voor de sheet (nil = geen fout).
    @Published private(set) var errorMessage: String?

    let audioEngine = AudioEngine()
    private let engine: ParakeetEngine
    private let history: HistoryStore
    private let settingsProvider: () -> AppSettings
    /// Reden waarom starten nu niet kan (dicteren/import/ondertitels bezig),
    /// of nil wanneer het mag. Gezet door `AppEnvironment`.
    var busyReason: (() -> String?)?

    /// True zolang er een notulen-sessie leeft — telt mee in de busy-guards
    /// van dicteren, import, ondertitels en de automatiseringen.
    var isBusy: Bool {
        phase == .recording || phase == .paused || phase == .transcribing
    }

    private var feedTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?

    init(
        engine: ParakeetEngine,
        history: HistoryStore,
        settingsProvider: @escaping () -> AppSettings
    ) {
        self.engine = engine
        self.history = history
        self.settingsProvider = settingsProvider
    }

    // MARK: - Besturing

    func start() {
        guard phase == .idle || phase == .finished else { return }
        if let reason = busyReason?() {
            errorMessage = reason
            return
        }
        errorMessage = nil
        transcript = nil
        elapsed = 0
        phase = .recording
        Task { await beginSession() }
    }

    private func beginSession() async {
        let settings = settingsProvider()
        let locale = Locale(identifier: settings.language.isEmpty ? "nl-NL" : settings.language)

        do {
            try await engine.startStreaming(locale: locale)
        } catch {
            await engine.cancel()
            fail(error)
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
            fail(error)
            return
        }

        // De sheet kan tijdens het async opstarten niet stoppen (de knoppen
        // verschijnen pas in .recording), dus geen sessionToken-dans nodig
        // zoals bij het hotkey-gedreven dicteren.
        startElapsedTicker()
        feedTask = Task { [engine] in
            for await box in stream {
                await engine.feed(box)
            }
        }
    }

    /// Pauze: capture stopt onmiddellijk (tap eraf), sessie blijft staan —
    /// zelfde semantiek als de dicteer-pauze. Gepauzeerde stukken bestaan
    /// nergens in de audio.
    func pause() {
        guard phase == .recording else { return }
        audioEngine.pause()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        if audioEngine.resume() {
            phase = .recording
        } else {
            Notifications.post("Hervatten mislukt — opname wordt afgerond")
            stop()
        }
    }

    func stop() {
        guard phase == .recording || phase == .paused else { return }
        phase = .transcribing
        audioEngine.stop()
        stopElapsedTicker()
        Task { await finishSession() }
    }

    /// Terug naar de beginstand voor een volgende notulen-sessie (aangeroepen
    /// bij het sluiten van de sheet).
    func reset() {
        guard !isBusy else { return }
        phase = .idle
        transcript = nil
        errorMessage = nil
        elapsed = 0
    }

    // MARK: - Afronden

    private func finishSession() async {
        await feedTask?.value
        feedTask = nil

        let result: TranscriptionResult
        do {
            result = try await engine.finalize()
        } catch {
            fail(error)
            return
        }

        let settings = settingsProvider()
        let processed = TextProcessor.process(
            result.text,
            replacements: settings.replacements,
            clean: settings.cleanOutput,
            removeFillers: settings.removeFillers,
            language: settings.language.isEmpty ? "nl" : settings.language
        )

        guard !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            transcript = nil
            errorMessage = "Geen spraak herkend — er is niets om te versturen."
            phase = .finished
            return
        }

        let entry = TranscriptEntry(
            id: UUID().uuidString,
            text: processed,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            name: "",
            pinned: false,
            language: settings.language.isEmpty ? "nl" : settings.language,
            model: "parakeet-tdt-0.6b-v3",
            source: "meeting",
            duration: elapsed,
            segments: result.segments
        )
        try? history.add(entry)

        transcript = processed
        phase = .finished
    }

    private func fail(_ error: Error) {
        feedTask?.cancel()
        feedTask = nil
        stopElapsedTicker()
        audioEngine.cancel()
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
        phase = .idle
    }

    // MARK: - Klok

    private func startElapsedTicker() {
        elapsedTask?.cancel()
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
}
