import Combine
import Core
import Foundation
import GRDB
import SwiftUI

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
    @Published var settings = SettingsStore.load() {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.save(settings)
        }
    }
    /// Set by the menu bar; `HomeView` observes and resets it to `nil`.
    @Published var menuNavigationRequest: MenuNavigationRequest?
    /// A one-line Dutch notice when the active engine differs from the requested
    /// one (e.g. Apple Speech asked for but the language is unsupported).
    @Published private(set) var engineNotice: String?

    let audioEngine = AudioEngine()

    // Both engines exist for the app's lifetime; the active one is chosen below.
    let appleSpeechEngine = AppleSpeechEngine()
    let parakeetEngine = ParakeetEngine()

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
            }
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
            }
        )
        self.captions = captions
        self.captionOverlay = CaptionOverlayController(service: captions)

        // Now that stored properties exist, bind the closures to `self`.
        settingsRef = { [weak self] in self?.settings ?? AppSettings() }
        stateSink = { [weak self] state in self?.appState = state }
        retentionRef = { [weak self] in self?.settings.historyRetention }

        // Persist every completed dictation.
        dictation.onTranscriptCompleted = { [weak self] completion in
            self?.saveCompletedTranscript(completion)
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
            return try HistoryStore(dbQueue: try DatabaseQueue(), retentionProvider: retentionProvider)
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
        } catch {
            NSLog("AppEnvironment: failed to save transcript: %@", String(describing: error))
        }
    }

    /// Kicks off engine-selection resolution, model status refresh + pre-warm at launch.
    func bootstrap() {
        // One-time import of the old Python history.json (reads only; the JSON
        // is left untouched as a backup). No-op after the first successful run.
        history.migrateFromV3IfNeeded()

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
