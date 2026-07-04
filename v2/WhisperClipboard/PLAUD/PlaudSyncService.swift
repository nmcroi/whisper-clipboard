import Core
import Foundation
import Observation

/// Pulls PLAUD cloud recordings and feeds them into the existing
/// ``FileImportService`` transcription pipeline.
///
/// ## Strategy
/// A periodic **timer poll** (every `plaudSyncIntervalMinutes`, default 15) plus
/// a manual "Synchroniseer nu". Each run: resolve a token (login from stored
/// email+password, or use a pasted token), list recordings within the **sync
/// window** and **newer than the last successful sync** (minus an overlap margin),
/// dedup them against a persisted set of processed recording ids, download each
/// new one's audio to a dedicated PLAUD dir, and enqueue it into
/// ``FileImportService`` — which gives transcription, diarization, history,
/// auto-export and AI for free. The interval clamp and the window/`since` math
/// live in the pure ``Core/PlaudSyncLogic``.
///
/// ## Sync window
/// `plaudSyncWindowDays` (default 30; 0 = all history) bounds how far back a sync
/// reaches. It shapes the effective `since` passed to the list endpoint — so even
/// a first sync on an empty checkpoint only pulls the last N days, not the entire
/// history — and is re-applied client-side as a belt-and-suspenders cutoff on each
/// listed recording's `startTime`, since PLAUD's `since` may be coarse.
///
/// ## De-duplication across restarts
/// Every downloaded recording's PLAUD `id` is persisted to a small
/// `plaud-processed.json` (mirroring ``WatchedProcessedStore``), so relaunching
/// never re-downloads a recording already run through the pipeline.
///
/// ## Robustness
/// - Never crashes on API failure: every error maps to a Dutch status message.
/// - Respects the importer busy-guard (won't stampede a live dictation/import).
/// - A recording is only marked processed once the importer has **accepted** its
///   downloaded file, and the sync checkpoint is only advanced when *every* listed
///   recording was handled — so a refused batch or a failed download (even one
///   older than the 24h overlap margin) stays eligible for a future run.
@MainActor
@Observable
final class PlaudSyncService {

    // MARK: - Status (drives the Settings status area)

    enum Status: Equatable {
        case idle
        case syncing
        case success(imported: Int, at: Date)
        case failed(String)
    }

    /// Live status for the UI. `lastError` persists the last failure text even
    /// after a later success cleared `status`, for the "laatste fout" line.
    private(set) var status: Status = .idle
    /// Timestamp of the last completed (successful) sync.
    private(set) var lastSyncedAt: Date?
    /// Count of recordings imported in the last successful sync.
    private(set) var lastImportedCount = 0
    /// Human (Dutch) text of the last failure, or nil if the last run succeeded.
    private(set) var lastError: String?
    /// True while a sync run is in flight (guards against overlap).
    private(set) var isSyncing = false

    // MARK: - Dependencies

    /// Current settings (enabled flag, interval, email). Read on demand.
    private let settings: () -> AppSettings
    /// Loads the PLAUD credentials (email+password/token) from the Keychain.
    private let credentialsProvider: () -> PlaudCredentials?
    /// Enqueues downloaded audio files into the transcription pipeline and returns
    /// the subset of `urls` it **accepted** (the importer refuses the whole batch
    /// while dictation/import is busy, and drops unsupported files). Only accepted
    /// recordings are marked processed, so a refused batch is retried next run.
    private let importer: (_ urls: [URL]) -> [URL]
    /// True when the importer/dictation is busy and we must hold off this tick.
    private let isBusy: () -> Bool
    /// The client (injected for tests; default uses `.shared`).
    private let client: PlaudClient
    private let store: PlaudProcessedStore
    /// Persists the last successful sync time so each run only asks PLAUD for
    /// recordings newer than that (minus an overlap margin), instead of paging the
    /// full history every tick.
    private let checkpoint: PlaudSyncCheckpoint
    /// Directory downloaded audio is saved to.
    private let audioDirectory: URL

    /// Recording ids already downloaded + enqueued (loaded from disk at init).
    private var processed: Set<String>
    /// The last successful sync time (loaded from disk at init), or nil on a first
    /// run — a nil `since` lists the full history once, then narrows.
    private var lastSuccessfulSync: Date?

    private var timer: Timer?

    /// How far *before* the last successful sync each run re-fetches, so a
    /// recording that landed in PLAUD's cloud slightly out of `start_time` order
    /// (or during the previous run) is never missed. One day is generous and cheap
    /// (dedup drops anything already processed).
    static let syncOverlapMargin: TimeInterval = 24 * 60 * 60

    init(
        settings: @escaping () -> AppSettings,
        credentialsProvider: @escaping () -> PlaudCredentials? = { PlaudCredentials.load() },
        importer: @escaping (_ urls: [URL]) -> [URL],
        isBusy: @escaping () -> Bool,
        client: PlaudClient = PlaudClient(),
        store: PlaudProcessedStore = PlaudProcessedStore(),
        checkpoint: PlaudSyncCheckpoint = PlaudSyncCheckpoint(),
        audioDirectory: URL? = nil
    ) {
        self.settings = settings
        self.credentialsProvider = credentialsProvider
        self.importer = importer
        self.isBusy = isBusy
        self.client = client
        self.store = store
        self.checkpoint = checkpoint
        self.audioDirectory = audioDirectory ?? Self.defaultAudioDirectory
        self.processed = store.load()
        self.lastSuccessfulSync = checkpoint.load()
    }

    /// `~/Library/Application Support/Whisper Clipboard v2/PLAUD/`.
    static var defaultAudioDirectory: URL {
        AppSupport.baseDirectory.appendingPathComponent("PLAUD", isDirectory: true)
    }

    // MARK: - Lifecycle

    /// Starts (or restarts) the poll timer to match the current settings. Safe to
    /// call repeatedly — e.g. after the user toggles sync or changes the interval.
    /// When sync is disabled, this simply stops the timer.
    func start() {
        timer?.invalidate()
        timer = nil

        guard settings().plaudSyncEnabled else { return }

        // Kick a first sync shortly after enabling (not synchronously, so enabling
        // the toggle stays snappy).
        Task { [weak self] in await self?.syncIfDue(trigger: .automatic) }

        let minutes = PlaudSyncLogic.clampIntervalMinutes(settings().plaudSyncIntervalMinutes)
        let interval = TimeInterval(minutes * 60)
        // Construct unscheduled and add once in `.common` mode so it keeps firing
        // while menus/panels track the run loop — without also being registered in
        // `.default` (which `Timer.scheduledTimer` would do).
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncIfDue(trigger: .automatic) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops polling (teardown; not required for app quit).
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-reads settings and reschedules the timer (call after the user changes
    /// the enabled flag or interval in Settings).
    func refresh() {
        start()
    }

    // MARK: - Sync

    enum Trigger { case automatic, manual }

    /// A manual "Synchroniseer nu": always attempts, even if busy is transiently
    /// true (it still won't overlap another in-flight sync).
    func syncNow() {
        Task { await self.performSync(trigger: .manual) }
    }

    /// An automatic tick: skips when the importer/dictation is busy (the files
    /// will be picked up next tick).
    private func syncIfDue(trigger: Trigger) async {
        guard settings().plaudSyncEnabled else { return }
        if isBusy() { return }
        await performSync(trigger: trigger)
    }

    /// The actual sync run. Never throws; maps every failure to `status`/`lastError`.
    func performSync(trigger: Trigger) async {
        guard !isSyncing else { return }

        guard let credentials = credentialsProvider(), credentials.isConfigured else {
            setFailure(PlaudError.missingCredentials.errorDescription ?? "Geen PLAUD-inloggegevens.")
            return
        }

        isSyncing = true
        status = .syncing
        defer { isSyncing = false }

        // Capture the run's start *before* the network call: on success we persist
        // this as the new checkpoint, so anything that lands in PLAUD's cloud
        // during this run is still re-fetched next time (belt-and-braces with the
        // overlap margin below). The window cutoff is anchored to the same instant.
        let runStartedAt = Date()
        let windowDays = settings().plaudSyncWindowDays
        // The effective `since`: the more recent of (checkpoint − overlap) and the
        // window cutoff (now − windowDays). On a first run with a window this is the
        // window cutoff (not nil), so an empty checkpoint doesn't pull all history;
        // with windowDays == 0 it's the checkpoint bound (nil on the first run).
        let since = PlaudSyncLogic.effectiveSince(
            checkpoint: lastSuccessfulSync,
            overlap: Self.syncOverlapMargin,
            windowDays: windowDays,
            now: runStartedAt
        )
        // A client-side cutoff re-applied to each listed recording, since PLAUD's
        // `since` may be coarse. nil when there is no window (windowDays == 0).
        let windowCutoff = PlaudSyncLogic.windowCutoff(windowDays: windowDays, now: runStartedAt)

        do {
            let token = try await client.token(for: credentials)
            let recordings = try await client.listRecordings(token: token, since: since)
            // Belt-and-suspenders: drop anything older than the window cutoff even
            // if it slipped through PLAUD's `since` filter. A recording with no
            // start_time is kept (we can't prove it's out of range).
            let windowed: [PlaudRecording]
            if let windowCutoff {
                windowed = recordings.filter { ($0.startTime ?? .distantFuture) >= windowCutoff }
            } else {
                windowed = recordings
            }
            // Single-pass dedup against the persisted processed set, newest first.
            let allNew = windowed.filter { !processed.contains($0.id) }
            let toDownload = allNew.sorted {
                ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast)
            }

            guard !toDownload.isEmpty else {
                recordCheckpoint(runStartedAt)
                setSuccess(imported: 0)
                return
            }

            // Download each new recording, remembering which id produced which
            // file so we only mark a recording processed once the importer has
            // ACCEPTED its file. `allHandled` stays true only if every recording
            // this run intended to fetch was downloaded AND accepted; any skip
            // (busy break, download error, importer refusal) holds the checkpoint
            // back so the next run re-lists — including items older than the 24h
            // overlap margin that would otherwise fall out of the `since` window.
            var idByURL: [URL: String] = [:]
            var downloadedURLs: [URL] = []
            var allHandled = true
            for recording in toDownload {
                // A late busy check on automatic runs: don't fight a dictation that
                // started mid-sync. Manual runs push through (the importer itself
                // still guards, refusing while dictation records).
                if trigger == .automatic, isBusy() {
                    allHandled = false
                    break
                }

                let preferred = audioDirectory.appendingPathComponent(recording.suggestedFilenameStem + ".mp3")
                let written: URL
                do {
                    // Use the *returned* URL — its extension may differ from the
                    // requested .mp3 when PLAUD serves another format (e.g. opus).
                    written = try await client.downloadAudio(recording, token: token, to: preferred)
                } catch {
                    // One failed download shouldn't abort the whole sync; leave it
                    // unprocessed AND hold the checkpoint so the next run retries it
                    // (even if it's older than the overlap margin).
                    NSLog("PlaudSync: download failed for %@: %@", recording.id, String(describing: error))
                    allHandled = false
                    continue
                }
                idByURL[written] = recording.id
                downloadedURLs.append(written)
            }

            // Hand the downloaded files to the importer; it returns the subset it
            // accepted (it refuses the whole batch while busy). Mark processed only
            // the recordings whose file was accepted.
            let acceptedURLs = downloadedURLs.isEmpty ? [] : importer(downloadedURLs)
            let acceptedSet = Set(acceptedURLs)
            for url in downloadedURLs {
                guard let id = idByURL[url] else { continue }
                if acceptedSet.contains(url) {
                    processed.insert(id)
                } else {
                    // Downloaded but the importer refused it: keep it eligible.
                    allHandled = false
                }
            }

            store.save(processed)
            // Only advance the checkpoint when nothing was left behind — every
            // intended item was downloaded AND accepted. A refused batch, a failed
            // download, or a busy break holds the checkpoint so the next run
            // re-lists (including items older than the 24h overlap margin).
            if allHandled {
                recordCheckpoint(runStartedAt)
            }
            setSuccess(imported: acceptedURLs.count)
        } catch let error as PlaudError {
            setFailure(error.errorDescription ?? "PLAUD-fout.")
        } catch {
            setFailure(PlaudError.server(error.localizedDescription).errorDescription ?? "PLAUD-fout.")
        }
    }

    // MARK: - Connection test

    /// Validates credentials by logging in (or checking a pasted token via a
    /// cheap list call). Returns a Dutch error message on failure, or nil on
    /// success. Does not mutate sync state.
    func testConnection(_ credentials: PlaudCredentials) async -> String? {
        guard credentials.isConfigured else {
            return PlaudError.missingCredentials.errorDescription
        }
        do {
            let token = try await client.token(for: credentials)
            // A pasted token is only proven valid by an actual authenticated call.
            // Do the cheapest possible one: a single list page, no paging and no
            // `since` heuristic — just enough to exercise auth + the list endpoint.
            _ = try await client.probeConnection(token: token)
            return nil
        } catch let error as PlaudError {
            return error.errorDescription
        } catch {
            return PlaudError.server(error.localizedDescription).errorDescription
        }
    }

    // MARK: - Status helpers

    /// Persists `date` as the new sync checkpoint (in memory + on disk) so the
    /// next run only asks PLAUD for newer recordings.
    private func recordCheckpoint(_ date: Date) {
        lastSuccessfulSync = date
        checkpoint.save(date)
    }

    private func setSuccess(imported: Int) {
        let now = Date()
        lastSyncedAt = now
        lastImportedCount = imported
        lastError = nil
        status = .success(imported: imported, at: now)
    }

    private func setFailure(_ message: String) {
        lastError = message
        status = .failed(message)
    }
}

// MARK: - Processed-set persistence

/// Persists the set of already-downloaded PLAUD recording ids to
/// `plaud-processed.json`, so restarts don't re-download recordings already run
/// through the pipeline. A thin wrapper over the shared ``JSONIdentitySet``
/// (same on-disk format: a sorted `[String]`).
struct PlaudProcessedStore {

    /// The fixed on-disk filename (unchanged, so existing state loads).
    static let filename = "plaud-processed.json"

    private let backing: JSONIdentitySet

    /// Default location under Application Support next to the other v2 state.
    /// Pass `fileURL` (tests) to redirect it elsewhere.
    init(fileURL: URL? = nil) {
        self.backing = JSONIdentitySet(filename: Self.filename, fileURL: fileURL)
    }

    /// Loads the persisted ids, or an empty set when absent/unreadable.
    func load() -> Set<String> { backing.load() }

    /// Persists `ids`. Best-effort: logs and swallows failures so a read-only
    /// disk can never break sync.
    func save(_ ids: Set<String>) { backing.save(ids) }
}

// MARK: - Sync checkpoint persistence

/// Persists the last successful PLAUD sync time to `plaud-last-sync.json`, so
/// each run only asks PLAUD for recordings newer than that (minus an overlap
/// margin) instead of paging the full history every tick. Best-effort: a
/// read-only disk degrades to "no checkpoint" (a full-history list), never a crash.
struct PlaudSyncCheckpoint {

    /// The fixed on-disk filename.
    static let filename = "plaud-last-sync.json"

    private let fileURL: URL

    /// Default location under Application Support next to the other v2 state.
    /// Pass `fileURL` (tests) to redirect it elsewhere.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? AppSupport.baseDirectory.appendingPathComponent(Self.filename, isDirectory: false)
    }

    /// The stored last-sync date, or nil when absent/unreadable (first run).
    func load() -> Date? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // Stored as a Unix-epoch seconds number for stability across coders.
        if let seconds = try? JSONDecoder().decode(Double.self, from: data) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    /// Persists `date`. Best-effort: logs and swallows failures.
    func save(_ date: Date) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(date.timeIntervalSince1970)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("PlaudSyncCheckpoint: failed to save (%@)", String(describing: error))
        }
    }
}
