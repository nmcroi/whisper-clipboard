import Core
import Foundation
import WhisperShared

/// Handmatige PLAUD-cloudsync op de iPhone. De iPhone is de primaire route:
/// NotePin → PLAUD-app/cloud → WhisperClip iPhone → iCloud → Mac.
/// Gedownloade audio is tijdelijk en wordt na transcriptie direct verwijderd.
@MainActor
final class PlaudSynciOSService: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var progressFraction = 0.0
    @Published private(set) var lastImportedCount = 0
    @Published private(set) var lastSyncedAt: Date?
    @Published private var progressState: PlaudSyncProgress = .notSynced

    private weak var app: AppModel?
    private let client = PlaudClient()
    private var task: Task<Void, Never>?

    private static let processedKey = "ios.plaud.processedIDs"
    private static let checkpointKey = "ios.plaud.lastSuccessfulSync"
    private static let defaultWindowHours = 48
    private static let overlap: TimeInterval = 24 * 60 * 60

    init(app: AppModel) {
        self.app = app
        self.lastSyncedAt = UserDefaults.standard.object(forKey: Self.checkpointKey) as? Date
    }

    /// Localiseert bij iedere weergave vanuit een taalneutrale toestand. Een
    /// taalwissel kan daardoor nooit een eerder vertaalde status laten staan.
    ///
    /// Na een herstart staat de toestand weer op `.notSynced`, terwijl er wel
    /// degelijk een eerdere synchronisatie bekend is. `Nog niet
    /// gesynchroniseerd` sprak dan de regel `Laatst bijgewerkt` eronder tegen
    /// (bevinding 2026-08-02). In dat geval blijft de statusregel leeg en
    /// vertelt de datum het verhaal.
    var progressText: String {
        if progressState == .notSynced, lastSyncedAt != nil { return "" }
        return localizedProgress(progressState)
    }

    var lastError: String? {
        guard case .failure(let failure) = progressState else { return nil }
        return localizedFailure(failure)
    }

    func syncNow() {
        guard !isSyncing else { return }
        task = Task { await performSync() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isSyncing = false
        progressState = .stopped
        progressFraction = 0
    }

    func testConnection(_ credentials: PlaudCredentials) async -> String? {
        guard credentials.isConfigured else {
            return L10n.string( "Vul eerst je PLAUD-account in.", locale: app?.interfaceLanguage.locale ?? Locale(identifier: "nl"))
        }
        do {
            let token = try await client.token(for: credentials)
            _ = try await client.probeConnection(token: token)
            return nil
        } catch let error as PlaudError {
            return localizedFailure(syncFailure(for: error))
        } catch {
            return L10n.string(
                "PLAUD-verbindingscontrole mislukt.",
                locale: app?.interfaceLanguage.locale ?? Locale(identifier: "nl")
            )
        }
    }

    private func performSync() async {
        guard let app, let history = app.history else {
            progressState = .failure(.historyUnavailable)
            return
        }
        guard let credentials = PlaudCredentials.load(), credentials.isConfigured else {
            progressState = .failure(.accountMissing)
            return
        }

        isSyncing = true
        lastImportedCount = 0
        progressFraction = 0
        progressState = .fetching
        defer { isSyncing = false }

        let now = Date()
        let configuredHours = UserDefaults.standard.object(forKey: "ios.plaud.windowHours") as? Int
            ?? Self.defaultWindowHours
        // 0 betekent bewust de volledige PLAUD-geschiedenis.
        let windowCutoff: Date? = configuredHours == 0
            ? nil
            : now.addingTimeInterval(-Double(configuredHours) * 60 * 60)
        let checkpoint = UserDefaults.standard.object(forKey: Self.checkpointKey) as? Date
        let checkpointSince = checkpoint?.addingTimeInterval(-Self.overlap)
        let since: Date?
        if let windowCutoff, let checkpointSince {
            since = max(windowCutoff, checkpointSince)
        } else {
            since = windowCutoff ?? checkpointSince
        }
        var processed = Set(UserDefaults.standard.stringArray(forKey: Self.processedKey) ?? [])

        do {
            let token = try await client.token(for: credentials)
            let listed = try await client.listRecordings(token: token, since: since)
            // De eerste iPhone-sync heeft nog geen eigen processed-ledger, maar
            // kan via iCloud wel PLAUD-transcripties zien die eerder door de Mac
            // zijn gemaakt. Herken die aan opnametijd + duur en koppel hun PLAUD-id
            // aan de iPhone-ledger, zodat de overstap geen dubbele regels maakt.
            let existingPlaud = try history.entries(filter: .plaud)
            for recording in listed where !processed.contains(recording.id) {
                guard let started = recording.startTime else { continue }
                let alreadyExists = existingPlaud.contains { entry in
                    guard let date = ISO8601DateFormatter().date(from: entry.createdAt) else { return false }
                    let sameMoment = abs(date.timeIntervalSince(started)) < 120
                    let sameDuration = abs(entry.duration - recording.duration) < 4
                    return sameMoment && sameDuration
                }
                if alreadyExists { processed.insert(recording.id) }
            }
            UserDefaults.standard.set(Array(processed).sorted(), forKey: Self.processedKey)
            let pending = listed
                .filter { recording in
                    guard let windowCutoff else { return true }
                    return (recording.startTime ?? .distantFuture) >= windowCutoff
                }
                .filter { !processed.contains($0.id) }
                .sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }

            guard !pending.isEmpty else {
                recordCheckpoint(now)
                progressState = .upToDate
                progressFraction = 1
                return
            }

            // Een PLAUD-import volgt dezelfde laatst gekozen transcriptietaal
            // als een gewone opname. Zo werkt ook automatische detectie en wordt
            // de feitelijk gebruikte keuze bij ieder geïmporteerd transcript bewaard.
            let transcriptionLanguage = app.transcriptionLanguage
            for (index, recording) in pending.enumerated() {
                try Task.checkCancellation()
                let number = index + 1
                progressState = .downloading(current: number, total: pending.count)
                progressFraction = Double(index) / Double(pending.count)

                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("plaud-\(recording.id).mp3")
                let downloaded = try await client.downloadAudio(recording, token: token, to: temporary)
                var downloadedAudioNeedsCleanup = true
                defer {
                    if downloadedAudioNeedsCleanup {
                        try? FileManager.default.removeItem(at: downloaded)
                    }
                }
                do {
                    try FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                        ofItemAtPath: downloaded.path
                    )
                } catch {
                    throw PlaudTemporaryAudioError.protectionFailed
                }

                progressState = .transcribing(current: number, total: pending.count)
                let result = try await app.engine.transcribeFile(
                    at: downloaded,
                    locale: transcriptionLanguage.locale
                )
                try Task.checkCancellation()
                do {
                    try FileManager.default.removeItem(at: downloaded)
                    downloadedAudioNeedsCleanup = false
                } catch {
                    throw PlaudTemporaryAudioError.cleanupFailed
                }
                let text = TextProcessor.process(
                    result.text,
                    replacements: app.replacements,
                    clean: true,
                    language: transcriptionLanguage == .automatic
                        ? ""
                        : transcriptionLanguage.rawValue
                ).trimmingCharacters(in: .whitespacesAndNewlines)

                // Ook stilte is definitief bekeken; zo blijft die niet iedere sync terugkomen.
                if !text.isEmpty {
                    let entry = TranscriptEntry(
                        id: "plaud.\(recording.id)",
                        text: text,
                        createdAt: ISO8601DateFormatter().string(from: recording.startTime ?? now),
                        name: "",
                        pinned: false,
                        language: transcriptionLanguage.rawValue,
                        model: "parakeet-tdt-0.6b-v3",
                        source: "plaud.ios",
                        duration: recording.duration,
                        segments: result.segments
                    )
                    try history.add(entry)
                    lastImportedCount += 1
                }

                processed.insert(recording.id)
                UserDefaults.standard.set(Array(processed).sorted(), forKey: Self.processedKey)
                progressFraction = Double(number) / Double(pending.count)
            }

            recordCheckpoint(now)
            progressState = .imported(lastImportedCount)
        } catch is CancellationError {
            progressState = .stopped
            progressFraction = 0
        } catch let error as PlaudError {
            fail(syncFailure(for: error))
        } catch {
            fail(.syncFailed)
        }
    }

    private func syncFailure(for error: PlaudError) -> PlaudSyncFailure {
        switch error {
        case .missingCredentials: .credentialsMissing
        case .authFailed(let detail): .authenticationFailed(detail)
        case .network: .network
        case .rateLimited: .rateLimited
        case .unexpectedResponse(let detail): .unexpectedResponse(detail)
        case .server(let detail): .server(detail)
        }
    }

    private func localizedProgress(_ progress: PlaudSyncProgress) -> String {
        let locale = app?.interfaceLanguage.locale ?? Locale(identifier: "nl")
        if case .failure(let failure) = progress {
            return localizedFailure(failure)
        }
        let format = L10n.string(dynamicKey: progress.localizationKey, locale: locale)
        let arguments = progress.integerArguments
        if arguments.count == 2 {
            return String(
                format: format,
                locale: locale,
                arguments[0],
                arguments[1]
            )
        }
        if let count = arguments.first {
            return String(
                format: format,
                locale: locale,
                count
            )
        }
        return format
    }

    private func localizedFailure(_ failure: PlaudSyncFailure) -> String {
        let locale = app?.interfaceLanguage.locale ?? Locale(identifier: "nl")
        let format = L10n.string(dynamicKey: failure.localizationKey, locale: locale)
        guard let detail = failure.detail else { return format }
        return String(format: format, locale: locale, detail)
    }

    private func recordCheckpoint(_ date: Date) {
        lastSyncedAt = date
        UserDefaults.standard.set(date, forKey: Self.checkpointKey)
    }

    private func fail(_ failure: PlaudSyncFailure) {
        progressState = .failure(failure)
        progressFraction = 0
    }
}

private enum PlaudTemporaryAudioError: Error {
    case protectionFailed
    case cleanupFailed
}
