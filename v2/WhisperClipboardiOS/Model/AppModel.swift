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

    #if WHISPERCLIP_PERSONAL || !WHISPERCLIP_PUBLIC
    /// PLAUD-cloudsync bestaat uitsluitend in de Personal-compilatie.
    lazy var plaudSync = PlaudSynciOSService(app: self)
    #endif

    /// Whether iCloud sync is enabled. Persisted in `UserDefaults` under
    /// `ios.icloudSyncEnabled`; available in Debug for Development-schema tests
    /// and forced off in Release while the Production schema is not live.
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

    /// Interface language. System follows the current supported system locale;
    /// the explicit alternatives override it app-wide without changing iOS.
    @Published var interfaceLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(interfaceLanguage.rawValue, forKey: Self.interfaceLanguageKey) }
    }

    /// Toont korte, niet-essentiële aanwijzingen in de hoofdschermen, zoals
    /// “Tik om op te nemen”. Statussen, voortgang en fouten blijven altijd staan.
    @Published var showHelpTips: Bool {
        didSet { UserDefaults.standard.set(showHelpTips, forKey: Self.showHelpTipsKey) }
    }

    /// Algemene hoofdschakelaar voor externe AI in de Notulist. Standaard uit;
    /// per vergadering is daarna nog een tweede expliciete keuze vereist.
    @Published var allowMeetingAI: Bool {
        didSet { UserDefaults.standard.set(allowMeetingAI, forKey: Self.allowMeetingAIKey) }
    }

    /// Laatst gekozen taal is de standaard voor de volgende opname. De keuze
    /// wordt ook afzonderlijk in ieder transcript opgeslagen.
    @Published var transcriptionLanguage: TranscriptionLanguage {
        didSet {
            UserDefaults.standard.set(transcriptionLanguage.rawValue, forKey: Self.transcriptionLanguageKey)
        }
    }

    /// Globale standaard-AI-aanbieder. Modellen blijven per aanbieder onthouden.
    @Published var aiProvider: AIProvider {
        didSet {
            UserDefaults.standard.set(aiProvider.rawValue, forKey: Self.aiProviderKey)
            // Notulist-AI heeft twee toestemmingen nodig. Een overstap naar een
            // aanbieder zonder sleutel trekt de algemene toestemming daarom in.
            if !hasAPIKey(for: aiProvider) { allowMeetingAI = false }
        }
    }

    @Published var aiModels: [AIProvider: String] {
        didSet {
            for provider in AIProvider.allCases {
                let model = aiModels[provider] ?? provider.defaultModel
                UserDefaults.standard.set(model, forKey: Self.aiModelKey(provider))
            }
        }
    }

    /// De woordenlijst (find → replace-regels), toegepast op elke transcriptie —
    /// zelfde regels als op de Mac. Lokaal bewaard als JSON in `UserDefaults`
    /// (`ios.replacements`) en gesynct met de Mac via ``ReplacementsCloudSync``
    /// (iCloud key-value store, last-writer-wins).
    @Published var replacements: [Replacement] {
        didSet {
            guard replacements != oldValue else { return }
            Self.persistReplacements(replacements)
            // Publiceer alleen eigen bewerkingen; een binnengekomen remote lijst
            // (applyingRemoteReplacements) mag niet terug de cloud in echoën.
            // publish() is gedebounced — tikken in de editor spamt de store niet.
            guard !applyingRemoteReplacements else { return }
            replacementsSync.publish(replacements)
        }
    }

    /// Herbruikbare deelnemers voor Notulen, lokaal bewaard en via iCloud met
    /// de Mac gedeeld. Maximaal één contact is gemarkeerd als 'ik'.
    @Published var meetingContacts: [SavedMeetingContact] {
        didSet {
            guard meetingContacts != oldValue else { return }
            Self.persistMeetingContacts(meetingContacts)
            guard !applyingRemoteMeetingContacts else { return }
            meetingContactsSync.publish(meetingContacts)
        }
    }

    /// iCloud KV-sync voor de woordenlijst. Los van `historySync` (CKSyncEngine):
    /// werkt ook nu die nog uit staat, en degradeert stil zonder entitlement.
    private let replacementsSync = ReplacementsCloudSync(updatedAtKey: "ios.replacementsUpdatedAt")
    /// Vlag rond het toepassen van een remote lijst, zodat de didSet hierboven
    /// niet opnieuw publiceert (sync-lus-preventie, laag 2).
    private var applyingRemoteReplacements = false
    private let meetingContactsSync = MeetingContactsCloudSync(updatedAtKey: "ios.meetingContactsUpdatedAt")
    private var applyingRemoteMeetingContacts = false

    /// Current model-download / readiness state, driving the onboarding card.
    @Published var modelStatus: ModelAssetStatus = .unknown

    /// Byte-level download progress ("X van Y MB"), nil when not downloading.
    /// Kept separate from `modelStatus` so the fraction and the byte text update
    /// together without widening the shared `ModelAssetStatus` enum.
    @Published var downloadBytes: ModelDownloadByteProgress?

    /// The last user-facing error message (nil = none).
    @Published var errorMessage: String?
    /// Niet-foutieve, eenmalige melding, bijvoorbeeld na geslaagd crashherstel.
    @Published var noticeMessage: String?

    private var didAttemptRecordingRecovery = false

    private static let appearanceKey = "ios.appearance"
    private static let interfaceLanguageKey = "ios.interfaceLanguage"
    private static let showHelpTipsKey = "ios.showHelpTips"
    private static let allowMeetingAIKey = "ios.allowMeetingAI"
    private static let icloudSyncKey = "ios.icloudSyncEnabled"
    private static let replacementsKey = "ios.replacements"
    private static let meetingContactsKey = "ios.meetingContacts"
    private static let transcriptionLanguageKey = "ios.transcriptionLanguage"
    private static let aiProviderKey = "ai.defaultProvider"

    init() {
        self.appearance = Self.loadAppearance()
        self.interfaceLanguage = AppLanguage(
            rawValue: UserDefaults.standard.string(forKey: Self.interfaceLanguageKey) ?? ""
        ) ?? .system
        self.showHelpTips = UserDefaults.standard.object(forKey: Self.showHelpTipsKey) as? Bool ?? true
        self.allowMeetingAI = UserDefaults.standard.bool(forKey: Self.allowMeetingAIKey)
        self.transcriptionLanguage = TranscriptionLanguage(
            rawValue: UserDefaults.standard.string(forKey: Self.transcriptionLanguageKey) ?? ""
        ) ?? AppFeatureConfiguration.defaultTranscriptionLanguage
        self.aiProvider = AIProvider(
            rawValue: UserDefaults.standard.string(forKey: Self.aiProviderKey) ?? ""
        ) ?? .anthropic
        self.aiModels = Dictionary(uniqueKeysWithValues: AIProvider.allCases.map { provider in
            let saved = UserDefaults.standard.string(forKey: Self.aiModelKey(provider))
            return (provider, saved?.isEmpty == false ? saved! : provider.defaultModel)
        })
        self.replacements = Self.loadReplacements()
        self.meetingContacts = Self.loadMeetingContacts()
        // Debug mag expliciet tegen het Development-schema testen, maar begint
        // altijd met de eerder gekozen (standaard uitgeschakelde) stand. Release
        // blijft hard uit totdat het schema bewust naar Production is uitgerold.
        #if DEBUG
        UserDefaults.standard.register(defaults: [Self.icloudSyncKey: false])
        let initialSyncEnabled = UserDefaults.standard.bool(forKey: Self.icloudSyncKey)
        #else
        UserDefaults.standard.set(false, forKey: Self.icloudSyncKey)
        let initialSyncEnabled = false
        #endif
        self.icloudSyncEnabled = initialSyncEnabled
        // Retention is unlimited for now (settings round adds a control). The DB
        // lives in this app's own sandbox, isolated from the Mac's copy.
        let store: HistoryStore?
        do {
            store = try HistoryStore(retentionProvider: { nil })
        } catch {
            store = nil
        }
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
        if store == nil {
            self.errorMessage = L10n.string(
                "De geschiedenis kon niet worden geopend.",
                locale: interfaceLanguage.locale
            )
        }

        // Woordenlijst-sync: pas een remote lijst toe onder de vlag (didSet
        // publiceert dan niet terug). De timestamp-administratie doet het
        // sync-component zelf.
        replacementsSync.onRemoteChange = { [weak self] list in
            guard let self, self.replacements != list else { return }
            self.applyingRemoteReplacements = true
            self.replacements = list
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

    // MARK: - Model lifecycle

    /// Refreshes `modelStatus` from the engine (called on appear).
    func refreshModelStatus() async {
        let status = await engine.assetStatus(for: transcriptionLanguage.locale)
        modelStatus = status
        // If already installed, pre-warm so the first record is instant.
        if status.isReady {
            do {
                try await engine.prepare()
                await recoverInterruptedRecordingsIfNeeded()
            } catch {
                modelStatus = await engine.assetStatus(for: transcriptionLanguage.locale)
                errorMessage = ErrorLocalization.message(for: error, language: interfaceLanguage)
            }
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
                let status = await self.engine.assetStatus(for: self.transcriptionLanguage.locale)
                let bytes = await self.engine.downloadByteProgress()
                await MainActor.run {
                    if case .downloading = status { self.modelStatus = status }
                    self.downloadBytes = bytes
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        do {
            try await engine.downloadAssets(for: transcriptionLanguage.locale)
            pollTask.cancel()
            downloadBytes = nil
            modelStatus = .installed
            await recoverInterruptedRecordingsIfNeeded()
        } catch {
            pollTask.cancel()
            downloadBytes = nil
            modelStatus = .needsDownload(progress: 0)
            errorMessage = ErrorLocalization.message(for: error, language: interfaceLanguage)
        }
    }

    /// Zet na een crash of geforceerd afsluiten achtergebleven tijdelijke audio
    /// alsnog om in gewone geschiedenis-items. Het audiobestand wordt pas gewist
    /// nadat de database-write is geslaagd.
    private func recoverInterruptedRecordingsIfNeeded() async {
        guard !didAttemptRecordingRecovery, let history else { return }
        didAttemptRecordingRecovery = true

        do {
            let batch = try await engine.recoverOrphanedRecordings(
                defaultLocale: transcriptionLanguage.locale
            )
            var savedCount = 0
            var failedCount = batch.failedCount
            for recovered in batch.recordings {
                let processed = TextProcessor.process(
                    recovered.result.text,
                    replacements: replacements,
                    clean: true,
                    language: recovered.language == .automatic ? "" : recovered.language.rawValue
                )
                guard !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await engine.discardRecoveredRecording(id: recovered.recoveryID)
                    continue
                }
                let entry = TranscriptEntry(
                    id: UUID().uuidString,
                    text: processed,
                    createdAt: ISO8601DateFormatter().string(from: recovered.createdAt),
                    name: "",
                    pinned: false,
                    language: recovered.language.rawValue,
                    model: "parakeet-tdt-0.6b-v3",
                    source: "mic.ios",
                    duration: recovered.duration,
                    segments: recovered.result.segments
                )
                do {
                    try history.add(entry)
                    await engine.discardRecoveredRecording(id: recovered.recoveryID)
                    savedCount += 1
                } catch {
                    failedCount += 1
                }
            }

            if failedCount > 0 {
                // RootView toont fout- en succesmeldingen met twee aparte alerts.
                // Bied bij een gemengd resultaat alleen de fout aan, zodat twee
                // gelijktijdige modal alerts elkaar niet kunnen verdringen.
                noticeMessage = nil
                errorMessage = L10n.string(
                    "Een onderbroken opname kon niet automatisch worden hersteld. De tijdelijke audio blijft bewaard voor een volgende poging.",
                    locale: interfaceLanguage.locale
                )
            } else if savedCount == 1 {
                noticeMessage = L10n.string(
                    "Een onderbroken opname is hersteld en in Geschiedenis bewaard.",
                    locale: interfaceLanguage.locale
                )
            } else if savedCount > 1 {
                noticeMessage = String(
                    format: L10n.string(
                        "%lld onderbroken opnamen zijn hersteld en in Geschiedenis bewaard.",
                        locale: interfaceLanguage.locale
                    ),
                    locale: interfaceLanguage.locale,
                    savedCount
                )
            }
        } catch {
            errorMessage = ErrorLocalization.message(for: error, language: interfaceLanguage)
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

    func presentDataChangeError(_ error: Error) {
        errorMessage = String(
            format: L10n.string(
                "De wijziging kon niet worden opgeslagen: %@",
                locale: interfaceLanguage.locale
            ),
            locale: interfaceLanguage.locale,
            error.localizedDescription
        )
    }

    // MARK: - Woordenlijst-persistentie

    private static func loadReplacements() -> [Replacement] {
        guard let data = UserDefaults.standard.data(forKey: replacementsKey) else { return [] }
        return (try? JSONDecoder().decode([Replacement].self, from: data)) ?? []
    }

    private static func persistReplacements(_ replacements: [Replacement]) {
        guard let data = try? JSONEncoder().encode(replacements) else { return }
        UserDefaults.standard.set(data, forKey: replacementsKey)
    }

    private static func loadMeetingContacts() -> [SavedMeetingContact] {
        guard let data = UserDefaults.standard.data(forKey: meetingContactsKey) else { return [] }
        return (try? JSONDecoder().decode([SavedMeetingContact].self, from: data)) ?? []
    }

    private static func persistMeetingContacts(_ contacts: [SavedMeetingContact]) {
        guard let data = try? JSONEncoder().encode(contacts) else { return }
        UserDefaults.standard.set(data, forKey: meetingContactsKey)
    }

    // MARK: - AI-providerinstellingen

    func selectedModel(for provider: AIProvider) -> String {
        aiModels[provider] ?? provider.defaultModel
    }

    func setSelectedModel(_ model: String, for provider: AIProvider) {
        var updated = aiModels
        updated[provider] = model
        aiModels = updated
    }

    func hasAPIKey(for provider: AIProvider) -> Bool {
        KeychainStore.hasKey(for: provider)
    }

    func availableModels(for provider: AIProvider) async throws -> [String] {
        guard let key = try KeychainStore.read(for: provider), !key.isEmpty else {
            throw AIServiceError.missingKey(provider)
        }
        let live = try await AIClientFactory.make(provider: provider, apiKey: key).listModels()
        return live.isEmpty ? provider.fallbackModels : live
    }

    private static func aiModelKey(_ provider: AIProvider) -> String {
        "ai.model.\(provider.rawValue)"
    }
}
