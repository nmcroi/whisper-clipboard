import Combine
import Core
import Foundation
import SwiftUI
import UIKit
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

    /// Stuurt wijzigingen in de HistoryStore (revision-bump bij hernoemen,
    /// verplaatsen, opslaan, …) door naar de views. Die observeren alleen
    /// AppModel; zonder deze doorgifte bleef bv. een hernoemde notitie zijn oude
    /// titel tonen tot een toevallige andere her-render (bug 2026-07-05).
    private var historyObservation: AnyCancellable?

    /// iCloud history sync (i2). `nil` when the DB couldn't be opened (no store to
    /// sync). Dormant until the toggle is on AND an iCloud account is available.
    let historySync: HistorySyncEngine?

    /// AI post-processing (Claude) service, shared by History- en Note-detail.
    /// `nil` wanneer de DB niet geopend kon worden (geen store om resultaten in
    /// te bewaren). Leest de API-key uit de Keychain van dit toestel.
    let modes: ModesService?

    /// Whether iCloud sync is enabled. Persisted in `UserDefaults` under
    /// `ios.icloudSyncEnabled`; defaults to on (matches the Mac default).
    @Published var icloudSyncEnabled: Bool {
        didSet {
            guard icloudSyncEnabled != oldValue else { return }
            UserDefaults.standard.set(icloudSyncEnabled, forKey: Self.icloudSyncKey)
            Task { await historySync?.settingChanged() }
        }
    }

    /// Chosen appearance. Persisted in `UserDefaults` under `ios.appearance`.
    @Published var appearance: AppSettings.AppearanceMode {
        didSet { Self.persistAppearance(appearance) }
    }

    /// Current model-download / readiness state, driving the onboarding card.
    @Published var modelStatus: ModelAssetStatus = .unknown

    /// Byte-level download progress ("X van Y MB"), nil when not downloading.
    /// Kept separate from `modelStatus` so the fraction and the byte text update
    /// together without widening the shared `ModelAssetStatus` enum.
    @Published var downloadBytes: ModelDownloadByteProgress?

    /// The last user-facing error message (nil = none).
    @Published var errorMessage: String?

    private static let appearanceKey = "ios.appearance"
    private static let icloudSyncKey = "ios.icloudSyncEnabled"

    init() {
        self.appearance = Self.loadAppearance()
        // iCloud-sync staat voorlopig UIT: de CloudKit-container bestaat wel, maar
        // het Production-schema is nog niet uitgerold, en de account-check kan
        // tegen Production hard traps veroorzaken. Tot dat na de vakantie netjes is
        // ingericht (schema → Production + een betrouwbare binary-entitlement-check;
        // `HistorySyncEngine.hasCloudKitEntitlement` leest nu het profiel i.p.v. de
        // binary en klopt niet als App ID iCloud heeft maar de build zonder iCloud
        // is gesigneerd) blijft de toggle uit én uitgeschakeld (zie SettingsSheet).
        UserDefaults.standard.register(defaults: [Self.icloudSyncKey: false])
        let syncEnabled = UserDefaults.standard.bool(forKey: Self.icloudSyncKey)
        self.icloudSyncEnabled = syncEnabled
        // Retention is unlimited for now (settings round adds a control). The DB
        // lives in this app's own sandbox, isolated from the Mac's copy.
        let store = try? HistoryStore(retentionProvider: { nil })
        self.history = store
        self.modes = store.map { ModesService(history: $0) }
        if let store {
            let engine = HistorySyncEngine(
                store: store,
                isEnabled: { UserDefaults.standard.bool(forKey: Self.icloudSyncKey) }
            )
            self.historySync = engine
            // Bring sync up if enabled + an iCloud account is available; dormant
            // otherwise (e.g. an unsigned simulator build with no CloudKit).
            Task { await engine.start() }
        } else {
            self.historySync = nil
        }

        // Zombie-sweep bij app-start: een opname sterft mét het proces, dus bij
        // launch loopt er nooit een legitieme opname. Alles wat nog als Live
        // Activity op het lock-screen hangt, is achtergebleven door een gekild
        // proces — ruim het onmiddellijk op. Draait ook als de gebruiker nooit een
        // nieuwe opname start (RecordingLiveActivityController.start() zou anders
        // pas bij de volgende opname opruimen).
        Task { await RecordingStopBus.endAllActivities() }

        // Geef store-wijzigingen door aan de views (zie historyObservation-doc).
        // Bewust als LAATSTE in init: de closure vangt `self` en dat mag pas
        // wanneer alle stored properties geïnitialiseerd zijn.
        self.historyObservation = store?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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
        errorMessage = nil
        modelStatus = .downloading(progress: 0)
        // Keep the screen awake for the duration — a multi-minute download over
        // a locked/dimmed screen is where interrupted, half-written models come
        // from (Issue 3). Restored in the defer below.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        // Poll the engine's fraction *and* byte progress while the download runs
        // so both the bar and the "X van Y MB" text keep moving.
        let pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let status = await self.engine.assetStatus(for: Locale(identifier: "nl_NL"))
                let bytes = await self.engine.downloadByteProgress()
                await MainActor.run {
                    if case .downloading = status { self.modelStatus = status }
                    self.downloadBytes = bytes
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        do {
            try await engine.downloadAssets(for: Locale(identifier: "nl_NL"))
            pollTask.cancel()
            downloadBytes = nil
            modelStatus = .installed
        } catch {
            pollTask.cancel()
            downloadBytes = nil
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
