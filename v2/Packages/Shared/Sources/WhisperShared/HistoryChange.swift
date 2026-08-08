import Foundation

/// Namespaces every sync-sidecar file alongside the database variant it belongs
/// to. Debug and Release already use separate SQLite files; sharing the old
/// `sync-state.bin` / `sync-pending.json` across those databases could make a
/// Debug launch consume Release pending changes (or vice versa).
public enum HistorySyncStorage {
    public static var variantSuffix: String {
        #if DEBUG
        "-dev"
        #else
        "-release"
        #endif
    }

    public static var stateFilename: String { "sync-state\(variantSuffix).bin" }
    public static var pendingFilename: String { "sync-pending\(variantSuffix).json" }
    public static var accountFilename: String { "sync-account\(variantSuffix).json" }
    public static var seedFilename: String { "sync-seed\(variantSuffix).json" }
}

/// A single local mutation of the history store, published to any observer (the
/// iCloud sync engine) so it can enqueue the matching CloudKit record change.
///
/// Sync deliberately works at the *record* granularity: even a field-level edit
/// (rename, pin, speaker name) emits an `.upsert` for the whole transcript. The
/// CloudKit record is the entire transcript, and last-writer-wins operates on
/// the whole record, so there is no value in a finer change vocabulary here — it
/// would only add surface area. The only two shapes that matter downstream are
/// "this transcript now looks like X" and "this transcript is gone".
public enum HistoryChange: Equatable, Hashable, Sendable {
    /// The transcript with this id was added or modified; the sync engine should
    /// fetch its current record and enqueue it for upload.
    case upsert(id: String)
    /// The transcript with this id was deleted; enqueue a record deletion.
    case delete(id: String)
    /// A note's title/order metadata was created or changed.
    case noteUpsert(id: String)
    /// A note was removed. Transcript changes are journaled separately.
    case noteDelete(id: String)

    /// The transcript id this change concerns (both cases carry one).
    public var id: String {
        switch self {
        case .upsert(let id), .delete(let id), .noteUpsert(let id), .noteDelete(let id):
            return id
        }
    }

    public var zoneName: String {
        switch self {
        case .upsert, .delete: TranscriptCloudRecord.zoneName
        case .noteUpsert, .noteDelete: NoteCloudRecord.zoneName
        }
    }

    public var journalKey: String { "\(zoneName)|\(id)" }
}

/// A durable journal of pending outbound changes, replayed into the sync engine
/// on start so mutations made while offline — or before the engine was even
/// constructed — are not lost.
///
/// Stored as a single JSON file under the app's base directory. The on-disk
/// shape is an ordered array of `{ op, id }` so replay preserves the order in
/// which changes happened (a delete that followed an upsert of the same id must
/// win). Saving is best-effort: a read-only disk degrades to "sync only what
/// happens from now on" rather than breaking history writes.
public struct HistoryPendingJournal: Sendable {

    private struct Entry: Codable {
        let op: String   // "upsert" | "delete"
        let id: String
        let token: String
    }

    public struct PendingItem: Equatable, Sendable {
        public let change: HistoryChange
        public let token: String
    }

    private let fileURL: URL

    /// Points at `<base>/<filename>`. Pass an explicit `fileURL` (tests) to
    /// redirect it. The filename is per-platform (the mac and iOS apps each own
    /// their sandboxed base directory) so the two journals never collide.
    public init(filename: String = HistorySyncStorage.pendingFilename, fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? AppSupport.baseDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    /// Appends a change, collapsing any earlier pending op for the same id (the
    /// latest op for an id is the only one that matters). Best-effort.
    @discardableResult
    public func append(_ change: HistoryChange) -> Bool {
        var entries = loadEntries().filter { entryChange($0).journalKey != change.journalKey }
        let token = UUID().uuidString
        switch change {
        case .upsert(let id): entries.append(Entry(op: "upsert", id: id, token: token))
        case .delete(let id): entries.append(Entry(op: "delete", id: id, token: token))
        case .noteUpsert(let id): entries.append(Entry(op: "note_upsert", id: id, token: token))
        case .noteDelete(let id): entries.append(Entry(op: "note_delete", id: id, token: token))
        }
        return save(entries)
    }

    /// Returns the pending changes in append order (oldest first).
    public func pending() -> [HistoryChange] {
        pendingItems().map(\.change)
    }

    /// Pending changes plus their mutation token. The token lets the sync engine
    /// acknowledge exactly the version it sent without clearing a newer local
    /// mutation for the same transcript id.
    public func pendingItems() -> [PendingItem] {
        loadEntries().map { entry in
            PendingItem(
                change: entryChange(entry),
                token: entry.token
            )
        }
    }

    /// Returns the current mutation for one namespaced record, if any.
    public func pendingItem(journalKey: String) -> PendingItem? {
        pendingItems().first { $0.change.journalKey == journalKey }
    }

    /// Clears one entry only if it is still the exact mutation that was sent.
    public func clear(journalKey: String, token: String) {
        save(loadEntries().filter {
            !(entryChange($0).journalKey == journalKey && $0.token == token)
        })
    }

    /// Removes the given ids from the journal (call once the engine has accepted
    /// them). Best-effort.
    public func clear(ids: [String]) {
        let drop = Set(ids)
        save(loadEntries().filter { !drop.contains($0.id) })
    }

    /// Empties the journal entirely.
    public func clearAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Storage

    private func loadEntries() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func entryChange(_ entry: Entry) -> HistoryChange {
        switch entry.op {
        case "delete": .delete(id: entry.id)
        case "note_upsert": .noteUpsert(id: entry.id)
        case "note_delete": .noteDelete(id: entry.id)
        default: .upsert(id: entry.id)
        }
    }

    @discardableResult
    private func save(_ entries: [Entry]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            NSLog("HistoryPendingJournal: failed to save (%@)", String(describing: error))
            return false
        }
    }
}

/// Durable binding between one local database variant and the iCloud private
/// database it was explicitly approved to merge with. The CloudKit user record
/// name is opaque but stable for this container and account.
public struct HistorySyncAccountBinding: Sendable {
    private struct Payload: Codable {
        let userRecordName: String
    }

    private let fileURL: URL

    public init(
        filename: String = HistorySyncStorage.accountFilename,
        fileURL: URL? = nil
    ) {
        self.fileURL = fileURL
            ?? AppSupport.baseDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    public func userRecordName() -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data).userRecordName
    }

    @discardableResult
    public func bind(to userRecordName: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Payload(userRecordName: userRecordName))
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            NSLog("HistorySyncAccountBinding: failed to persist binding (%@)", String(describing: error))
            return false
        }
    }
}

/// Records which approved iCloud account has already received a complete local
/// seed. Pending seed records stay in the durable journal until CloudKit reports
/// them successfully sent, so a crash cannot silently lose the initial upload.
public struct HistorySyncSeedLedger: Sendable {
    private struct Payload: Codable {
        var seededUserRecordNames: Set<String>
    }

    private let fileURL: URL

    public init(
        filename: String = HistorySyncStorage.seedFilename,
        fileURL: URL? = nil
    ) {
        self.fileURL = fileURL
            ?? AppSupport.baseDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    public func contains(_ userRecordName: String) -> Bool {
        load().seededUserRecordNames.contains(userRecordName)
    }

    @discardableResult
    public func markSeeded(_ userRecordName: String) -> Bool {
        var payload = load()
        payload.seededUserRecordNames.insert(userRecordName)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            NSLog("HistorySyncSeedLedger: failed to persist seed marker (%@)", String(describing: error))
            return false
        }
    }

    private func load() -> Payload {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return Payload(seededUserRecordNames: [])
        }
        return payload
    }
}
