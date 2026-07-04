import Foundation

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

    /// The transcript id this change concerns (both cases carry one).
    public var id: String {
        switch self {
        case .upsert(let id), .delete(let id):
            return id
        }
    }
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
    }

    private let fileURL: URL

    /// Points at `<base>/<filename>`. Pass an explicit `fileURL` (tests) to
    /// redirect it. The filename is per-platform (the mac and iOS apps each own
    /// their sandboxed base directory) so the two journals never collide.
    public init(filename: String = "sync-pending.json", fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? AppSupport.baseDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    /// Appends a change, collapsing any earlier pending op for the same id (the
    /// latest op for an id is the only one that matters). Best-effort.
    public func append(_ change: HistoryChange) {
        var entries = loadEntries().filter { $0.id != change.id }
        switch change {
        case .upsert(let id): entries.append(Entry(op: "upsert", id: id))
        case .delete(let id): entries.append(Entry(op: "delete", id: id))
        }
        save(entries)
    }

    /// Returns the pending changes in append order (oldest first).
    public func pending() -> [HistoryChange] {
        loadEntries().map { entry in
            entry.op == "delete" ? .delete(id: entry.id) : .upsert(id: entry.id)
        }
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

    private func save(_ entries: [Entry]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("HistoryPendingJournal: failed to save (%@)", String(describing: error))
        }
    }
}
