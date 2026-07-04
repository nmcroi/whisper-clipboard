import Foundation
import GRDB

/// Defines the GRDB migration set for the v2 history database.
///
/// Tables:
///  - `transcripts` — one row per saved transcription, mirroring
///    `Core.TranscriptEntry` (segments stored as a JSON TEXT blob).
///  - `transcripts_fts` — an FTS5 external-content index over `text` + `name`,
///    kept in sync with `transcripts` via triggers.
///  - `ai_results` — reserved for M4 AI post-processing output.
public enum HistorySchema {

    /// Builds the `DatabaseMigrator` used by both the live store and tests.
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // During development we allow schema erasure on incompatible changes.
        // (Safe: the history DB is derived; the v1 JSON remains the source of truth.)
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_transcripts") { db in
            try db.create(table: "transcripts") { t in
                t.column("id", .text).primaryKey()
                t.column("text", .text).notNull()
                // Raw ISO-8601 string, byte-for-byte as produced by the source
                // (see Core.TranscriptEntry.createdAt).
                t.column("created_at", .text).notNull()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("language", .text).notNull().defaults(to: "")
                t.column("model", .text).notNull().defaults(to: "")
                t.column("source", .text).notNull().defaults(to: "mic")
                t.column("duration", .double).notNull().defaults(to: 0)
                // JSON-encoded [TranscriptSegment].
                t.column("segments", .text).notNull().defaults(to: "[]")
                // Sortable epoch seconds derived from created_at at insert time,
                // so "newest first" ordering is a fast indexed integer compare.
                t.column("sort_key", .double).notNull().defaults(to: 0)
            }
            try db.create(
                index: "idx_transcripts_sort",
                on: "transcripts",
                columns: ["sort_key"]
            )
            try db.create(
                index: "idx_transcripts_source",
                on: "transcripts",
                columns: ["source"]
            )
        }

        migrator.registerMigration("v2_fts") { db in
            // External-content FTS5 over text + name. `content=` points the index
            // at the transcripts table; `content_rowid` uses its rowid.
            try db.create(virtualTable: "transcripts_fts", using: FTS5()) { t in
                t.synchronize(withTable: "transcripts")
                t.column("text")
                t.column("name")
                t.tokenizer = .unicode61()
            }
        }

        migrator.registerMigration("v3_ai_results") { db in
            try db.create(table: "ai_results") { t in
                t.column("id", .text).primaryKey()
                t.column("transcript_id", .text)
                    .notNull()
                    .references("transcripts", onDelete: .cascade)
                t.column("mode_id", .text).notNull()
                t.column("mode_name", .text).notNull()
                t.column("output", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_ai_results_transcript",
                on: "ai_results",
                columns: ["transcript_id"]
            )
        }

        migrator.registerMigration("v4_speaker_names") { db in
            // Per-transcript speaker rename map, JSON-encoded [String: String]
            // (raw diarization label → user-chosen display name). Defaults to an
            // empty object so existing rows need no backfill.
            try db.alter(table: "transcripts") { t in
                t.add(column: "speaker_names", .text).notNull().defaults(to: "{}")
            }
        }

        migrator.registerMigration("v5_modified_at") { db in
            // Last-writer-wins clock for iCloud sync (i2). Milliseconds since the
            // 1970 epoch, updated on every local mutation. Existing rows are
            // backfilled from their created_at (sort_key epoch seconds → ms) so an
            // already-populated history gets sensible, ordered timestamps rather
            // than all collapsing to a single migration instant — this keeps the
            // conflict resolver deterministic on the very first sync.
            try db.alter(table: "transcripts") { t in
                t.add(column: "modified_at", .integer).notNull().defaults(to: 0)
            }
            // Backfill: sort_key holds epoch SECONDS derived from created_at.
            try db.execute(sql: """
                UPDATE transcripts
                SET modified_at = CAST(sort_key * 1000 AS INTEGER)
                WHERE sort_key > 0
            """)
        }

        migrator.registerMigration("v6_notes") { db in
            // Notities (iPhone i2): een doorlopende, benoemde notitie waaraan je
            // over uren/dagen kunt blijven toevoegen. Additief en veilig:
            //  1. Een nieuwe `notes`-tabel (id/titel/aangemaakt/gewijzigd).
            //  2. Een NULL-bare `note_id`-kolom op `transcripts`. Een transcript
            //     met `note_id = NULL` gedraagt zich exact als vandaag (los in de
            //     Geschiedenis). Met een `note_id` hoort het bij die notitie en
            //     wordt het daar samengevoegd i.p.v. los te verschijnen.
            // Bestaande rijen krijgen automatisch `note_id = NULL` (geen backfill
            // nodig), dus lokale databases van bestaande gebruikers blijven intact.
            //
            // iCloud-sync van notities/`note_id` is BEWUST uitgesteld (net als de
            // AIResult-sync), zie TranscriptCloudRecord — de `Transcript`-CKRecord
            // stuurt `note_id` niet mee en er is (nog) geen `Note`-recordtype.
            try db.create(table: "notes") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull().defaults(to: "")
                // Raw ISO-8601 strings, consistent met transcripts.created_at.
                t.column("created_at", .text).notNull()
                t.column("modified_at", .text).notNull()
                // Sorteersleutel (epoch-seconden van modified_at) voor snelle
                // "laatst gewijzigd eerst"-ordening.
                t.column("sort_key", .double).notNull().defaults(to: 0)
            }
            try db.create(
                index: "idx_notes_sort",
                on: "notes",
                columns: ["sort_key"]
            )
            try db.alter(table: "transcripts") { t in
                // NULL = losse Geschiedenis-entry (ongewijzigd gedrag). Niet-NULL
                // = hoort bij die notitie. Geen FK-constraint: bij het verwijderen
                // van een notitie zetten we `note_id` expliciet terug op NULL zodat
                // de entries als losse Geschiedenis-items behouden blijven.
                t.add(column: "note_id", .text)
            }
            try db.create(
                index: "idx_transcripts_note",
                on: "transcripts",
                columns: ["note_id"]
            )
        }

        return migrator
    }
}
