import Combine
import Core
import SwiftUI

/// Dependency-injection container shared across the app.
///
/// For milestone M0 it owns only the observable `appState` and the settings
/// model. Real services (audio capture, transcription engine, clipboard,
/// history) are wired in later.
@MainActor
final class AppEnvironment: ObservableObject {
    @Published var appState: AppState = .starting
    @Published var settings = AppSettings()

    /// Debug helper: steps the app through its lifecycle states so the menu bar
    /// icon and status line can be exercised without a real recording pipeline.
    func simulateStateCycle() {
        let sequence: [AppState] = [
            .loadingModel,
            .ready,
            .recording,
            .transcribing,
            .ready,
        ]

        Task { @MainActor in
            for state in sequence {
                appState = state
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }
}
