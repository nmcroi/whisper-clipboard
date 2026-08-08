import AVFoundation
import Core
import Foundation
import SwiftUI
import WhisperShared

/// Drives one record → transcribe → save cycle on the Record tab.
///
/// Owns the ``IOSAudioEngine``, feeds captured buffers into the shared
/// ``ParakeetEngine``, and on stop runs finalize → `TextProcessor.process` →
/// `HistoryStore.add`. Publishes the state the view renders (recording flag,
/// elapsed time, level, transcribing spinner, last result).
@MainActor
final class RecordController: ObservableObject, RecordingStopHandling {

    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isPaused = false
    /// True wanneer de huidige pauze door een OS-onderbreking komt (telefoontje,
    /// Siri) in plaats van de pauzeknop — de UI benoemt dat onderscheid en de
    /// hervat-knop werkt dan niet (het systeem hervat zelf zodra het kan).
    @Published private(set) var pausedByInterruption = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var lastResult: String?
    /// Wanneer `lastResult` op het scherm verscheen; stuurt de auto-wis na vijf
    /// minuten (zie ``clearResultIfExpired()``).
    private var lastResultAt: Date?
    @Published private(set) var didCopy = false
    private enum Status {
        case idle, preparing, recording, paused, pausedByInterruption, resumeFailed
        case noAudio, transcribing, noSpeech, ready, failed
    }
    @Published private var status: Status = .idle

    var isIdle: Bool { status == .idle }
    var statusLine: String {
        let locale = app?.interfaceLanguage.locale ?? Locale(identifier: "nl")
        return switch status {
        case .idle: L10n.string( "Tik om op te nemen", locale: locale)
        case .preparing: L10n.string( "Even klaarzetten…", locale: locale)
        case .recording: L10n.string( "Bezig met opnemen…", locale: locale)
        case .paused: L10n.string( "Gepauzeerd", locale: locale)
        case .pausedByInterruption: L10n.string( "Gepauzeerd (onderbreking)", locale: locale)
        case .resumeFailed: L10n.string( "Hervatten lukte niet — opname wordt afgerond…", locale: locale)
        case .noAudio: L10n.string( "Geen audio gehoord. Tik om opnieuw op te nemen.", locale: locale)
        case .transcribing: L10n.string( "Bezig met transcriberen…", locale: locale)
        case .noSpeech: L10n.string( "Geen audio of spraak herkend. Tik om opnieuw op te nemen.", locale: locale)
        case .ready: L10n.string( "Tik om opnieuw op te nemen.", locale: locale)
        case .failed: L10n.string( "Er ging iets mis. Tik om opnieuw te proberen.", locale: locale)
        }
    }

    private var app: AppModel?
    /// True zolang een start-cyclus in gang is maar `isRecording` nog niet gezet.
    /// Dicht het async-venster tussen een tik en `isRecording = true`, zodat een
    /// tweede snelle tik geen tweede sessie op dezelfde engine start.
    private var starting = false
    /// Wanneer gezet, wordt de opname áán deze notitie toegevoegd (met `note_id`)
    /// i.p.v. als losse Geschiedenis-entry opgeslagen. `nil` = het standaard
    /// "one-off"-gedrag van het Opnemen-tabblad (ongewijzigd). Zie ``save``.
    private var targetNoteId: String?
    /// De `source` waarmee opnames worden opgeslagen. Standaard "mic"; de
    /// notulist-flow zet hem op "meeting" (label "Notulen" in de Geschiedenis).
    var transcriptSource = "mic"
    /// Per-opnamekeuze. Wordt bij start bevroren zodat een latere
    /// instellingenwijziging de lopende opname niet kan veranderen.
    private var transcriptionLanguage: TranscriptionLanguage = .dutch
    /// Een transcript waarvan de database-write mislukte blijft in geheugen
    /// staan. Een nieuwe opname of het wissen van het resultaat mag dit niet
    /// stil overschrijven; Notulist kan dezelfde entry opnieuw bewaren.
    @Published private var pendingSave: (entry: TranscriptEntry, noteID: String?)?
    var hasPendingSave: Bool { pendingSave != nil }
    /// Wanneer gezet, krijgt deze closure de verwerkte transcript-tekst zodra
    /// een opname klaar is (naast de normale opslag in de Geschiedenis). De
    /// notulist-flow gebruikt dit om de mail-composer te openen.
    var onTranscriptReady: ((String, TranscriptEntry?) -> Void)?
    private var audio: IOSAudioEngine?
    private var feedTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var levelCancellable: AnyObject?
    private let liveActivity = RecordingLiveActivityController()

    func attach(app: AppModel) {
        self.app = app
    }

    /// Koppelt deze controller aan een notitie: elke afgeronde opname wordt áán
    /// die notitie toegevoegd i.p.v. als losse Geschiedenis-entry. Roep aan vanuit
    /// de notitie-detailweergave. `nil` herstelt het standaard one-off-gedrag.
    func attach(app: AppModel, targetNoteId: String?) {
        self.app = app
        self.targetNoteId = targetNoteId
    }

    // MARK: - Toggle

    func toggle(language: TranscriptionLanguage? = nil) {
        if isRecording {
            Task { await stopAndTranscribe() }
        } else {
            // Negeer een tweede tik terwijl een start al onderweg is: anders zou
            // het async start-venster (tot `isRecording = true`) een tweede sessie
            // op dezelfde engine kunnen openen.
            guard !starting else { return }
            if pendingSave != nil, retryPendingSave() == nil { return }
            if let language {
                transcriptionLanguage = language
                app?.transcriptionLanguage = language
            } else if let app {
                transcriptionLanguage = app.transcriptionLanguage
            }
            starting = true
            Task { await start() }
        }
    }

    // MARK: - Start

    /// Laadt het transcriptiemodel alvast zodra het Opnemen-tabblad verschijnt.
    /// Zonder dit betaalt de eerste tik na een koude start de volledige
    /// modellading, wat als een trage knop voelt (bevinding 2026-08-02).
    func warmUpEngine() async {
        guard let app, app.modelStatus.isReady, !isRecording else { return }
        try? await app.engine.prepare()
    }

    private func start() async {
        // Wat er ook gebeurt (succes, vroege return of fout): het start-venster is
        // voorbij als deze functie terugkeert, dus laat de guard weer los.
        defer { starting = false }
        guard let app else { return }
        didCopy = false
        lastResult = nil
        lastResultAt = nil
        // Nog niet `.recording`: tussen deze tik en het werkelijk lopen van de
        // audio zit op een koude start de modellading. De statusregel mag dan
        // niet beweren dat er al wordt opgenomen (bevinding 2026-08-02).
        status = .preparing

        let engine = app.engine
        guard let format = await engine.bestAudioFormat() else {
            fail(L10n.string( "Audioformaat niet beschikbaar.", locale: app.interfaceLanguage.locale))
            return
        }

        let audio = IOSAudioEngine()
        audio.onInterruption = { [weak self] in
            Task { await self?.stopAndTranscribe() }
        }
        audio.onPause = { [weak self] in
            guard let self else { return }
            self.isPaused = true
            self.pausedByInterruption = true
            self.status = .pausedByInterruption
            self.liveActivity.setPaused(true)
        }
        audio.onResume = { [weak self] in
            guard let self else { return }
            self.isPaused = false
            self.pausedByInterruption = false
            self.status = .recording
            self.liveActivity.setPaused(false)
        }
        self.audio = audio

        do {
            // Eerst de microfoon aanzetten: dat is een kwestie van milliseconden.
            // Het model mag daarna laden terwijl de opname al loopt. De
            // audiostroom buffert onbeperkt, dus de eerste seconden blijven
            // bewaard en worden alsnog gevoerd zodra de engine klaarstaat.
            // Voorheen wachtte de knop op de modellading: op een koude start zes
            // seconden voordat er iets gebeurde (bevinding 2026-08-02).
            let stream = try await audio.start(convertingTo: format)
            isRecording = true
            status = .recording
            isPaused = false
            liveActivity.start()
            // Meld ons aan als de actieve opname zodat de stop-knop op de Live
            // Activity (via StopRecordingIntent) déze controller bereikt.
            RecordingStopBus.shared.register(self)
            startTicking(audio: audio)
            let language = transcriptionLanguage
            // Pump captured buffers into the engine off the record loop.
            feedTask = Task { [weak self] in
                do {
                    try await engine.startStreaming(locale: language.locale)
                } catch {
                    self?.failAfterStart(error)
                    return
                }
                for await box in stream {
                    await engine.feed(box)
                    _ = self // keep alive
                }
            }
        } catch {
            await engine.cancel()
            self.audio = nil
            liveActivity.end()
            fail(ErrorLocalization.message(for: error, language: app.interfaceLanguage))
        }
    }

    /// De opname liep al toen het model alsnog niet bleek te laden. Alles netjes
    /// afbreken en de fout tonen, in plaats van door te gaan met een microfoon
    /// die nergens naartoe schrijft.
    private func failAfterStart(_ error: Error) {
        guard let app else { return }
        tickTask?.cancel()
        tickTask = nil
        audio?.stop()
        audio = nil
        isRecording = false
        isPaused = false
        RecordingStopBus.shared.deregister(self)
        liveActivity.end()
        fail(ErrorLocalization.message(for: error, language: app.interfaceLanguage))
    }

    private func startTicking(audio: IOSAudioEngine) {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    guard let self, self.isRecording else { return }
                    self.elapsed = audio.elapsed
                    // Tijdens pauze geen levels doorsturen (blijft op 0 staan).
                    let live = audio.isPaused ? 0 : audio.levelMeter.level
                    self.level = live
                    self.liveActivity.push(level: live)
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    // MARK: - Pauze (pauzeknop)

    /// Pauzeert of hervat de lopende opname. Pauze stopt de capture onmiddellijk
    /// (niets van ná de druk komt de opname in); hervatten gaat naadloos verder
    /// in dezelfde opname — de stukken plakken automatisch aan elkaar. Tijdens
    /// een ONDERBREKINGS-pauze doet deze knop niets: het systeem hervat zelf.
    func togglePause() {
        guard isRecording, let audio else { return }
        if audio.isPaused {
            guard audio.pauseReason == .user else { return }
            if audio.resumeByUser() {
                isPaused = false
                status = .recording
                liveActivity.setPaused(false)
            } else {
                // Hervatten mislukt (input/sessie weg): rond netjes af met alles
                // tot het pauzemoment.
                status = .resumeFailed
                Task { await stopAndTranscribe() }
            }
        } else {
            audio.pauseByUser()
            isPaused = true
            pausedByInterruption = false
            status = .paused
            liveActivity.setPaused(true)
        }
    }

    // MARK: - Stop

    /// Stop-pad vanaf de Live Activity (lock-screen / Dynamic Island). Gedraagt
    /// zich exact als op de in-app stop-knop tikken: afronden → transcriberen →
    /// opslaan → activiteit beëindigen. Aangeroepen op de main actor door
    /// `RecordingStopBus`.
    func stopFromIntent() {
        guard isRecording else { return }
        Task { await stopAndTranscribe() }
    }

    private func stopAndTranscribe() async {
        guard isRecording, let app else { return }
        isRecording = false
        // Meteen mee omzetten: de knop werd al geel terwijl de regel eronder nog
        // "Bezig met opnemen" zei tijdens het leegdraaien (bevinding 2026-08-02).
        status = .transcribing
        isPaused = false
        pausedByInterruption = false
        RecordingStopBus.shared.deregister(self)
        tickTask?.cancel()
        tickTask = nil
        let capturedDuration = elapsed
        level = 0
        liveActivity.end()

        // `stop()` beëindigt de AsyncStream-continuation, dus de feed-loop draait
        // de laatste gebufferde buffers nog leeg en eindigt dan vanzelf. We WACHTEN
        // daarop (niet cancellen — dat zou juist de laatste woorden droppen). Een
        // korte timeout-guard voorkomt vastlopen mocht de stream onverhoopt niet
        // eindigen; daarna cancellen we alsnog als vangnet.
        audio?.stop()
        if let feedTask {
            let drained = await withTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask { await feedTask.value; return true }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 s vangnet
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !drained { feedTask.cancel() }
        }
        feedTask = nil
        audio = nil

        guard capturedDuration >= 0.35 else {
            await app.engine.cancel()
            lastResult = nil
            status = .noAudio
            return
        }

        isTranscribing = true
        status = .transcribing

        do {
            let result = try await app.engine.finalize()
            isTranscribing = false
            let processed = TextProcessor.process(
                result.text,
                replacements: app.replacements,
                clean: true,
                language: transcriptionLanguage == .automatic ? "" : transcriptionLanguage.rawValue
            )
            guard !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                lastResult = nil
                status = .noSpeech
                return
            }
            lastResult = processed
            lastResultAt = Date()
            status = .ready
            let savedEntry = save(processed, segments: result.segments, duration: capturedDuration)
            onTranscriptReady?(processed, savedEntry)
        } catch {
            isTranscribing = false
            fail(ErrorLocalization.message(for: error, language: app.interfaceLanguage))
        }
    }

    // MARK: - Save

    private func save(_ text: String, segments: [TranscriptSegment], duration: Double) -> TranscriptEntry? {
        let entry = TranscriptEntry(
            id: UUID().uuidString,
            text: text,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            name: "",
            pinned: false,
            language: transcriptionLanguage.rawValue,
            model: "parakeet-tdt-0.6b-v3",
            source: transcriptSource + ".ios",
            duration: duration,
            segments: segments
        )
        do {
            try persist(entry, noteID: targetNoteId)
            pendingSave = nil
            return entry
        } catch {
            pendingSave = (entry, targetNoteId)
            showSaveFailure()
            return nil
        }
    }

    /// Probeert exact dezelfde entry opnieuw te bewaren; UUID en metadata
    /// blijven dus stabiel en een gedeeltelijke vorige poging kan niet dubbelen.
    @discardableResult
    func retryPendingSave() -> TranscriptEntry? {
        guard let pendingSave else { return nil }
        do {
            try persist(pendingSave.entry, noteID: pendingSave.noteID)
            self.pendingSave = nil
            return pendingSave.entry
        } catch {
            showSaveFailure()
            return nil
        }
    }

    private func persist(_ entry: TranscriptEntry, noteID: String?) throws {
        guard let history = app?.history else {
            throw RecordPersistenceError.historyUnavailable
        }
        // Twee routes vanuit dezelfde pijplijn:
        //  • targetNoteId == nil → standaard one-off: los in de Geschiedenis
        //    (ongewijzigd gedrag van het Opnemen-tabblad).
        //  • targetNoteId gezet → voeg de opname áán die notitie toe (met note_id);
        //    hij verschijnt dan niet los in de Geschiedenis.
        if let noteID {
            try history.appendToNote(entry, noteId: noteID)
        } else {
            try history.add(entry)
        }
    }

    private func showSaveFailure() {
        guard let app else { return }
        app.errorMessage = L10n.string(
            "Het transcript kon niet in Geschiedenis worden bewaard. De tekst blijft op dit scherm; kopieer of deel hem en probeer opnieuw.",
            locale: app.interfaceLanguage.locale
        )
    }

    func markCopied() {
        didCopy = true
    }

    /// Wist het resultaat van het scherm en zet de statusregel terug op de
    /// ruststand. Raakt de Geschiedenis NIET aan — de opgeslagen entry blijft
    /// gewoon in het Geschiedenis-tabblad staan; dit leegt alleen het scherm.
    func clearResult() {
        guard pendingSave == nil else {
            showSaveFailure()
            return
        }
        lastResult = nil
        lastResultAt = nil
        didCopy = false
        status = .idle
    }

    /// Wist het resultaat wanneer het langer dan vijf minuten geleden verscheen.
    /// Aangeroepen op foreground-events (scenePhase → .active) en bij het
    /// verschijnen van het tabblad — bewust geen achtergrond-timer, zodat er
    /// niets tikt terwijl de app niet in beeld is.
    func clearResultIfExpired(now: Date = Date()) {
        guard let lastResultAt,
              TransientResultPolicy.isExpired(shownAt: lastResultAt, now: now) else { return }
        clearResult()
    }

    // MARK: - Failure

    private func fail(_ message: String) {
        isRecording = false
        isPaused = false
        pausedByInterruption = false
        isTranscribing = false
        RecordingStopBus.shared.deregister(self)
        tickTask?.cancel()
        tickTask = nil
        liveActivity.end()
        app?.errorMessage = message
        status = .failed
    }
}

private enum RecordPersistenceError: Error {
    case historyUnavailable
}
