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
        }
    }

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
        let history = Self.makeHistoryStore(retentionProvider: { retentionRef() })
        self.history = history

        // AI prompt modes (M4). The API key is read from the Keychain on demand.
        self.modes = ModesService(history: history)

        // File-import pipeline. Refuses while dictation is recording/transcribing,
        // mirroring the Python "one job at a time" guard.
        self.fileImport = FileImportService(
            engine: parakeetEngine,
            history: history,
            locale: { Locale(identifier: settingsRef().language.isEmpty ? "nl-NL" : settingsRef().language) },
            busyReason: { [weak dictation] in
                switch dictation?.phase {
                case .recording, .transcribing:
                    return "Wacht tot de huidige opname of transcriptie klaar is"
                default:
                    return nil
                }
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
                case .recording, .transcribing:
                    return "Stop eerst de dictaat-opname voordat je ondertitels start"
                default:
                    break
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
                case .recording, .transcribing: return true
                default: break
                }
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
                (fileImport?.importFiles(urls, source: "plaud") ?? []).map(\.url)
            },
            isBusy: { [weak dictation, weak fileImport, weak modelManager] in
                if modelManager?.status.isReady != true { return true }
                switch dictation?.phase {
                case .recording, .transcribing: return true
                default: break
                }
                return fileImport?.isBusy ?? false
            }
        )

        // Now that stored properties exist, bind the closures to `self`.
        settingsRef = { [weak self] in self?.settings ?? AppSettings() }
        stateSink = { [weak self] state in self?.appState = state }

        // The AppKit overlays (HUD, caption overlay) live outside the SwiftUI
        // colour-scheme environment, so give them the chosen appearance directly;
        // their dynamic `Theme` colors then resolve to the right palette.
        hud.appearanceProvider = { [weak self] in
            self?.settings.appearance.nsAppearance
        }
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
        // Refuse dictation while a file import is running.
        dictation.importBusyProvider = { [weak self] in self?.fileImport.isBusy ?? false }
        // Starting dictation pauses live captions (they do not auto-resume).
        dictation.onWillStartRecording = { [weak self] in self?.captions.stop() }

        // Direct insertion wiring (M5). Capture the frontmost app at recording
        // start; attempt insertion at completion (clipboard-only when disabled).
        dictation.captureInsertionTarget = { InsertionService.captureFrontmost() }
        dictation.insertionHandler = { [weak self] text, target in
            guard let self else { return .clipboardOnly(reason: .disabled) }
            return self.insertion.insert(text, settings: self.settings, target: target)
        }
    }

    /// Opens the on-disk history store, degrading through an in-memory queue if
    /// the disk DB can't be opened. Only an impossible double-failure (even an
    /// in-memory SQLite DB can't be created) is fatal, and then with a clear
    /// message rather than an opaque force-unwrap crash.
    private static func makeHistoryStore(retentionProvider: @escaping () -> Int?) -> HistoryStore {
        do {
            return try HistoryStore(retentionProvider: retentionProvider)
        } catch {
            NSLog("AppEnvironment: history DB open failed (%@); trying in-memory store.", String(describing: error))
        }
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

    /// Builds a `TranscriptEntry` from a finished dictation and stores it.
    private func saveCompletedTranscript(_ completion: DictationController.TranscriptCompletion) {
        let entry = TranscriptEntry(
            id: UUID().uuidString,
            text: completion.text,
            createdAt: historyTimestampString(from: Date()),
            name: "",
            pinned: false,
            language: completion.language,
            model: completion.model,
            source: completion.source,
            duration: completion.duration,
            segments: completion.segments
        )
        do {
            try history.add(entry)
            // Auto-export the completed dictation (M7). Best-effort; never blocks
            // or fails the dictation flow.
            autoExport.exportIfEnabled(entry)
        } catch {
            NSLog("AppEnvironment: failed to save transcript: %@", String(describing: error))
        }
    }

    /// Kicks off engine-selection resolution, model status refresh + pre-warm at launch.
    func bootstrap() {
        // One-time import of the old Python history.json (reads only; the JSON
        // is left untouched as a backup). No-op after the first successful run.
        history.migrateFromV3IfNeeded()

        // Start watching configured folders for new media (M7). Safe to start
        // unconditionally: with no folders configured each scan is a no-op, and
        // the service picks up folders added later via `watchedFolders.refresh()`.
        watchedFolders.start()

        // Start PLAUD cloud sync if enabled. Safe to start unconditionally: when
        // disabled it schedules nothing; enabling it later re-schedules via
        // `plaudSync.refresh()`.
        plaudSync.start()

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
