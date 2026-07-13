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
    @Published private(set) var statusLine = "Tik om op te nemen"

    private var app: AppModel?
    /// True zolang een start-cyclus in gang is maar `isRecording` nog niet gezet.
    /// Dicht het async-venster tussen een tik en `isRecording = true`, zodat een
    /// tweede snelle tik geen tweede sessie op dezelfde engine start.
    private var starting = false
    /// Wanneer gezet, wordt de opname áán deze notitie toegevoegd (met `note_id`)
    /// i.p.v. als losse Geschiedenis-entry opgeslagen. `nil` = het standaard
    /// "one-off"-gedrag van het Opnemen-tabblad (ongewijzigd). Zie ``save``.
    private var targetNoteId: String?
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

    func toggle() {
        if isRecording {
            Task { await stopAndTranscribe() }
        } else {
            // Negeer een tweede tik terwijl een start al onderweg is: anders zou
            // het async start-venster (tot `isRecording = true`) een tweede sessie
            // op dezelfde engine kunnen openen.
            guard !starting else { return }
            starting = true
            Task { await start() }
        }
    }

    // MARK: - Start

    private func start() async {
        // Wat er ook gebeurt (succes, vroege return of fout): het start-venster is
        // voorbij als deze functie terugkeert, dus laat de guard weer los.
        defer { starting = false }
        guard let app else { return }
        didCopy = false
        lastResult = nil
        lastResultAt = nil
        statusLine = "Bezig met opnemen…"

        let engine = app.engine
        guard let format = await engine.bestAudioFormat() else {
            fail("Audioformaat niet beschikbaar.")
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
            self.statusLine = "Gepauzeerd (onderbreking)"
            self.liveActivity.setPaused(true)
        }
        audio.onResume = { [weak self] in
            guard let self else { return }
            self.isPaused = false
            self.pausedByInterruption = false
            self.statusLine = "Bezig met opnemen…"
            self.liveActivity.setPaused(false)
        }
        self.audio = audio

        do {
            try await engine.startStreaming(locale: Locale(identifier: "nl_NL"))
            let stream = try await audio.start(convertingTo: format)
            isRecording = true
            isPaused = false
            liveActivity.start()
            // Meld ons aan als de actieve opname zodat de stop-knop op de Live
            // Activity (via StopRecordingIntent) déze controller bereikt.
            RecordingStopBus.shared.register(self)
            startTicking(audio: audio)
            // Pump captured buffers into the engine off the record loop.
            feedTask = Task { [weak self] in
                for await box in stream {
                    await engine.feed(box)
                    _ = self // keep alive
                }
            }
        } catch {
            await engine.cancel()
            self.audio = nil
            liveActivity.end()
            fail(error.localizedDescription)
        }
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
                statusLine = "Bezig met opnemen…"
                liveActivity.setPaused(false)
            } else {
                // Hervatten mislukt (input/sessie weg): rond netjes af met alles
                // tot het pauzemoment.
                statusLine = "Hervatten lukte niet — opname wordt afgerond…"
                Task { await stopAndTranscribe() }
            }
        } else {
            audio.pauseByUser()
            isPaused = true
            pausedByInterruption = false
            statusLine = "Gepauzeerd"
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
        isPaused = false
        pausedByInterruption = false
        RecordingStopBus.shared.deregister(self)
        tickTask?.cancel()
        tickTask = nil
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

        isTranscribing = true
        statusLine = "Bezig met transcriberen…"

        do {
            let result = try await app.engine.finalize()
            isTranscribing = false
            let processed = TextProcessor.process(
                result.text,
                replacements: app.replacements,
                clean: true,
                language: "nl"
            )
            guard !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                lastResult = nil
                statusLine = "Geen spraak herkend. Tik om opnieuw op te nemen."
                return
            }
            lastResult = processed
            lastResultAt = Date()
            statusLine = "Klaar. Tik om opnieuw op te nemen."
            save(processed, segments: result.segments, duration: elapsed)
        } catch {
            isTranscribing = false
            fail(error.localizedDescription)
        }
    }

    // MARK: - Save

    private func save(_ text: String, segments: [TranscriptSegment], duration: Double) {
        guard let history = app?.history else { return }
        let entry = TranscriptEntry(
            id: UUID().uuidString,
            text: text,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            name: "",
            pinned: false,
            language: "nl",
            model: "parakeet-tdt-0.6b-v3",
            source: "mic",
            duration: duration,
            segments: segments
        )
        // Twee routes vanuit dezelfde pijplijn:
        //  • targetNoteId == nil → standaard one-off: los in de Geschiedenis
        //    (ongewijzigd gedrag van het Opnemen-tabblad).
        //  • targetNoteId gezet → voeg de opname áán die notitie toe (met note_id);
        //    hij verschijnt dan niet los in de Geschiedenis.
        if let noteId = targetNoteId {
            try? history.appendToNote(entry, noteId: noteId)
        } else {
            try? history.add(entry)
        }
    }

    func markCopied() {
        didCopy = true
    }

    /// Wist het resultaat van het scherm en zet de statusregel terug op de
    /// ruststand. Raakt de Geschiedenis NIET aan — de opgeslagen entry blijft
    /// gewoon in het Geschiedenis-tabblad staan; dit leegt alleen het scherm.
    func clearResult() {
        lastResult = nil
        lastResultAt = nil
        didCopy = false
        statusLine = "Tik om op te nemen"
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
        statusLine = "Er ging iets mis. Tik om opnieuw te proberen."
    }
}
