import Core
import Foundation
import GRDB
import Observation

/// The mic/file filter applied to history queries.
public enum HistoryFilter: String, CaseIterable, Sendable {
    case all
    case mic
    case file
    case plaud
}

/// @MainActor store wrapping a GRDB `DatabaseQueue` at
/// `~/Library/Application Support/Whisper Clipboard v2/history.db`.
///
/// Owns CRUD, FTS5-backed search, retention pruning (porting the Python
/// `_trim` semantics: pinned entries are never pruned), and the one-time
/// migration of the old v3 `history.json`.
@MainActor
public final class HistoryStore: ObservableObject {

    /// Bumped after every mutation so SwiftUI views observing the store refetch.
    ///
    /// Exposed as `public var` (not `public private(set)`) on purpose: the mac
    /// AppDelegate subscribes to the Combine projected value `$revision` from
    /// another module, and `@Published`'s projected value inherits the property's
    /// *setter* access — a private setter would make `$revision` inaccessible
    /// cross-module. Mutation still only happens internally via `bump()`.
    @Published public var revision = 0

    private let dbQueue: DatabaseQueue
    private let retentionProvider: () -> Int?

    // MARK: - Sync hook (i2)

    /// Observer invoked after every local mutation, carrying the change so the
    /// iCloud sync engine can enqueue the matching CloudKit record change. `nil`
    /// when no sync engine is attached (dev builds, tests, users without iCloud):
    /// the store then behaves exactly as before.
    ///
    /// Not fired for changes applied *from* a remote fetch — see `applyingRemote`.
    public var onChange: ((HistoryChange) -> Void)?

    /// Re-entrancy guard: set while applying a fetched remote change so the
    /// outbound `onChange` hook is suppressed (a remote upsert must not bounce
    /// straight back out as a local upsert, which would loop the two devices).
    private var applyingRemote = false

    /// Emits a change to the sync observer unless we are currently applying a
    /// remote fetch.
    private func emit(_ change: HistoryChange) {
        guard !applyingRemote, let onChange else { return }
        onChange(change)
    }

    /// Whether this store is backed by the durable on-disk database. When `false`
    /// (an ephemeral in-memory fallback), the one-time v3 migration imports into
    /// RAM but must NOT persist the "migration done" flag — otherwise the durable
    /// DB on a later launch would skip the migration and lose the legacy history.
    private let isPersistent: Bool

    private static let migratedFlagKey = "migratedFromV3"

    // MARK: - Init

    /// Live initializer: opens/creates the DB on disk and runs schema migrations.
    /// - Parameter retentionProvider: yields the current `AppSettings.historyRetention`
    ///   (`nil` = unlimited). Read lazily so live settings changes are honored.
    public init(retentionProvider: @escaping () -> Int?) throws {
        let url = try Self.databaseURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.dbQueue = try DatabaseQueue(path: url.path)
        self.retentionProvider = retentionProvider
        self.isPersistent = true
        try HistorySchema.migrator().migrate(dbQueue)
    }

    /// Test / in-memory initializer against a caller-provided queue.
    ///
    /// - Parameter isPersistent: whether the queue is durable on-disk state.
    ///   Defaults to `true` so existing tests observe the migration flag being set;
    ///   `AppEnvironment` passes `false` for the throwaway in-memory fallback so a
    ///   migration into RAM never persists the "done" flag (finding: v3 history
    ///   lost after a transient disk failure).
    public init(dbQueue: DatabaseQueue, retentionProvider: @escaping () -> Int?, isPersistent: Bool = true) throws {
        self.dbQueue = dbQueue
        self.retentionProvider = retentionProvider
        self.isPersistent = isPersistent
        try HistorySchema.migrator().migrate(dbQueue)
    }

    /// The on-disk location of the v2 history database.
    ///
    /// HARDE LES (2026-07-05): DEBUG-builds en test-hosts gebruiken een EIGEN
    /// bestand (`history-dev.db`). Eerder deelden dev/test-runs het echte
    /// `history.db` van de geïnstalleerde release-app, en in combinatie met
    /// `eraseDatabaseOnSchemaChange` (DEBUG-only) is daarbij Niels' echte
    /// geschiedenis gewist. Dev/test mag NOOIT meer bij productiedata kunnen.
    public static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        #if DEBUG
        let filename = "history-dev.db"
        #else
        let filename = "history.db"
        #endif
        return base
            .appendingPathComponent("Whisper Clipboard v2", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    // MARK: - Mutations

    /// Inserts (or replaces) an entry, then prunes to the retention limit.
    public func add(_ entry: TranscriptEntry) throws {
        let prunedIDs = try dbQueue.write { db -> [String] in
            try TranscriptRecord(entry: entry).insert(db)
            return try Self.prune(db, retention: self.retentionProvider())
        }
        emit(.upsert(id: entry.id))
        // bevinding 2026-08-03: door retentie verwijderde rijen worden nu ook als
        // sync-verwijdering uitgezonden, net als in `delete(id:)`.
        for prunedID in prunedIDs { emit(.delete(id: prunedID)) }
        bump()
    }

    public func delete(id: String) throws {
        _ = try dbQueue.write { db in
            try TranscriptRecord.deleteOne(db, key: id)
        }
        emit(.delete(id: id))
        bump()
    }

    public func rename(id: String, name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false
        try dbQueue.write { db in
            if var record = try TranscriptRecord.fetchOne(db, key: id) {
                record.name = clean
                record.modifiedAt = TranscriptRecord.nowMillis()
                try record.update(db)
                changed = true
            }
        }
        if changed { emit(.upsert(id: id)) }
        bump()
    }

    public func setPinned(id: String, _ pinned: Bool) throws {
        var changed = false
        let prunedIDs = try dbQueue.write { db -> [String] in
            guard var record = try TranscriptRecord.fetchOne(db, key: id),
                  record.pinned != pinned
            else { return [] }
            record.pinned = pinned
            record.modifiedAt = TranscriptRecord.nowMillis()
            try record.update(db)
            changed = true
            // Unpinning may push the entry over the retention limit.
            return try Self.prune(db, retention: self.retentionProvider())
        }
        if changed { emit(.upsert(id: id)) }
        // bevinding 2026-08-03: ook hier de gepruunde rijen als verwijdering
        // uitzenden (het losmaken van een pin kan er rijen over de limiet duwen).
        for prunedID in prunedIDs { emit(.delete(id: prunedID)) }
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
    public func updateText(id: String, text: String) throws {
        var changed = false
        try dbQueue.write { db in
            if var record = try TranscriptRecord.fetchOne(db, key: id) {
                record.text = text
                record.segments = "[]"
                record.modifiedAt = TranscriptRecord.nowMillis()
                try record.update(db)
                changed = true
            }
        }
        if changed { emit(.upsert(id: id)) }
        bump()
    }

    /// Replaces the transcript's word-level `segments` and rebuilds `text` from
    /// them (transcript trimming). Passing the kept words after deleting a
    /// sentence/turn persists both the shortened segment list and the matching
    /// body text. The rebuilt text is speaker-aware (grouped turns) when the kept
    /// segments carry speakers, matching the export format.
    public func updateSegments(id: String, segments: [TranscriptSegment]) throws {
        var changed = false
        try dbQueue.write { db in
            if let record = try TranscriptRecord.fetchOne(db, key: id) {
                let rebuilt = Self.rebuildText(from: segments)
                var rebuiltEntry = record.entry
                rebuiltEntry.segments = segments
                rebuiltEntry.text = rebuilt
                // Re-derive the record so segments JSON + text + FTS stay in sync,
                // preserving the existing speaker-name map and pinned/sort fields.
                var updated = TranscriptRecord(entry: rebuiltEntry)
                updated.pinned = record.pinned
                updated.speakerNames = record.speakerNames
                // Behoud de notitie-koppeling bij trimmen (anders zou een getrimde
                // opname uit zijn notitie loskomen).
                updated.noteId = record.noteId
                // `TranscriptRecord(entry:)` already stamped modifiedAt = now.
                try updated.update(db)
                changed = true
            }
        }
        if changed { emit(.upsert(id: id)) }
        bump()
    }

    /// Attaches speaker labels to a transcript's segments **without** touching its
    /// display text. Unlike ``updateSegments(id:segments:)`` (which rebuilds the
    /// text from the segments, as trimming needs), this preserves the stored text
    /// verbatim — used by the post-dictation diarization pass, where the text was
    /// already post-processed (replacements/cleanup/filler removal) and must not be
    /// re-derived from the raw segment text. No-op if the id is gone (e.g. the user
    /// deleted the entry before diarization finished).
    public func updateSegmentsPreservingText(id: String, segments: [TranscriptSegment]) throws {
        var changed = false
        try dbQueue.write { db in
            if let record = try TranscriptRecord.fetchOne(db, key: id) {
                var entry = record.entry
                entry.segments = segments
                // Keep the existing text; only re-derive the record so the segments
                // JSON is refreshed. Preserve pinned/speakerNames/note fields.
                var updated = TranscriptRecord(entry: entry)
                updated.pinned = record.pinned
                updated.speakerNames = record.speakerNames
                updated.noteId = record.noteId
                try updated.update(db)
                changed = true
            }
        }
        if changed { emit(.upsert(id: id)) }
        bump()
    }

    /// Sets (or clears) the display name for one raw speaker label in a
    /// transcript's rename map. An empty/blank `name` removes the mapping so the
    /// raw label ("Spreker 1") shows again.
    public func setSpeakerName(transcriptId: String, rawSpeaker: String, name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false
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
                record.modifiedAt = TranscriptRecord.nowMillis()
                try record.update(db)
                changed = true
            }
        }
        if changed { emit(.upsert(id: transcriptId)) }
        bump()
    }

    /// Reduces an over-diarized transcript to the requested number of speakers.
    /// The speakers with the most spoken time are retained. Tiny false-positive
    /// labels are reassigned to the nearest retained speaker in time, preferring
    /// matching neighbours. Transcript text and timings remain unchanged.
    public func limitSpeakers(id: String, maximum: Int) throws {
        guard maximum >= 1 else { return }
        var changed = false
        try dbQueue.write { db in
            guard let record = try TranscriptRecord.fetchOne(db, key: id) else { return }
            var entry = record.entry
            let totals = Dictionary(grouping: entry.segments.compactMap { segment in
                segment.speaker.map { ($0, max(0, segment.end - segment.start)) }
            }, by: { $0.0 }).mapValues { $0.reduce(0) { $0 + $1.1 } }
            let retained = Set(totals.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.prefix(maximum).map(\.key))
            guard totals.count > retained.count, !retained.isEmpty else { return }

            for index in entry.segments.indices {
                guard let speaker = entry.segments[index].speaker,
                      !retained.contains(speaker) else { continue }
                let previous = entry.segments[..<index].reversed().first { segment in
                    segment.speaker.map(retained.contains) == true
                }
                let next = entry.segments[(index + 1)...].first { segment in
                    segment.speaker.map(retained.contains) == true
                }
                let replacement: String?
                if previous?.speaker == next?.speaker {
                    replacement = previous?.speaker
                } else {
                    let previousGap = previous.map { max(0, entry.segments[index].start - $0.end) } ?? .greatestFiniteMagnitude
                    let nextGap = next.map { max(0, $0.start - entry.segments[index].end) } ?? .greatestFiniteMagnitude
                    replacement = previousGap <= nextGap ? previous?.speaker : next?.speaker
                }
                entry.segments[index].speaker = replacement ?? retained.first
            }

            var updated = TranscriptRecord(entry: entry)
            updated.pinned = record.pinned
            updated.noteId = record.noteId
            let retainedNames = entry.speakerNames.filter { retained.contains($0.key) }
            updated.speakerNames = (try? String(data: JSONEncoder().encode(retainedNames), encoding: .utf8)) ?? "{}"
            try updated.update(db)
            changed = true
        }
        if changed { emit(.upsert(id: id)) }
        bump()
    }

    /// Rebuilds a transcript's plain `text` from (possibly trimmed) segments by
    /// joining the word texts with single spaces — matching how the `text` field
    /// is originally produced (a plain transcript, no speaker labels). Speaker
    /// labels are intentionally NOT baked into `text`: they live on the segments,
    /// which stay the single source for grouped display and speaker-aware export
    /// (`Exporter.toText`), so copy/body text stays plain and consistent whether
    /// or not the entry was trimmed. Empty segments → empty string.
    public static func rebuildText(from segments: [TranscriptSegment]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Removes every entry (used by "wis geschiedenis" flows).
    public func deleteAll() throws {
        // Capture the ids first so each removal can be propagated to iCloud as a
        // record deletion (a bulk `DELETE` gives us no per-row hook).
        let ids: [String] = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM transcripts")
        }
        _ = try dbQueue.write { db in
            try TranscriptRecord.deleteAll(db)
        }
        for id in ids { emit(.delete(id: id)) }
        bump()
    }

    // MARK: - Sync integration (i2)

    /// Fetches the raw persistence record for `id` (including its `modifiedAt`
    /// clock and JSON blobs), or `nil` if absent. The sync engine uses this to
    /// materialize the CloudKit record for an outbound `.upsert`.
    public func record(id: String) throws -> TranscriptRecord? {
        try dbQueue.read { db in
            try TranscriptRecord.fetchOne(db, key: id)
        }
    }

    /// Every locally-held transcript id, including entries linked to a note.
    /// Used once per approved iCloud account to seed pre-existing history.
    public func allRecordIDs() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM transcripts ORDER BY id")
        }
    }

    /// The `modifiedAt` clocks for a set of ids, keyed by id. Used by the
    /// conflict resolver to compare a locally-held row against an incoming remote
    /// record without materializing the whole entry. Missing ids are absent.
    public func modifiedAt(ids: [String]) throws -> [String: Int64] {
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, modified_at FROM transcripts WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
                arguments: StatementArguments(ids)
            )
            var out: [String: Int64] = [:]
            for row in rows { out[row["id"]] = row["modified_at"] }
            return out
        }
    }

    /// Applies a record fetched from iCloud, WITHOUT re-emitting an outbound
    /// change (the `applyingRemote` guard is held for the duration). This is the
    /// inbound half of sync: the engine has already run last-writer-wins and only
    /// calls this when the remote copy should win.
    ///
    /// The incoming `record` carries the remote `modifiedAt`, which is persisted
    /// verbatim so both devices converge on the same clock for that row.
    ///
    /// bevinding 2026-08-03: retention-pruning draait hier BEWUST niet meer. Het
    /// liep bij élke binnenkomende upsert, dus een eerste iCloud-seed kon lokale
    /// rijen massaal wissen — en zonder sync-verwijdering (de `applyingRemote`-
    /// guard onderdrukt `emit`), zodat die rijen in iCloud bleven staan en
    /// telkens terugkwamen. Het bewaarlimiet wordt weer toegepast bij de
    /// eerstvolgende lokale mutatie (`add` / `setPinned`).
    public func applyRemoteUpsert(_ record: TranscriptRecord, includesNoteLink: Bool = false) throws {
        applyingRemote = true
        defer { applyingRemote = false }
        try dbQueue.write { db in
            var record = record
            // Legacy CloudKit records did not carry a note-link marker. Preserve
            // the local link for those; current records may explicitly attach or
            // detach through their versioned `noteId` field.
            if !includesNoteLink {
                record.noteId = try TranscriptRecord.fetchOne(db, key: record.id)?.noteId
            }
            try record.save(db)
        }
        bump()
    }

    /// Removes a record deleted remotely, without re-emitting an outbound delete.
    public func applyRemoteDelete(id: String) throws {
        applyingRemote = true
        defer { applyingRemote = false }
        _ = try dbQueue.write { db in
            try TranscriptRecord.deleteOne(db, key: id)
        }
        bump()
    }

    /// Builds the `?,?,…` placeholder list for an `IN (…)` clause.
    private func databaseQuestionMarks(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    // MARK: - AI results (M4)

    /// Persisted AI-mode results for a transcript, newest first.
    public func aiResults(forTranscript transcriptId: String) throws -> [AIResult] {
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
    public func addAIResult(_ result: AIResult) throws {
        try dbQueue.write { db in
            try AIResultRecord(result: result).insert(db)
        }
        bump()
    }

    /// Deletes a single AI result by id.
    public func deleteAIResult(id: String) throws {
        _ = try dbQueue.write { db in
            try AIResultRecord.deleteOne(db, key: id)
        }
        bump()
    }

    // MARK: - Notes (i2)

    /// Alle notities, laatst-gewijzigd eerst.
    public func notes() throws -> [Note] {
        try dbQueue.read { db in
            try NoteRecord
                .order(Column("sort_key").desc)
                .fetchAll(db)
                .map(\.note)
        }
    }

    /// Eén notitie op id, of `nil` als hij niet bestaat.
    public func note(id: String) throws -> Note? {
        try dbQueue.read { db in
            try NoteRecord.fetchOne(db, key: id)?.note
        }
    }

    public func noteRecord(id: String) throws -> NoteRecord? {
        try dbQueue.read { db in try NoteRecord.fetchOne(db, key: id) }
    }

    public func allNoteRecordIDs() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM notes ORDER BY id")
        }
    }

    public func noteModifiedAt(ids: [String]) throws -> [String: Int64] {
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let records = try NoteRecord.fetchAll(
                db,
                sql: "SELECT * FROM notes WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
                arguments: StatementArguments(ids)
            )
            return Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.modifiedAtMillis) })
        }
    }

    public func applyRemoteNoteUpsert(_ record: NoteRecord) throws {
        applyingRemote = true
        defer { applyingRemote = false }
        try dbQueue.write { db in try record.save(db) }
        bump()
    }

    public func applyRemoteNoteDelete(id: String) throws {
        applyingRemote = true
        defer { applyingRemote = false }
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcripts SET note_id = NULL WHERE note_id = ?", arguments: [id])
            _ = try NoteRecord.deleteOne(db, key: id)
        }
        bump()
    }

    /// Maakt een nieuwe notitie aan met de gegeven titel en retourneert hem.
    @discardableResult
    public func createNote(title: String) throws -> Note {
        let now = ISO8601DateFormatter().string(from: Date())
        let note = Note(
            id: UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            modifiedAt: now
        )
        try dbQueue.write { db in
            try NoteRecord(note: note).insert(db)
        }
        emit(.noteUpsert(id: note.id))
        bump()
        return note
    }

    /// Maakt een nieuwe notitie en verplaatst een bestaande opname ernaartoe in
    /// één transactie. Zo kan een databasefout nooit een lege notitie achterlaten
    /// nadat het verplaatsen van de opname is mislukt.
    @discardableResult
    public func createNote(title: String, movingEntryId entryId: String) throws -> Note? {
        let now = ISO8601DateFormatter().string(from: Date())
        let note = Note(
            id: UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            modifiedAt: now
        )
        var previousNoteId: String?
        var didCreate = false

        try dbQueue.write { db in
            guard var entry = try TranscriptRecord.fetchOne(db, key: entryId) else { return }
            previousNoteId = entry.noteId
            try NoteRecord(note: note).insert(db)
            entry.noteId = note.id
            entry.modifiedAt = TranscriptRecord.nowMillis()
            try entry.update(db)

            if let previousNoteId,
               var previousNote = try NoteRecord.fetchOne(db, key: previousNoteId) {
                previousNote.modifiedAt = now
                previousNote.sortKey = Date().timeIntervalSince1970
                try previousNote.update(db)
            }
            didCreate = true
        }

        guard didCreate else { return nil }
        emit(.noteUpsert(id: note.id))
        emit(.upsert(id: entryId))
        if let previousNoteId { emit(.noteUpsert(id: previousNoteId)) }
        bump()
        return note
    }

    /// Hernoemt een notitie en werkt zijn `modifiedAt` bij.
    public func renameNote(id: String, title: String) throws {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false
        try dbQueue.write { db in
            if var record = try NoteRecord.fetchOne(db, key: id) {
                record.title = clean
                record.modifiedAt = ISO8601DateFormatter().string(from: Date())
                record.sortKey = Date().timeIntervalSince1970
                try record.update(db)
                changed = true
            }
        }
        if changed { emit(.noteUpsert(id: id)) }
        bump()
    }

    /// Verwijdert een notitie. De gekoppelde opnames worden standaard NIET
    /// weggegooid: hun `note_id` wordt op `NULL` gezet zodat ze als losse
    /// Geschiedenis-items behouden blijven. Zet `deleteEntries` op `true` om ook
    /// de opnames te verwijderen.
    public func deleteNote(id: String, deleteEntries: Bool) throws {
        var freedIds: [String] = []
        try dbQueue.write { db in
            if deleteEntries {
                // Verwijder de gekoppelde transcripts (elk apart zodat sync ze als
                // verwijdering kan doorgeven).
                freedIds = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM transcripts WHERE note_id = ?",
                    arguments: [id]
                )
                try TranscriptRecord.deleteAll(db, keys: freedIds)
            } else {
                // Ontkoppel: note_id → NULL, zodat de opnames losse Geschiedenis-
                // items worden. modified_at wordt bijgewerkt zodat een latere sync
                // (uitgesteld) de wijziging zou zien.
                freedIds = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM transcripts WHERE note_id = ?",
                    arguments: [id]
                )
                try db.execute(
                    sql: "UPDATE transcripts SET note_id = NULL, modified_at = ? WHERE note_id = ?",
                    arguments: [TranscriptRecord.nowMillis(), id]
                )
            }
            try NoteRecord.deleteOne(db, key: id)
        }
        emit(.noteDelete(id: id))
        if deleteEntries {
            for freed in freedIds { emit(.delete(id: freed)) }
        } else {
            for freed in freedIds { emit(.upsert(id: freed)) }
        }
        bump()
    }

    /// De opnames van een notitie, oudste eerst (chronologisch, zoals ze zijn
    /// toegevoegd) — dat is de leesvolgorde in de notitie-detailweergave.
    public func noteEntries(noteId: String) throws -> [TranscriptEntry] {
        try dbQueue.read { db in
            try TranscriptRecord
                .filter(Column("note_id") == noteId)
                .order(Column("sort_key").asc, Column("created_at").asc)
                .fetchAll(db)
                .map(\.entry)
        }
    }

    /// Voegt een verse opname toe áán een notitie (i.p.v. als losse
    /// Geschiedenis-entry). De opname krijgt `note_id` gezet en de notitie z'n
    /// `modifiedAt` wordt naar nu geschoven. Retention-pruning wordt bewust NIET
    /// toegepast op notitie-opnames (een notitie mag onbeperkt groeien).
    public func appendToNote(_ entry: TranscriptEntry, noteId: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbQueue.write { db in
            try TranscriptRecord(entry: entry, noteId: noteId).insert(db)
            if var noteRecord = try NoteRecord.fetchOne(db, key: noteId) {
                noteRecord.modifiedAt = now
                noteRecord.sortKey = Date().timeIntervalSince1970
                try noteRecord.update(db)
            }
        }
        emit(.upsert(id: entry.id))
        emit(.noteUpsert(id: noteId))
        bump()
    }

    /// Verplaatst een bestaande (losse) opname naar een notitie: zet `note_id` en
    /// verwijdert hem daarmee uit de losse Geschiedenis (want die filtert op
    /// `note_id IS NULL`). Werkt de `modifiedAt` van de notitie bij.
    public func moveEntryToNote(entryId: String, noteId: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        var changed = false
        var previousNoteId: String?
        try dbQueue.write { db in
            if var record = try TranscriptRecord.fetchOne(db, key: entryId) {
                previousNoteId = record.noteId
                record.noteId = noteId
                record.modifiedAt = TranscriptRecord.nowMillis()
                try record.update(db)
                changed = true
                if var noteRecord = try NoteRecord.fetchOne(db, key: noteId) {
                    noteRecord.modifiedAt = now
                    noteRecord.sortKey = Date().timeIntervalSince1970
                    try noteRecord.update(db)
                }
                if let previousNoteId, previousNoteId != noteId,
                   var oldNote = try NoteRecord.fetchOne(db, key: previousNoteId) {
                    oldNote.modifiedAt = now
                    oldNote.sortKey = Date().timeIntervalSince1970
                    try oldNote.update(db)
                }
            }
        }
        if changed {
            emit(.upsert(id: entryId))
            emit(.noteUpsert(id: noteId))
            if let previousNoteId, previousNoteId != noteId {
                emit(.noteUpsert(id: previousNoteId))
            }
        }
        bump()
    }

    /// Verhuist alle opnames van `sourceNoteId` naar `targetNoteId` en verwijdert
    /// de daarna lege bronnotitie in één database-transactie. Bij iedere fout
    /// wordt de volledige wijziging teruggedraaid, zodat een samenvoeging nooit
    /// half uitgevoerd eindigt of resterende opnames als losse historie achterlaat.
    public func mergeNote(sourceNoteId: String, into targetNoteId: String) throws {
        guard sourceNoteId != targetNoteId else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let modifiedAt = TranscriptRecord.nowMillis()
        var movedIds: [String] = []
        var didMerge = false

        try dbQueue.write { db in
            guard try NoteRecord.fetchOne(db, key: sourceNoteId) != nil,
                  var target = try NoteRecord.fetchOne(db, key: targetNoteId)
            else { return }

            movedIds = try String.fetchAll(
                db,
                sql: "SELECT id FROM transcripts WHERE note_id = ? ORDER BY sort_key, created_at",
                arguments: [sourceNoteId]
            )
            try db.execute(
                sql: "UPDATE transcripts SET note_id = ?, modified_at = ? WHERE note_id = ?",
                arguments: [targetNoteId, modifiedAt, sourceNoteId]
            )
            target.modifiedAt = now
            target.sortKey = Date().timeIntervalSince1970
            try target.update(db)
            try NoteRecord.deleteOne(db, key: sourceNoteId)
            didMerge = true
        }

        guard didMerge else { return }
        for id in movedIds { emit(.upsert(id: id)) }
        emit(.noteUpsert(id: targetNoteId))
        emit(.noteDelete(id: sourceNoteId))
        bump()
    }

    /// Maakt een notitie-opname weer los: zet `note_id` op NULL zodat hij terug in
    /// de losse Geschiedenis verschijnt (die filtert op `note_id IS NULL`). Spiegelt
    /// ``moveEntryToNote`` — bumpt `modifiedAt` en zendt een upsert uit voor sync.
    public func detachEntryFromNote(entryId: String) throws {
        var changed = false
        var previousNoteId: String?
        let now = ISO8601DateFormatter().string(from: Date())
        try dbQueue.write { db in
            if var record = try TranscriptRecord.fetchOne(db, key: entryId) {
                previousNoteId = record.noteId
                record.noteId = nil
                record.modifiedAt = TranscriptRecord.nowMillis()
                try record.update(db)
                changed = true
                if let previousNoteId,
                   var noteRecord = try NoteRecord.fetchOne(db, key: previousNoteId) {
                    noteRecord.modifiedAt = now
                    noteRecord.sortKey = Date().timeIntervalSince1970
                    try noteRecord.update(db)
                }
            }
        }
        if changed {
            emit(.upsert(id: entryId))
            if let previousNoteId { emit(.noteUpsert(id: previousNoteId)) }
        }
        bump()
    }

    // MARK: - Queries

    /// Fetches entries newest-first, optionally full-text filtered and/or scoped
    /// to a source, with paging.
    /// - Parameters:
    ///   - query: FTS5 search text; `nil`/empty returns all. Matched as prefix.
    ///   - filter: `.all`, `.mic`, or `.file`.
    public func entries(
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
    /// Note-linked entries (`note_id` set) are excluded, matching `entries(…)`.
    public func count(query: String? = nil, filter: HistoryFilter = .all) throws -> Int {
        try dbQueue.read { db in
            try Self.fetchCount(db, query: query, filter: filter)
        }
    }

    /// Convenience: the most-recent `n` entries (for the Home "recent" list and
    /// the menu-bar recents), newest first.
    public func recent(_ n: Int) throws -> [TranscriptEntry] {
        try entries(query: nil, filter: .all, limit: n, offset: 0)
    }

    // MARK: - Migration

    /// Runs the one-time v3 → v2 migration if the old `history.json` exists and
    /// the migration flag is not yet set. Reads the JSON only (never writes it).
    /// Returns the number of entries imported (0 when skipped).
    @discardableResult
    public func migrateFromV3IfNeeded(
        legacyURL: URL = HistoryStore.legacyHistoryURL(),
        defaults: UserDefaults = .standard
    ) -> Int {
        guard !defaults.bool(forKey: Self.migratedFlagKey) else { return 0 }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            // No legacy file at all: mark done so we never re-check — but only when
            // this is the durable on-disk store (an in-memory fallback must not
            // persist "done" and cause a later real DB to skip the migration).
            if isPersistent {
                defaults.set(true, forKey: Self.migratedFlagKey)
            }
            return 0
        }

        do {
            let result = try HistoryV3Migrator.migrate(contentsOf: legacyURL)
            let prunedIDs = try dbQueue.write { db -> [String] in
                for entry in result.entries {
                    // Only insert entries the DB doesn't already have.
                    if try TranscriptRecord.fetchOne(db, key: entry.id) == nil {
                        try TranscriptRecord(entry: entry).insert(db)
                    }
                }
                return try Self.prune(db, retention: self.retentionProvider())
            }
            // bevinding 2026-08-03: pruning verwijdert hier ook rijen die al in
            // iCloud stonden (de migratie slaat bestaande ids over maar pruunt de
            // hele losse geschiedenis), dus die verwijderingen moeten worden
            // uitgezonden.
            for prunedID in prunedIDs { emit(.delete(id: prunedID)) }
            // Persist the "migration done" flag only when the import actually
            // landed in the durable on-disk DB. An in-memory fallback still returns
            // the imported count (so this session has usable data) but leaves the
            // flag unset, so a later launch with a working disk DB retries.
            if isPersistent {
                defaults.set(true, forKey: Self.migratedFlagKey)
            }
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
    public static func legacyHistoryURL() -> URL {
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
    ///
    /// Geeft de verwijderde ids terug. bevinding 2026-08-03: pruning wiste rijen
    /// zonder `emit(.delete(id:))`, waardoor ze in iCloud bleven staan, opnieuw
    /// werden opgehaald en meteen weer werden gepruund — een eindeloze lus. Elke
    /// aanroeper moet de teruggegeven ids ná de transactie als verwijdering
    /// uitzenden, precies zoals `delete(id:)` doet.
    private static func prune(_ db: Database, retention: Int?) throws -> [String] {
        // `nil` = unlimited. `<= 0` is also treated as "disabled/unlimited": a
        // literal 0 would otherwise delete every unpinned entry (including a
        // transcript the user just recorded), which is never the intent.
        guard let limit = retention, limit > 0 else { return [] }
        // Ordered newest-first (pinned status does not affect ordering here;
        // it only exempts rows from the unpinned budget).
        // Notitie-opnames (note_id gezet) tellen niet mee voor het bewaarlimiet —
        // een notitie mag onbeperkt groeien (zie `appendToNote`).
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, pinned FROM transcripts WHERE note_id IS NULL ORDER BY sort_key DESC, created_at DESC"
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
        return toDelete
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

        // Notitie-gekoppelde opnames (note_id gezet) horen thuis in hun notitie en
        // verschijnen NIET los in de Geschiedenis. `note_id IS NULL` = ongewijzigd
        // gedrag voor alle bestaande (en losse) entries.
        conditions.append("t.note_id IS NULL")

        if let pattern = query.flatMap(ftsPattern) {
            conditions.append("transcripts_fts MATCH ?")
            _ = args.append(contentsOf: StatementArguments([pattern]))
        }
        switch filter {
        case .all:
            break
        case .mic:
            conditions.append("(t.source = ? OR t.source LIKE ?)")
            _ = args.append(contentsOf: StatementArguments(["mic", "mic.%"]))
        case .file:
            // "Bestand" also covers live-captions sessions (both are non-mic).
            conditions.append("(t.source IN (?, ?) OR t.source LIKE ? OR t.source LIKE ?)")
            _ = args.append(contentsOf: StatementArguments(["file", "captions", "file.%", "captions.%"]))
        case .plaud:
            conditions.append("(t.source = ? OR t.source LIKE ?)")
            _ = args.append(contentsOf: StatementArguments(["plaud", "plaud.%"]))
        }

        let clause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return (clause, args)
    }

    /// Turns free-text into a safe FTS5 prefix query: each whitespace-separated
    /// token is double-quoted (escaping embedded quotes) and suffixed with `*`
    /// for prefix matching, joined by implicit AND. Returns `nil` for
    /// empty/blank input (meaning: no FTS filter).
    public static func ftsPattern(from raw: String) -> String? {
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
