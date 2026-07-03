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
enum HistorySchema {

    /// Builds the `DatabaseMigrator` used by both the live store and tests.
    static func migrator() -> DatabaseMigrator {
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

        return migrator
    }
}
