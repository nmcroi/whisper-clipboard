import Combine
import Core
import Foundation
import SwiftUI

/// Dependency-injection container shared across the app.
///
/// M2 wires the real dictation pipeline with a selectable transcription engine.
/// Parakeet (multilingual, incl. Dutch) is the primary engine; Apple Speech is
/// available when its on-device model supports the configured language. Both
/// engines are instantiated up front; the active one is resolved from settings
/// with a language-support fallback (see ``EngineSelector``).
@MainActor
final class AppEnvironment: ObservableObject {
    @Published var appState: AppState = .starting
    @Published var settings = AppSettings()
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
    private let hud: RecordingHUDController

    private var locale: Locale {
        Locale(identifier: settings.language.isEmpty ? "nl-NL" : settings.language)
    }

    init() {
        // Resolve the active engine synchronously from the initial settings.
        // Apple Speech's live language-support check is async, so at init we
        // default to honouring the requested engine; `bootstrap()` re-checks and
        // applies the fallback once `SpeechTranscriber.supportedLocales` is known.
        let initialSettings = AppSettings()
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

        // Now that stored properties exist, bind the closures to `self`.
        settingsRef = { [weak self] in self?.settings ?? AppSettings() }
        stateSink = { [weak self] state in self?.appState = state }
    }

    /// Kicks off engine-selection resolution, model status refresh + pre-warm at launch.
    func bootstrap() {
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
