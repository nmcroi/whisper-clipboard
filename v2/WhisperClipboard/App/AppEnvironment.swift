import Combine
import Core
import Foundation
import GRDB
import SwiftUI
import WhisperShared

/// Produces a history timestamp string matching the Python app's
/// `isoformat(timespec="seconds")` shape (no fractional seconds, local offset).
private func historyTimestampString(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = .current
    return formatter.string(from: date)
}

/// Dependency-injection container shared across the app.
///
/// M2 wires the real dictation pipeline with a selectable transcription engine.
/// Parakeet (multilingual, incl. Dutch) is the primary engine; Apple Speech is
/// available when its on-device model supports the configured language. Both
/// engines are instantiated up front; the active one is resolved from settings
/// with a language-support fallback (see ``EngineSelector``).
@MainActor
final class AppEnvironment: ObservableObject {
    /// A navigation request coming from outside the SwiftUI hierarchy (menu bar),
    /// consumed by `HomeView` to switch tabs / open a transcript.
    enum MenuNavigationRequest: Equatable {
        case home
        case history(id: String?)
    }

    @Published var appState: AppState = .starting

    /// Niet-nil wanneer de geschiedenis op schijf niet geopend kon worden. De app
    /// draait dan op een wegwerp-database in het geheugen; opnemen wordt
    /// geweigerd en iCloud blijft uit, zodat er niets verloren kan gaan zonder
    /// dat iemand het merkt (bevinding 2026-08-03).
    let historyFailure: String?

    /// Nederlandse uitleg bij ``historyFailure``, klaar om te tonen.
    var historyFailureMessage: String? {
        guard let historyFailure else { return nil }
        return """
            De geschiedenis kon niet worden geopend: \(historyFailure)
            WhisperClip neemt daarom niets op — anders zou je opname bij het \
            afsluiten verdwijnen. Synchroniseren met iCloud staat ook uit.
            """
    }
    /// Shared sidebar/detail navigation state. Owned here (rather than as a
    /// per-view `@StateObject`) so the menu bar and the SwiftUI window operate on
    /// one single source of truth and a view recreation can never spawn a second
    /// navigation hierarchy.
    let navigation = AppNavigation()
    @Published var settings = SettingsStore.load() {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.save(settings)
            // Live-apply a theme switch to the AppKit overlays and the status
            // menu, which sit outside SwiftUI's colour-scheme environment.
            if settings.appearance != oldValue.appearance {
                applyAppearanceToAppKitSurfaces()
            }
            // React to the iCloud-sync toggle: start or go dormant.
            if settings.icloudSyncEnabled != oldValue.icloudSyncEnabled {
                Task { await historySync.settingChanged() }
            }
            // Publiceer woordenlijst-bewerkingen naar de iCloud KV-store, behalve
            // wanneer de wijziging juist een binnengekomen remote lijst is
            // (applyingRemoteReplacements — sync-lus-preventie). publish() is
            // gedebounced — tikken in de Woordenlijst-tab spamt de store niet.
            if settings.replacements != oldValue.replacements, !applyingRemoteReplacements {
                replacementsSync.publish(settings.replacements)
            }
        }
    }

    /// iCloud KV-sync voor de woordenlijst (los van `historySync`; werkt ook
    /// zonder CloudKit-schema en degradeert stil zonder entitlement/account).
    private let replacementsSync = ReplacementsCloudSync(updatedAtKey: "replacementsUpdatedAt")
    private var applyingRemoteReplacements = false
    @Published var meetingContacts: [SavedMeetingContact] = AppEnvironment.loadMeetingContacts() {
        didSet {
            guard meetingContacts != oldValue else { return }
            Self.persistMeetingContacts(meetingContacts)
            guard !applyingRemoteMeetingContacts else { return }
            meetingContactsSync.publish(meetingContacts)
        }
    }
    private let meetingContactsSync = MeetingContactsCloudSync(updatedAtKey: "meetingContactsUpdatedAt")
    private var applyingRemoteMeetingContacts = false

    /// Re-applies the current appearance to the AppKit surfaces that don't
    /// inherit SwiftUI's `.preferredColorScheme` (the floating HUD/overlay panels
    /// and the menu-bar status item's menu). SwiftUI windows update themselves.
    private func applyAppearanceToAppKitSurfaces() {
        hud.applyAppearance()
        captionOverlay.applyAppearance()
        onAppearanceChange?(settings.appearance)
    }

    /// Set by the app delegate to re-skin the status-item menu when the theme
    /// changes (the menu is pure AppKit and outside the SwiftUI environment).
    var onAppearanceChange: ((AppSettings.AppearanceMode) -> Void)?
    /// Set by the menu bar; `HomeView` observes and resets it to `nil`.
    @Published var menuNavigationRequest: MenuNavigationRequest?
    /// A one-line Dutch notice when the active engine differs from the requested
    /// one (e.g. Apple Speech asked for but the language is unsupported).
    @Published private(set) var engineNotice: String?

    let audioEngine = AudioEngine()

    // Both engines exist for the app's lifetime; the active one is chosen below.
    let appleSpeechEngine = AppleSpeechEngine()
    let parakeetEngine = ParakeetEngine()

    /// Speaker diarization for file imports (loaded lazily on first use).
    let diarizationService = DiarizationService()

    /// The engine actually driving dictation this launch.
    let activeEngine: any TranscriptionEngine

    let modelManager: EngineModelManager
    let dictation: DictationController
    let hotkeys: HotkeyManager
    let history: HistoryStore
    /// iCloud history sync (i2). Dormant on ad-hoc dev builds / without an iCloud
    /// account; the "iCloud-synchronisatie" settings section shows its status.
    let historySync: HistorySyncEngine
    let fileImport: FileImportService
    /// AI prompt modes (M4): built-in + custom, runs against transcripts.
    let modes: ModesService
    /// Live captions from system audio (M6).
    let captions: CaptionsService
    private let hud: RecordingHUDController
    private let captionOverlay: CaptionOverlayController
    /// Direct text insertion (M5): pastes into the frontmost app when enabled.
    let insertion = InsertionService()
    /// Auto-export of completed transcripts to a folder (M7).
    let autoExport: AutoExportService
    /// Watched-folder auto-transcribe (M7).
    let watchedFolders: WatchedFolderService
    /// PLAUD cloud sync: pulls NotePin recordings from PLAUD's cloud into the
    /// import pipeline.
    let plaudSync: PlaudSyncService
    /// De private notulist (Mac): opnemen → lokaal transcriberen → verslag
    /// mailen. Eigen mic-capture, deelt de ParakeetEngine; telt mee in alle
    /// one-job-at-a-time-guards.
    let meeting: MeetingController

    private var locale: Locale {
        Locale(identifier: settings.language.isEmpty ? "nl-NL" : settings.language)
    }

    init() {
        // Resolve the active engine synchronously from the initial settings.
        // Apple Speech's live language-support check is async, so at init we
        // default to honouring the requested engine; `bootstrap()` re-checks and
        // applies the fallback once `SpeechTranscriber.supportedLocales` is known.
        let initialSettings = SettingsStore.load()
        let engine: any TranscriptionEngine =
            initialSettings.engine == .appleSpeech ? appleSpeechEngine : parakeetEngine
        self.activeEngine = engine

        let modelManager = EngineModelManager(
            engine: engine,
            locale: Locale(identifier: initialSettings.language.isEmpty ? "nl-NL" : initialSettings.language)
        )
        self.modelManager = modelManager

        // `settings`/`appState` are read/written after init; capture via closures
        // that resolve against the (soon-to-be-fully-initialized) instance.
        var settingsRef: (() -> AppSettings)!
        var stateSink: ((AppState) -> Void)!
        var translateToggleSink: ((Bool) -> Void)!
        // Of er een notulen-sessie loopt — gebonden nádat `meeting` bestaat;
        // de busy-closures hieronder draaien pas ver na init.
        var meetingBusyRef: (() -> Bool)!

        let dictation = DictationController(
            engine: engine,
            audioEngine: audioEngine,
            modelManager: modelManager,
            settingsProvider: { settingsRef() },
            onStateChange: { stateSink($0) }
        )
        self.dictation = dictation

        self.hotkeys = HotkeyManager(
            controller: dictation,
            modeProvider: { settingsRef().hotkeyMode }
        )

        self.hud = RecordingHUDController(controller: dictation)

        // History store. If the on-disk DB can't be opened we degrade to a
        // throwaway in-memory queue so the rest of the app keeps working
        // (non-persistent, but dictation + clipboard are unaffected).
        var retentionRef: (() -> Int?)!
        let opened = Self.makeHistoryStore(retentionProvider: { retentionRef() })
        let history = opened.store
        self.history = history
        self.historyFailure = opened.failure

        // AI prompt modes (M4). The API key is read from the Keychain on demand.
        self.modes = ModesService(history: history)

        // iCloud history sync (i2). Constructed here so it can install its
        // outbound change hook on the store immediately; it stays dormant until
        // `bootstrap()` calls `start()` (which checks the toggle + iCloud account).
        self.historySync = HistorySyncEngine(
            store: history,
            isEnabled: { settingsRef().icloudSyncEnabled }
        )

        // File-import pipeline. Refuses while dictation is recording/transcribing,
        // mirroring the Python "one job at a time" guard.
        self.fileImport = FileImportService(
            engine: parakeetEngine,
            history: history,
            locale: { Locale(identifier: settingsRef().language.isEmpty ? "nl-NL" : settingsRef().language) },
            busyReason: { [weak dictation] in
                switch dictation?.phase {
                case .recording, .paused, .transcribing:
                    return "Wacht tot de huidige opname of transcriptie klaar is"
                default:
                    break
                }
                if meetingBusyRef() {
                    return "Wacht tot de notulen-opname klaar is"
                }
                return nil
            },
            diarizer: diarizationService,
            settings: { settingsRef() }
        )

        // Live captions (M6): a dedicated engine instance (created inside the
        // service) keeps caption transcription off the dictation engine's state.
        // Captions refuse to start while dictation or import is busy; the reverse
        // exclusion (dictation auto-stops captions) is wired below via a hook.
        let captions = CaptionsService(
            history: history,
            locale: { Locale(identifier: settingsRef().language.isEmpty ? "nl-NL" : settingsRef().language) },
            saveToHistory: { settingsRef().saveCaptions },
            busyReason: { [weak dictation, weak fileImport] in
                switch dictation?.phase {
                case .recording, .paused, .transcribing:
                    return "Stop eerst de dictaat-opname voordat je ondertitels start"
                default:
                    break
                }
                if meetingBusyRef() {
                    return "Stop eerst de notulen-opname voordat je ondertitels start"
                }
                if fileImport?.isBusy == true {
                    return "Wacht tot het importeren klaar is voordat je ondertitels start"
                }
                return nil
            },
            replacements: { settingsRef().replacements },
            removeFillers: { settingsRef().removeFillers },
            translateToDutch: { settingsRef().translateCaptionsToDutch },
            onTranslateToggle: { translateToggleSink($0) }
        )
        self.captions = captions
        self.captionOverlay = CaptionOverlayController(service: captions)

        // Automation (M7): auto-export writes each completed transcript to disk;
        // the watched-folder service scans configured folders and feeds new,
        // stable media files into the (existing) file-import pipeline, respecting
        // its one-job-at-a-time busy guard.
        let autoExport = AutoExportService(settings: { settingsRef() })
        self.autoExport = autoExport
        self.watchedFolders = WatchedFolderService(
            foldersProvider: { settingsRef().watchedFolders },
            importer: { [weak fileImport] urls in fileImport?.importFiles(urls) },
            isBusy: { [weak dictation, weak fileImport, weak modelManager] in
                // Hold watched files back until the transcription model is ready:
                // otherwise files present at launch could be enqueued before the
                // model finishes downloading, fail, and — because they'd be marked
                // processed — never be retried. Treating "not ready" as busy leaves
                // them eligible for a later tick once the model installs.
                if modelManager?.status.isReady != true { return true }
                switch dictation?.phase {
                case .recording, .paused, .transcribing: return true
                default: break
                }
                if meetingBusyRef() { return true }
                return fileImport?.isBusy ?? false
            }
        )

        // PLAUD cloud sync (off by default). Pulls NotePin recordings from
        // PLAUD's cloud, downloads the new ones, and feeds them into the same
        // file-import pipeline (tagged source "plaud"). Same readiness/busy guard
        // as watched folders so a sync never fights the model download or a live
        // dictation.
        self.plaudSync = PlaudSyncService(
            settings: { settingsRef() },
            // Return the URLs the importer actually ACCEPTED (it refuses entirely
            // while dictation/import is busy, and drops unsupported files), so the
            // sync only marks those recordings processed — a refused batch stays
            // eligible for the next run instead of being silently dropped.
            importer: { [weak fileImport] urls in
                await fileImport?.importFilesAndWait(urls, source: "plaud") ?? []
            },
            cancelImporter: { [weak fileImport] in fileImport?.cancelPlaudImports() },
            isBusy: { [weak dictation, weak fileImport, weak modelManager] in
                if modelManager?.status.isReady != true { return true }
                switch dictation?.phase {
                case .recording, .paused, .transcribing: return true
                default: break
                }
                if meetingBusyRef() { return true }
                return fileImport?.isBusy ?? false
            }
        )

        // De notulist: eigen mic-capture, gedeelde ParakeetEngine (net als de
        // import-pijplijn), en dezelfde one-job-at-a-time-afspraken als de rest.
        let meeting = MeetingController(
            engine: parakeetEngine,
            history: history,
            settingsProvider: { settingsRef() }
        )
        self.meeting = meeting
        meetingBusyRef = { [weak meeting] in meeting?.isBusy ?? false }
        meeting.busyReason = { [weak dictation, weak self] in
            switch dictation?.phase {
            case .recording, .paused, .transcribing:
                return "Stop eerst de dictaat-opname voordat je notulen opneemt"
            default:
                break
            }
            if self?.fileImport.isBusy == true {
                return "Wacht tot het importeren klaar is voordat je notulen opneemt"
            }
            if self?.captions.isRunning == true {
                return "Stop eerst de live ondertitels voordat je notulen opneemt"
            }
            return nil
        }

        // Now that stored properties exist, bind the closures to `self`.
        settingsRef = { [weak self] in self?.settings ?? AppSettings() }
        stateSink = { [weak self] state in self?.appState = state }

        // The AppKit overlays (HUD, caption overlay) live outside the SwiftUI
        // colour-scheme environment, so give them the chosen appearance directly;
        // their dynamic `Theme` colors then resolve to the right palette.
        hud.appearanceProvider = { [weak self] in
            self?.settings.appearance.nsAppearance
        }
        hud.prepare()
        captionOverlay.appearanceProvider = { [weak self] in
            self?.settings.appearance.nsAppearance
        }
        translateToggleSink = { [weak self] enabled in self?.settings.translateCaptionsToDutch = enabled }
        retentionRef = { [weak self] in self?.settings.historyRetention }

        // Persist every completed dictation.
        dictation.onTranscriptCompleted = { [weak self] completion in
            self?.saveCompletedTranscript(completion)
        }
        // Auto-export each completed file import once it is stored (M7).
        fileImport.onTranscriptStored = { [weak self] entry in
            self?.autoExport.exportIfEnabled(entry)
        }
        // Refuse dictation while a file import or a meeting recording is running.
        dictation.importBusyProvider = { [weak self] in
            (self?.fileImport.isBusy ?? false) || (self?.meeting.isBusy ?? false)
        }
        // Starting dictation pauses live captions (they do not auto-resume).
        dictation.onWillStartRecording = { [weak self] in self?.captions.stop() }

        // Direct insertion wiring (M5). Capture the frontmost app at recording
        // start; attempt insertion at completion (clipboard-only when disabled).
        dictation.captureInsertionTarget = { InsertionService.captureFrontmost() }
        // Momentopname van het klembord VÓÓR de transcriptie erop komt, zodat de
        // insertion-restore het echte vorige klembord van de gebruiker terugzet.
        dictation.pasteboardSnapshotProvider = { [weak self] in
            self?.insertion.snapshotPasteboard()
        }
        dictation.insertionHandler = { [weak self] text, target, snapshot in
            guard let self else { return .clipboardOnly(reason: .disabled) }
            return self.insertion.insert(text, settings: self.settings, target: target, snapshot: snapshot)
        }

        // Woordenlijst-sync (iCloud KV-store): een remote lijst van de iPhone
        // gaat onder de vlag in `settings.replacements` — SettingsStore bewaart
        // hem dan automatisch via de gewone didSet, zonder terug te publiceren.
        // De timestamp-administratie doet het sync-component zelf.
        replacementsSync.onRemoteChange = { [weak self] list in
            guard let self, self.settings.replacements != list else { return }
            self.applyingRemoteReplacements = true
            self.settings.replacements = list
            self.applyingRemoteReplacements = false
        }
        replacementsSync.start()
        meetingContactsSync.onRemoteChange = { [weak self] contacts in
            guard let self, self.meetingContacts != contacts else { return }
            self.applyingRemoteMeetingContacts = true
            self.meetingContacts = contacts
            self.applyingRemoteMeetingContacts = false
        }
        meetingContactsSync.start()
    }

    private static let meetingContactsDefaultsKey = "meetingContacts"

    private static func loadMeetingContacts() -> [SavedMeetingContact] {
        guard let data = UserDefaults.standard.data(forKey: meetingContactsDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([SavedMeetingContact].self, from: data)) ?? []
    }

    private static func persistMeetingContacts(_ contacts: [SavedMeetingContact]) {
        guard let data = try? JSONEncoder().encode(contacts) else { return }
        UserDefaults.standard.set(data, forKey: meetingContactsDefaultsKey)
    }

    /// Opent de geschiedenis op schijf. Lukt dat niet, dan komt er nog steeds een
    /// werkbaar object terug — anders valt er niets te tonen — maar de fout wordt
    /// teruggegeven zodat de app hem meldt en niet doet alsof er niets aan de
    /// hand is.
    ///
    /// Vroeger schoof deze functie stilzwijgend een database in het geheugen
    /// onder de app en meldde `bootstrap()` daarna gewoon `.ready`. Alles wat je
    /// die sessie opnam verdween bij het afsluiten, en — erger — de iCloud-sync
    /// draaide óók op die wegwerp-database terwijl de CloudKit-cursor wél naar
    /// schijf werd geschreven. Records van de iPhone kwamen binnen in RAM,
    /// verdwenen, en de cursor schoof eroverheen: permanent verlies dat nooit
    /// meer werd opgehaald (bevinding 2026-08-03).
    private static func makeHistoryStore(
        retentionProvider: @escaping () -> Int?
    ) -> (store: HistoryStore, failure: String?) {
        do {
            return (try HistoryStore(retentionProvider: retentionProvider), nil)
        } catch {
            NSLog("AppEnvironment: history DB open failed (%@); trying in-memory store.", String(describing: error))
            return (Self.makeThrowawayStore(retentionProvider: retentionProvider),
                    error.localizedDescription)
        }
    }

    private static func makeThrowawayStore(retentionProvider: @escaping () -> Int?) -> HistoryStore {
        do {
            // In-memory fallback: mark it non-persistent so a v3 migration into
            // this throwaway store never persists the "migration done" flag (which
            // would make a later on-disk launch skip the migration and lose the
            // legacy history for good).
            return try HistoryStore(
                dbQueue: try DatabaseQueue(),
                retentionProvider: retentionProvider,
                isPersistent: false
            )
        } catch {
            fatalError("Kon de geschiedenis-database niet openen (ook niet in-memory): \(error)")
        }
    }

    /// Minimum dictation duration (seconds) worth diarizing. Mirrors
    /// ``FileImportService``'s guard: short quick dictations rarely have multiple
    /// speakers and diarization on <10s is unreliable — and, crucially, skipping
    /// them keeps the fast dictate-to-clipboard path free of any model load.
    private static let minDictationDiarizeDuration: Double = 10

    /// Builds a `TranscriptEntry` from a finished dictation and stores it.
    ///
    /// Latency note: the transcript text is **already on the clipboard** by the
    /// time this runs (``DictationController/completeTranscription`` copies it
    /// before firing `onTranscriptCompleted`). So the entry is persisted straight
    /// away here, and speaker recognition — when enabled and applicable — runs
    /// afterwards on a detached task, updating the stored entry's segments in
    /// place. Nothing on the dictate-to-clipboard hot path waits for diarization.
    private func saveCompletedTranscript(_ completion: DictationController.TranscriptCompletion) {
        let entry = TranscriptEntry(
            id: UUID().uuidString,
            text: completion.text,
            createdAt: historyTimestampString(from: Date()),
            name: "",
            pinned: false,
            language: completion.language,
            model: completion.model,
            source: completion.source + ".mac",
            duration: completion.duration,
            segments: completion.segments
        )
        // Dit blok zit tussen "transcript klaar" en "HUD meldt klaar", dus alles
        // wat hier traag is voelt de gebruiker als een hangende transcriptie.
        // Meten in plaats van gissen: duurt het merkbaar lang, dan staat het in
        // het log met de schuldige stap (bevinding 2026-08-04).
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            if ms > 250 {
                NSLog("AppEnvironment: opslaan duurde %.0f ms — dit vertraagt de HUD", ms)
            }
        }

        do {
            try history.add(entry)
            // Het transcript staat er nu echt: pas hier mag de bewaarde audio
            // zijn definitieve plek krijgen (bevinding 2026-08-03).
            preserveAudio(completion.preservedAudioURL, forEntryId: entry.id)
            // Auto-export the completed dictation (M7). Best-effort en mogelijk
            // traag (netwerkschijf, security-scoped bookmark), dus buiten het
            // hete pad: de HUD hoort niet op een export te wachten
            // (bevinding 2026-08-04).
            let exported = entry
            Task { [autoExport] in autoExport.exportIfEnabled(exported) }
        } catch {
            // Opslaan mislukt: er is geen item om de audio aan te koppelen, maar
            // weggooien zou de laatste kopie vernietigen. Laat het bestand staan
            // zodat de herstelronde bij de volgende start het oppakt.
            NSLog("AppEnvironment: failed to save transcript: %@", String(describing: error))
            // Niet alleen naar het log: een mislukte opslag betekent dat deze
            // dictatie nergens meer staat behalve op het klembord. Dat hoort de
            // gebruiker te weten zolang hij er nog iets mee kan
            // (bevinding 2026-08-03).
            Notifications.postCritical(
                "Opslaan in Geschiedenis is mislukt. De tekst staat nog op je klembord — plak hem ergens voordat je iets anders kopieert."
            )
        }

        // Optional speaker recognition (diarization) for the just-finished
        // dictation. Runs off the hot path (the text is already copied + stored),
        // and only when: the master toggle is on, we retained the recording's
        // samples (Parakeet 16 kHz path), the clip is long enough, and it has
        // segments to label. On any failure the entry simply keeps its plain
        // segments — dictation is never blocked or crashed by diarization.
        guard settings.speakerRecognitionEnabled,
              let samples = completion.samples,
              !samples.isEmpty,
              completion.duration >= Self.minDictationDiarizeDuration,
              !completion.segments.isEmpty
        else { return }

        let entryId = entry.id
        let segments = completion.segments
        Task { [weak self] in
            guard let self else { return }
            do {
                let turns = try await self.diarizationService.diarize(samples: samples)
                guard !turns.isEmpty else { return }
                let labelled = SpeakerMerge.assign(segments: segments, turns: turns)
                // Only write back if diarization actually assigned any speaker.
                guard labelled != segments else { return }
                try self.history.updateSegmentsPreservingText(id: entryId, segments: labelled)
            } catch {
                // Best-effort: keep the plain-segment transcript already saved.
                NSLog("AppEnvironment: dictation diarization skipped: %@", String(describing: error))
            }
        }
    }

    /// Kicks off engine-selection resolution, model status refresh + pre-warm at launch.
    func bootstrap() {
        // Geschiedenis onbruikbaar: niets meer opstarten dat gegevens aanmaakt of
        // synchroniseert. Geen migratie, geen opschoning, geen iCloud, geen
        // modelvoorbereiding — alleen de melding (bevinding 2026-08-03).
        if let historyFailureMessage {
            appState = .error("Geschiedenis kon niet worden geopend")
            Notifications.postCritical(historyFailureMessage)
            return
        }

        // One-time import of the old Python history.json (reads only; the JSON
        // is left untouched as a backup). No-op after the first successful run.
        history.migrateFromV3IfNeeded()

        // Early PLAUD builds used the temporary download filename as the visible
        // title and the import time as the recording date. Remove only those
        // unmistakably malformed rows; they are rebuilt from the PLAUD cloud
        // with correct metadata by the sync immediately below. Using the store
        // API journals CloudKit deletions, so malformed copies also disappear
        // from the iPhone instead of becoming duplicates.
        if let malformedPlaudEntries = try? history.entries(filter: .plaud).filter({ entry in
            entry.name.range(
                of: #"^\d{4}-\d{2}-\d{2}_\d{4}_"#,
                options: .regularExpression
            ) != nil
        }) {
            for entry in malformedPlaudEntries {
                try? history.delete(id: entry.id)
            }
        }

        // Microfoon alvast klaarzetten. De eerste aanraking van de audiohardware
        // kostte anders een groot deel van de wachttijd bij de eerste opname
        // (bevinding 2026-08-04). Er wordt niets opgenomen en geen andere audio
        // onderbroken.
        audioEngine.warmUp()
        meeting.audioEngine.warmUp()

        // Audiovangnet: bewaar de opname wanneer de gebruiker dat wil, zodat een
        // mislukte transcriptie of een crash niet meteen het gesprek kost.
        Task { [parakeetEngine, saveRecordings = settings.saveRecordings] in
            await parakeetEngine.setPreserveFinishedRecording(saveRecordings)
        }

        // Na een crash of geforceerd afsluiten kan er tijdelijke opname-audio zijn
        // achtergebleven. Die alsnog omzetten in gewone geschiedenis-items. Dit
        // pad bestond al en werd getest, maar had tot nu toe alleen op de iPhone
        // een aanroeper — op de Mac ging elke onderbroken opname verloren
        // (bevinding 2026-08-03).
        Task { await recoverInterruptedRecordings() }

        // Start watching configured folders for new media (M7). Safe to start
        // unconditionally: with no folders configured each scan is a no-op, and
        // the service picks up folders added later via `watchedFolders.refresh()`.
        watchedFolders.start()

        // PLAUD wordt voortaan alleen door de iPhone geïmporteerd. Zet een oude
        // Mac-instelling eenmalig uit en stop eventuele polling, zodat twee
        // apparaten nooit dezelfde cloudopname tegelijk transcriberen.
        if settings.plaudSyncEnabled {
            settings.plaudSyncEnabled = false
        }
        plaudSync.stop()

        // Bring up iCloud history sync if enabled + available (dormant otherwise).
        Task { await historySync.start() }

        Task {
            await resolveEngineSelection()
            await modelManager.refresh()
            switch modelManager.status {
            case .installed:
                appState = .ready
                try? await activeEngine.prepare()
            case .unsupported:
                appState = .error("Transcriptie is niet beschikbaar op dit apparaat")
            case .needsDownload, .downloading, .unknown:
                // Model missing but installable: the UI offers a download.
                appState = .ready
            }
        }
    }

    /// Verplaatst het bewaarde opnamebestand naar `Recordings/<id>.caf`, de plek
    /// waar ``TranscriptAudioStore`` hem verwacht. Alleen aanroepen nadat het
    /// transcript werkelijk is opgeslagen.
    private func preserveAudio(_ url: URL?, forEntryId id: String) {
        guard let url else { return }
        do {
            let directory = try TranscriptAudioStore.recordingsDirectory()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory
                .appendingPathComponent(id)
                .appendingPathExtension(url.pathExtension.isEmpty ? "caf" : url.pathExtension)
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            NSLog("AppEnvironment: kon opname niet bewaren: %@", String(describing: error))
            // Het bestand blijft in de tijdelijke map staan; de herstelronde bij
            // de volgende start ruimt het op of biedt het opnieuw aan.
        }
    }

    /// Zet achtergebleven tijdelijke opname-audio alsnog om in geschiedenis-items.
    /// Het audiobestand wordt pas gewist nadat de database-write is geslaagd; bij
    /// een mislukking blijft het staan voor een volgende poging.
    private func recoverInterruptedRecordings() async {
        let settings = self.settings
        let locale = Locale(identifier: settings.language.isEmpty ? "nl-NL" : settings.language)

        let batch: RecordingRecoveryBatch
        do {
            batch = try await parakeetEngine.recoverOrphanedRecordings(defaultLocale: locale)
        } catch {
            NSLog("AppEnvironment: recovery of interrupted recordings failed: %@", String(describing: error))
            return
        }

        guard !batch.recordings.isEmpty || batch.failedCount > 0 else { return }

        var savedCount = 0
        var failedCount = batch.failedCount
        for recovered in batch.recordings {
            let processed = TextProcessor.process(
                recovered.result.text,
                replacements: settings.replacements,
                clean: settings.cleanOutput,
                removeFillers: settings.removeFillers,
                language: recovered.language == .automatic ? "nl" : recovered.language.rawValue
            )
            guard !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await parakeetEngine.discardRecoveredRecording(id: recovered.recoveryID)
                continue
            }
            let entry = TranscriptEntry(
                id: UUID().uuidString,
                text: processed,
                createdAt: historyTimestampString(from: recovered.createdAt),
                name: "",
                pinned: false,
                language: recovered.language.rawValue,
                model: "parakeet-tdt-0.6b-v3",
                source: "mic.mac",
                duration: recovered.duration,
                segments: recovered.result.segments
            )
            do {
                try history.add(entry)
                await parakeetEngine.discardRecoveredRecording(id: recovered.recoveryID)
                savedCount += 1
            } catch {
                failedCount += 1
            }
        }

        if failedCount > 0 {
            Notifications.postCritical(
                "Een onderbroken opname kon niet automatisch worden hersteld. "
                    + "De tijdelijke audio blijft bewaard voor een volgende poging."
            )
        } else if savedCount > 0 {
            Notifications.post(
                savedCount == 1
                    ? "Een onderbroken opname is alsnog in de Geschiedenis gezet."
                    : "\(savedCount) onderbroken opnamen zijn alsnog in de Geschiedenis gezet."
            )
        }
    }

    /// Applies the ``EngineSelector`` fallback: if the user picked Apple Speech
    /// but the configured language is not in `SpeechTranscriber.supportedLocales`,
    /// surface a notice. (The active engine itself is fixed for the launch; the
    /// notice tells the user why Parakeet is in use.)
    private func resolveEngineSelection() async {
        let supported = await AppleSpeechEngine.supportedLanguageCodes()
        let decision = EngineSelector.decide(
            requested: settings.engine,
            language: settings.language,
            appleSupportedLanguageCodes: supported
        )
        engineNotice = decision.notice
        if let notice = decision.notice {
            NSLog("EngineSelector: %@", notice)
        }
    }

    /// Toggles the live-captions session (Home card / menu bar). Starting refuses
    /// (with a notification) while dictation or import is busy; see
    /// ``CaptionsService/start()``.
    func toggleCaptions() {
        if captions.isRunning {
            captions.stop()
        } else {
            captions.start()
        }
    }

    /// Starts the model download flow (menu / onboarding card).
    func downloadModel() {
        Task {
            appState = .loadingModel
            await modelManager.download()
            appState = modelManager.status.isReady ? .ready : .error("Model kon niet laden")
        }
    }

    #if DEBUG
    /// Debug helper preserved from M0.
    func simulateStateCycle() {
        dictation.simulateStateCycle()
    }
    #endif
}
