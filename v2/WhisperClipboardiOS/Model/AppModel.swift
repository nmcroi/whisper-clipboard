import Combine
import Core
import Foundation
import SwiftUI
import WhisperShared

/// The app-wide environment for the iOS companion: the shared Parakeet engine,
/// the GRDB history store (in this app's own sandboxed Application Support), the
/// current appearance, and the model-download state machine.
///
/// Kept deliberately small — this is the i0+i1 scaffold. Settings beyond the
/// theme (replacements, retention, filler removal) and iCloud sync come in later
/// rounds; the data layer is already sync-compatible with the Mac (identical
/// `TranscriptEntry` schema via `WhisperShared`).
@MainActor
final class AppModel: ObservableObject {

    /// The one shared transcription engine (pre-warmed, kept alive across records).
    let engine = ParakeetEngine()

    /// The history store, or `nil` if the DB couldn't be opened (rare — surfaced
    /// as an error banner rather than crashing).
    let history: HistoryStore?

    /// Chosen appearance. Persisted in `UserDefaults` under `ios.appearance`.
    @Published var appearance: AppSettings.AppearanceMode {
        didSet { Self.persistAppearance(appearance) }
    }

    /// Current model-download / readiness state, driving the onboarding card.
    @Published var modelStatus: ModelAssetStatus = .unknown

    /// The last user-facing error message (nil = none).
    @Published var errorMessage: String?

    private static let appearanceKey = "ios.appearance"

    init() {
        self.appearance = Self.loadAppearance()
        // Retention is unlimited for now (settings round adds a control). The DB
        // lives in this app's own sandbox, isolated from the Mac's copy.
        self.history = try? HistoryStore(retentionProvider: { nil })
    }

    // MARK: - Model lifecycle

    /// Refreshes `modelStatus` from the engine (called on appear).
    func refreshModelStatus() async {
        let status = await engine.assetStatus(for: Locale(identifier: "nl_NL"))
        modelStatus = status
        // If already installed, pre-warm so the first record is instant.
        if status.isReady {
            try? await engine.prepare()
        }
    }

    /// Kicks off the model download, streaming progress into `modelStatus`.
    func downloadModel() async {
        modelStatus = .downloading(progress: 0)
        // Poll the engine's progress while the download runs.
        let pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let status = await self.engine.assetStatus(for: Locale(identifier: "nl_NL"))
                await MainActor.run {
                    if case .downloading = status { self.modelStatus = status }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        do {
            try await engine.downloadAssets(for: Locale(identifier: "nl_NL"))
            pollTask.cancel()
            modelStatus = .installed
        } catch {
            pollTask.cancel()
            modelStatus = .needsDownload(progress: 0)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Appearance persistence

    private static func loadAppearance() -> AppSettings.AppearanceMode {
        let raw = UserDefaults.standard.string(forKey: appearanceKey) ?? ""
        return AppSettings.AppearanceMode(rawValue: raw) ?? .dark
    }

    private static func persistAppearance(_ mode: AppSettings.AppearanceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: appearanceKey)
    }
}
