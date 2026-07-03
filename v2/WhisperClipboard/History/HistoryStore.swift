import Core
import Foundation
import GRDB
import Observation

/// The mic/file filter applied to history queries.
enum HistoryFilter: String, CaseIterable, Sendable {
    case all
    case mic
    case file
}

/// @MainActor store wrapping a GRDB `DatabaseQueue` at
/// `~/Library/Application Support/Whisper Clipboard v2/history.db`.
///
/// Owns CRUD, FTS5-backed search, retention pruning (porting the Python
/// `_trim` semantics: pinned entries are never pruned), and the one-time
/// migration of the old v3 `history.json`.
@MainActor
final class HistoryStore: ObservableObject {

    /// Bumped after every mutation so SwiftUI views observing the store refetch.
    @Published private(set) var revision = 0

    private let dbQueue: DatabaseQueue
    private let retentionProvider: () -> Int?

    private static let migratedFlagKey = "migratedFromV3"

    // MARK: - Init

    /// Live initializer: opens/creates the DB on disk and runs schema migrations.
    /// - Parameter retentionProvider: yields the current `AppSettings.historyRetention`
    ///   (`nil` = unlimited). Read lazily so live settings changes are honored.
    init(retentionProvider: @escaping () -> Int?) throws {
        let url = try Self.databaseURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.dbQueue = try DatabaseQueue(path: url.path)
        self.retentionProvider = retentionProvider
        try HistorySchema.migrator().migrate(dbQueue)
    }

    /// Test / in-memory initializer against a caller-provided queue.
    init(dbQueue: DatabaseQueue, retentionProvider: @escaping () -> Int?) throws {
        self.dbQueue = dbQueue
        self.retentionProvider = retentionProvider
        try HistorySchema.migrator().migrate(dbQueue)
    }

    /// The on-disk location of the v2 history database.
    static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("Whisper Clipboard v2", isDirectory: true)
            .appendingPathComponent("history.db", isDirectory: false)
    }

    // MARK: - Mutations

    /// Inserts (or replaces) an entry, then prunes to the retention limit.
    func add(_ entry: TranscriptEntry) throws {
        try dbQueue.write { db in
            try TranscriptRecord(entry: entry).insert(db)
            try Self.prune(db, retention: self.retentionProvider())
        }
        bump()
    }

    func delete(id: String) throws {
        _ = try dbQueue.write { db in
            try TranscriptRecord.deleteOne(db, key: id)
        }
        bump()
    }

    func rename(id: String, name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try dbQueue.write { db in
            if var record = try TranscriptRecord.fetchOne(db, key: id) {
                record.name = clean
                try record.update(db)
            }
        }
        bump()
    }

    func setPinned(id: String, _ pinned: Bool) throws {
        try dbQueue.write { db in
            if var record = try TranscriptRecord.fetchOne(db, key: id), record.pinned != pinned {
                record.pinned = pinned
                try record.update(db)
                // Unpinning may push the entry over the retention limit.
                try Self.prune(db, retention: self.retentionProvider())
            }
        }
        bump()
    }

    /// Overwrites the transcript's plain `text` (inline editing) and **clears the
    /// word-level `segments`**.
    ///
    /// Edited-text policy (see `TranscriptDetailView`): once the user hand-edits
    /// the body, the original word-level timing no longer lines up with the new
    /// text, so we drop the segments and treat the edited `text` as the single
    /// source of truth for display, copy, and export. Timecodes and speaker
    /// grouping therefore disappear for a manually-edited entry — a deliberate,
    /// simple, robust choice over trying to keep stale timings in sync. (Trimming,
    /// which *does* keep text and segments consistent, goes through
    /// ``updateSegments(id:segments:)`` instead and preserves timing.)
    ///
    /// The FTS index updates automatically via the sync triggers.
    func updateText(id: String, text: String) throws {
        try dbQueue.write { db in
            if var record = try TranscriptRecord.fetchOne(db, key: id) {
                record.text = text
                record.segments = "[]"
                try record.update(db)
            }
        }
        bump()
    }

    /// Replaces the transcript's word-level `segments` and rebuilds `text` from
    /// them (transcript trimming). Passing the kept words after deleting a
    /// sentence/turn persists both the shortened segment list and the matching
    /// body text. The rebuilt text is speaker-aware (grouped turns) when the kept
    /// segments carry speakers, matching the export format.
    func updateSegments(id: String, segments: [TranscriptSegment]) throws {
        try dbQueue.write { db in
            if var record = try TranscriptRecord.fetchOne(db, key: id) {
                let rebuilt = Self.rebuildText(from: segments)
                var rebuiltEntry = record.entry
                rebuiltEntry.segments = segments
                rebuiltEntry.text = rebuilt
                // Re-derive the record so segments JSON + text + FTS stay in sync,
                // preserving the existing speaker-name map and pinned/sort fields.
                var updated = TranscriptRecord(entry: rebuiltEntry)
                updated.pinned = record.pinned
                updated.speakerNames = record.speakerNames
                try updated.update(db)
            }
        }
        bump()
    }

    /// Sets (or clears) the display name for one raw speaker label in a
    /// transcript's rename map. An empty/blank `name` removes the mapping so the
    /// raw label ("Spreker 1") shows again.
    func setSpeakerName(transcriptId: String, rawSpeaker: String, name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try dbQueue.write { db in
            if var record = try TranscriptRecord.fetchOne(db, key: transcriptId) {
                var map = record.entry.speakerNames
                if clean.isEmpty {
                    map.removeValue(forKey: rawSpeaker)
                } else {
                    map[rawSpeaker] = clean
                }
                if let data = try? JSONEncoder().encode(map),
                   let json = String(data: data, encoding: .utf8) {
                    record.speakerNames = json
                } else {
                    record.speakerNames = "{}"
                }
                try record.update(db)
            }
        }
        bump()
    }

    /// Rebuilds a transcript's plain `text` from (possibly trimmed) segments by
    /// joining the word texts with single spaces — matching how the `text` field
    /// is originally produced (a plain transcript, no speaker labels). Speaker
    /// labels are intentionally NOT baked into `text`: they live on the segments,
    /// which stay the single source for grouped display and speaker-aware export
    /// (`Exporter.toText`), so copy/body text stays plain and consistent whether
    /// or not the entry was trimmed. Empty segments → empty string.
    static func rebuildText(from segments: [TranscriptSegment]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Removes every entry (used by "wis geschiedenis" flows).
    func deleteAll() throws {
        _ = try dbQueue.write { db in
            try TranscriptRecord.deleteAll(db)
        }
        bump()
    }

    // MARK: - AI results (M4)

    /// Persisted AI-mode results for a transcript, newest first.
    func aiResults(forTranscript transcriptId: String) throws -> [AIResult] {
        try dbQueue.read { db in
            let records = try AIResultRecord
                .filter(Column("transcript_id") == transcriptId)
                .order(Column("created_at").desc)
                .fetchAll(db)
            return records.map(\.result)
        }
    }

    /// Inserts (or replaces) an AI result. Multiple results per transcript are
    /// allowed (a rerun appends a new row).
    func addAIResult(_ result: AIResult) throws {
        try dbQueue.write { db in
            try AIResultRecord(result: result).insert(db)
        }
        bump()
    }

    /// Deletes a single AI result by id.
    func deleteAIResult(id: String) throws {
        _ = try dbQueue.write { db in
            try AIResultRecord.deleteOne(db, key: id)
        }
        bump()
    }

    // MARK: - Queries

    /// Fetches entries newest-first, optionally full-text filtered and/or scoped
    /// to a source, with paging.
    /// - Parameters:
    ///   - query: FTS5 search text; `nil`/empty returns all. Matched as prefix.
    ///   - filter: `.all`, `.mic`, or `.file`.
    func entries(
        query: String? = nil,
        filter: HistoryFilter = .all,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [TranscriptEntry] {
        try dbQueue.read { db in
            let records = try Self.fetchRecords(
                db,
                query: query,
                filter: filter,
                limit: limit,
                offset: offset
            )
            return records.map(\.entry)
        }
    }

    /// Total number of entries matching the query/filter (ignores paging).
    func count(query: String? = nil, filter: HistoryFilter = .all) throws -> Int {
        try dbQueue.read { db in
            try Self.fetchCount(db, query: query, filter: filter)
        }
    }

    /// Convenience: the most-recent `n` entries (for the Home "recent" list and
    /// the menu-bar recents), newest first.
    func recent(_ n: Int) throws -> [TranscriptEntry] {
        try entries(query: nil, filter: .all, limit: n, offset: 0)
    }

    // MARK: - Migration

    /// Runs the one-time v3 → v2 migration if the old `history.json` exists and
    /// the migration flag is not yet set. Reads the JSON only (never writes it).
    /// Returns the number of entries imported (0 when skipped).
    @discardableResult
    func migrateFromV3IfNeeded(
        legacyURL: URL = HistoryStore.legacyHistoryURL(),
        defaults: UserDefaults = .standard
    ) -> Int {
        guard !defaults.bool(forKey: Self.migratedFlagKey) else { return 0 }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            // No legacy file at all: mark done so we never re-check.
            defaults.set(true, forKey: Self.migratedFlagKey)
            return 0
        }

        do {
            let result = try HistoryV3Migrator.migrate(contentsOf: legacyURL)
            try dbQueue.write { db in
                for entry in result.entries {
                    // Only insert entries the DB doesn't already have.
                    if try TranscriptRecord.fetchOne(db, key: entry.id) == nil {
                        try TranscriptRecord(entry: entry).insert(db)
                    }
                }
                try Self.prune(db, retention: self.retentionProvider())
            }
            defaults.set(true, forKey: Self.migratedFlagKey)
            bump()
            NSLog(
                "HistoryStore: migrated %d transcripts from v3 (skipped %d malformed).",
                result.entries.count, result.skippedCount
            )
            return result.entries.count
        } catch {
            NSLog("HistoryStore: v3 migration failed: %@", String(describing: error))
            // Leave the flag unset so a fixed file can be retried next launch.
            return 0
        }
    }

    /// The old Python app's v3 history file (READ-ONLY source for migration).
    static func legacyHistoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Whisper Clipboard", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }

    // MARK: - Internals

    private func bump() { revision &+= 1 }

    /// Ports Python `_trim`: walking newest-first, keep every pinned entry and
    /// up to `limit` unpinned entries; delete the rest. `nil` = unlimited.
    private static func prune(_ db: Database, retention: Int?) throws {
        // `nil` = unlimited. `<= 0` is also treated as "disabled/unlimited": a
        // literal 0 would otherwise delete every unpinned entry (including a
        // transcript the user just recorded), which is never the intent.
        guard let limit = retention, limit > 0 else { return }
        // Ordered newest-first (pinned status does not affect ordering here;
        // it only exempts rows from the unpinned budget).
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, pinned FROM transcripts ORDER BY sort_key DESC, created_at DESC"
        )
        var unpinnedKept = 0
        var toDelete: [String] = []
        for row in rows {
            let id: String = row["id"]
            let pinned: Bool = row["pinned"]
            if pinned {
                continue
            } else if unpinnedKept < limit {
                unpinnedKept += 1
            } else {
                toDelete.append(id)
            }
        }
        if !toDelete.isEmpty {
            try TranscriptRecord.deleteAll(db, keys: toDelete)
        }
    }

    private static func fetchRecords(
        _ db: Database,
        query: String?,
        filter: HistoryFilter,
        limit: Int?,
        offset: Int
    ) throws -> [TranscriptRecord] {
        var sql: String
        var arguments = StatementArguments()
        let (whereClause, whereArgs) = buildWhere(query: query, filter: filter)

        if query.flatMap(ftsPattern) != nil {
            sql = """
            SELECT t.* FROM transcripts t
            JOIN transcripts_fts fts ON fts.rowid = t.rowid
            \(whereClause)
            ORDER BY t.sort_key DESC, t.created_at DESC
            """
        } else {
            sql = """
            SELECT t.* FROM transcripts t
            \(whereClause)
            ORDER BY t.sort_key DESC, t.created_at DESC
            """
        }
        _ = arguments.append(contentsOf: whereArgs)

        if let limit {
            sql += "\nLIMIT ? OFFSET ?"
            _ = arguments.append(contentsOf: StatementArguments([limit, offset]))
        } else if offset > 0 {
            // No explicit limit but a non-zero offset: SQLite requires a LIMIT
            // for OFFSET to apply. Use an effectively-unbounded positive limit
            // rather than the non-standard `LIMIT -1` sentinel.
            sql += "\nLIMIT ? OFFSET ?"
            _ = arguments.append(contentsOf: StatementArguments([Int.max, offset]))
        }

        return try TranscriptRecord.fetchAll(db, sql: sql, arguments: arguments)
    }

    private static func fetchCount(
        _ db: Database,
        query: String?,
        filter: HistoryFilter
    ) throws -> Int {
        let (whereClause, whereArgs) = buildWhere(query: query, filter: filter)
        let sql: String
        if query.flatMap(ftsPattern) != nil {
            sql = """
            SELECT COUNT(*) FROM transcripts t
            JOIN transcripts_fts fts ON fts.rowid = t.rowid
            \(whereClause)
            """
        } else {
            sql = "SELECT COUNT(*) FROM transcripts t \(whereClause)"
        }
        return try Int.fetchOne(db, sql: sql, arguments: whereArgs) ?? 0
    }

    /// Builds the shared WHERE clause + arguments for both fetch and count.
    private static func buildWhere(
        query: String?,
        filter: HistoryFilter
    ) -> (String, StatementArguments) {
        var conditions: [String] = []
        var args = StatementArguments()

        if let pattern = query.flatMap(ftsPattern) {
            conditions.append("transcripts_fts MATCH ?")
            _ = args.append(contentsOf: StatementArguments([pattern]))
        }
        switch filter {
        case .all:
            break
        case .mic:
            conditions.append("t.source = ?")
            _ = args.append(contentsOf: StatementArguments(["mic"]))
        case .file:
            // "Bestand" also covers live-captions sessions (both are non-mic).
            conditions.append("t.source IN (?, ?)")
            _ = args.append(contentsOf: StatementArguments(["file", "captions"]))
        }

        let clause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return (clause, args)
    }

    /// Turns free-text into a safe FTS5 prefix query: each whitespace-separated
    /// token is double-quoted (escaping embedded quotes) and suffixed with `*`
    /// for prefix matching, joined by implicit AND. Returns `nil` for
    /// empty/blank input (meaning: no FTS filter).
    static func ftsPattern(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map { token -> String in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
        guard !tokens.isEmpty else { return nil }
        return tokens.joined(separator: " ")
    }
}
