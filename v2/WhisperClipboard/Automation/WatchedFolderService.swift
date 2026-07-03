import Core
import Foundation

/// Watches one or more folders and auto-transcribes newly-arrived audio/video
/// files by handing them to the existing ``FileImportService``.
///
/// ## Strategy
/// A periodic **timer scan** (every ``scanInterval`` seconds) rather than
/// FSEvents: simpler, robust across atomic moves and network volumes, and it
/// gives us the two-scan size-stability check for free (a file mid-copy is
/// skipped until its size stops changing). The new/stable/unprocessed decision
/// is delegated to the pure ``Core/WatchedFolderLogic`` so it is unit-tested
/// without the filesystem.
///
/// ## De-duplication across restarts
/// Every enqueued file's identity (path + mtime + size) is persisted to a small
/// `watched-processed.json`, so relaunching the app never reprocesses files that
/// are still sitting in a watched folder.
///
/// ## Busy-guard
/// The service respects the same one-job-at-a-time guard as manual import: it
/// only enqueues while the importer is idle (checked via the injected
/// `importer`), so a watched folder can't stampede the pipeline or fight a live
/// dictation. Files that aren't enqueued this tick are simply re-evaluated next
/// tick (they stay "new & stable" until actually processed).
@MainActor
final class WatchedFolderService {

    /// How often the watched folders are re-scanned.
    static let scanInterval: TimeInterval = 10

    private let foldersProvider: () -> [String]
    private let importer: (_ urls: [URL]) -> Void
    /// True when the importer (or dictation) is busy and we should hold off
    /// enqueuing this tick.
    private let isBusy: () -> Bool
    private let store: WatchedProcessedStore

    /// The previous scan per folder, keyed by folder path — needed for the
    /// size-stability check. In-memory only (a partial-copy check is meaningless
    /// across a relaunch; the processed-set handles restart de-duplication).
    private var previousScans: [String: [WatchedFolderLogic.ScannedFile]] = [:]

    /// Identities already handed to the importer (loaded from disk at init).
    private var processed: Set<String>

    private var timer: Timer?

    init(
        foldersProvider: @escaping () -> [String],
        importer: @escaping (_ urls: [URL]) -> Void,
        isBusy: @escaping () -> Bool,
        store: WatchedProcessedStore = WatchedProcessedStore()
    ) {
        self.foldersProvider = foldersProvider
        self.importer = importer
        self.isBusy = isBusy
        self.store = store
        self.processed = store.load()
    }

    // MARK: - Lifecycle

    /// Starts periodic watching. Safe to call when no folders are configured —
    /// each tick simply finds nothing. Idempotent (a second call is ignored while
    /// already running).
    func start() {
        guard timer == nil else { return }
        // An immediate first scan seeds `previousScans` so files already present
        // at launch become eligible on the *next* tick once confirmed stable.
        scanTick()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanTick() }
        }
        // Keep firing while menus/panels track the run loop.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops watching (used on teardown; not required for app quit).
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-reads the folder list immediately (e.g. right after the user adds a
    /// folder in Settings) so watching starts without waiting for the next tick.
    func refresh() {
        scanTick()
    }

    // MARK: - Scan

    private func scanTick() {
        let folders = foldersProvider()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Forget previous scans for folders no longer watched (frees memory and
        // prevents a removed-then-readded folder from using stale state).
        let watchedSet = Set(folders)
        previousScans = previousScans.filter { watchedSet.contains($0.key) }

        guard !folders.isEmpty else { return }

        var currentAll: [WatchedFolderLogic.ScannedFile] = []
        for folder in folders {
            let current = Self.scanDirectory(folder)
            let previous = previousScans[folder] ?? []
            let ready = WatchedFolderLogic.filesToEnqueue(
                currentScan: current,
                previousScan: previous,
                processed: processed
            )
            currentAll.append(contentsOf: ready)
            previousScans[folder] = current
        }

        guard !currentAll.isEmpty else { return }

        // Respect the busy-guard: if the importer/dictation is busy, leave the
        // files for a later tick (they remain new & stable & unprocessed).
        guard !isBusy() else { return }

        // Mark processed BEFORE enqueuing so an in-flight rescan (or a rapid
        // second tick) can't double-enqueue the same file.
        for file in currentAll { processed.insert(file.identity) }
        store.save(processed)

        importer(currentAll.map { URL(fileURLWithPath: $0.path) })
    }

    /// Scans one directory (non-recursive) for supported media files, returning a
    /// ``Core/WatchedFolderLogic/ScannedFile`` per file with its size + mtime.
    /// Unreadable folders / files are silently skipped. `nonisolated` so it can
    /// run off the main actor if ever needed and to keep it pure-ish.
    nonisolated static func scanDirectory(_ path: String) -> [WatchedFolderLogic.ScannedFile] {
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: path, isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        var files: [WatchedFolderLogic.ScannedFile] = []
        for url in entries {
            guard SupportedMedia.isSupported(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            // Skip directories that merely have a media-like extension.
            if values?.isRegularFile == false { continue }
            let size = Int64(values?.fileSize ?? 0)
            let mtime = Int64(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            files.append(WatchedFolderLogic.ScannedFile(path: url.path, size: size, modifiedAt: mtime))
        }
        // Deterministic order (by path) so behavior is stable and testable.
        return files.sorted { $0.path < $1.path }
    }
}

// MARK: - Processed-set persistence

/// Persists the set of already-transcribed watched-file identities to
/// `watched-processed.json`, so restarts don't reprocess files still present in
/// a watched folder. A thin wrapper over the shared ``JSONIdentitySet`` (same
/// on-disk format: a sorted `[String]`).
struct WatchedProcessedStore {

    /// The fixed on-disk filename (unchanged, so existing state loads).
    static let filename = "watched-processed.json"

    private let backing: JSONIdentitySet

    /// Default location under Application Support next to the other v2 state.
    /// Pass `fileURL` (tests) to redirect it elsewhere.
    init(fileURL: URL? = nil) {
        self.backing = JSONIdentitySet(filename: Self.filename, fileURL: fileURL)
    }

    /// Loads the persisted identities, or an empty set when absent/unreadable.
    func load() -> Set<String> { backing.load() }

    /// Persists `identities`. Best-effort: logs and swallows failures so a
    /// read-only disk can never break watching.
    func save(_ identities: Set<String>) { backing.save(identities) }
}
