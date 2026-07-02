import Combine
import Core
import Foundation
import SwiftUI

/// Dependency-injection container shared across the app.
///
/// M1 wires the real dictation pipeline: audio capture, the Apple Speech
/// streaming engine, orchestration, the global hotkey, and the recording HUD.
@MainActor
final class AppEnvironment: ObservableObject {
    @Published var appState: AppState = .starting
    @Published var settings = AppSettings()

    let audioEngine = AudioEngine()
    let engine: AppleSpeechEngine
    let modelManager: EngineModelManager
    let dictation: DictationController
    let hotkeys: HotkeyManager
    private let hud: RecordingHUDController

    private var locale: Locale {
        Locale(identifier: settings.language.isEmpty ? "nl-NL" : settings.language)
    }

    init() {
        let engine = AppleSpeechEngine()
        self.engine = engine

        let modelManager = EngineModelManager(
            engine: engine,
            locale: Locale(identifier: "nl-NL")
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

    /// Kicks off model status refresh + pre-warm at launch.
    func bootstrap() {
        Task {
            await modelManager.refresh()
            switch modelManager.status {
            case .installed:
                appState = .ready
                try? await engine.prepare()
            case .unsupported:
                // No on-device model for this language on this macOS build.
                appState = .error("Taal ‘\(settings.language)’ niet beschikbaar voor spraakherkenning")
            case .needsDownload, .downloading, .unknown:
                // Model missing but installable: the UI offers a download.
                appState = .ready
            }
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
