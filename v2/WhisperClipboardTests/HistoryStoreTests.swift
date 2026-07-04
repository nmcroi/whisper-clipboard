import Core
import Foundation
import GRDB
import XCTest
import WhisperShared
@testable import WhisperClipboard

@MainActor
final class HistoryStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a store over a fresh in-memory database with the given retention.
    private func makeStore(retention: Int? = nil) throws -> HistoryStore {
        let queue = try DatabaseQueue()
        return try HistoryStore(dbQueue: queue, retentionProvider: { retention })
    }

    private func entry(
        id: String = UUID().uuidString,
        text: String,
        name: String = "",
        pinned: Bool = false,
        source: String = "mic",
        createdAt: String = "2026-06-21T10:00:00+02:00",
        duration: Double = 0,
        segments: [TranscriptSegment] = []
    ) -> TranscriptEntry {
        TranscriptEntry(
            id: id, text: text, createdAt: createdAt, name: name, pinned: pinned,
            language: "nl", model: "parakeet-tdt-0.6b-v3", source: source,
            duration: duration, segments: segments
        )
    }

    // MARK: - CRUD

    func testAddAndFetch() throws {
        let store = try makeStore()
        try store.add(entry(text: "Hallo wereld"))
        let all = try store.entries()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.text, "Hallo wereld")
        XCTAssertEqual(try store.count(), 1)
    }

    func testDelete() throws {
        let store = try makeStore()
        let e = entry(id: "e1", text: "Verwijder mij")
        try store.add(e)
        try store.delete(id: "e1")
        XCTAssertEqual(try store.count(), 0)
    }

    func testRename() throws {
        let store = try makeStore()
        let e = entry(id: "e1", text: "iets")
        try store.add(e)
        try store.rename(id: "e1", name: "  Mijn notitie  ")
        let fetched = try store.entries().first
        XCTAssertEqual(fetched?.name, "Mijn notitie") // trimmed
    }

    func testSetPinned() throws {
        let store = try makeStore()
        let e = entry(id: "e1", text: "vast")
        try store.add(e)
        try store.setPinned(id: "e1", true)
        XCTAssertTrue(try store.entries().first?.pinned ?? false)
        try store.setPinned(id: "e1", false)
        XCTAssertFalse(try store.entries().first?.pinned ?? true)
    }

    func testSegmentsRoundTrip() throws {
        let store = try makeStore()
        let segs = [
            TranscriptSegment(start: 0, end: 1.5, text: "Eerste"),
            TranscriptSegment(start: 1.5, end: 3, text: "Tweede"),
        ]
        try store.add(entry(id: "e1", text: "Eerste Tweede", duration: 3, segments: segs))
        let fetched = try store.entries().first
        XCTAssertEqual(fetched?.segments, segs)
    }

    // MARK: - Inline editing / trimming / speaker naming (M-detail)

    func testUpdateTextOverwritesBodyAndIsSearchable() throws {
        let store = try makeStore()
        try store.add(entry(id: "e1", text: "oude tekst hier"))
        try store.updateText(id: "e1", text: "compleet nieuwe inhoud")
        let fetched = try store.entries().first
        XCTAssertEqual(fetched?.text, "compleet nieuwe inhoud")
        // FTS index tracks the new text, not the old.
        XCTAssertEqual(try store.entries(query: "nieuwe").map(\.id), ["e1"])
        XCTAssertTrue(try store.entries(query: "oude").isEmpty)
    }

    func testUpdateTextClearsSegments() throws {
        // Edited-text policy: a manual body edit drops the now-misaligned
        // word-level timing so the edited text is the single source of truth.
        let store = try makeStore()
        let segs = [
            TranscriptSegment(start: 0, end: 1, text: "een"),
            TranscriptSegment(start: 1, end: 2, text: "twee"),
        ]
        try store.add(entry(id: "e1", text: "een twee", segments: segs))
        try store.updateText(id: "e1", text: "handmatig bewerkt")
        let fetched = try store.entries().first
        XCTAssertEqual(fetched?.text, "handmatig bewerkt")
        XCTAssertEqual(fetched?.segments, [])
    }

    func testUpdateSegmentsRebuildsTextNoSpeakers() throws {
        let store = try makeStore()
        let segs = [
            TranscriptSegment(start: 0, end: 1, text: "een"),
            TranscriptSegment(start: 1, end: 2, text: "twee."),
            TranscriptSegment(start: 2, end: 3, text: "drie"),
        ]
        try store.add(entry(id: "e1", text: "een twee. drie", segments: segs))
        // Drop the middle word (simulating a trim).
        let kept = [segs[0], segs[2]]
        try store.updateSegments(id: "e1", segments: kept)
        let fetched = try store.entries().first
        XCTAssertEqual(fetched?.segments, kept)
        XCTAssertEqual(fetched?.text, "een drie")
    }

    func testUpdateSegmentsRebuildsPlainTextKeepingSpeakerSegments() throws {
        // The rebuilt `text` stays plain (no "Spreker N:" labels); the speaker
        // labels live on the segments, which the exporter/grouped view read.
        let store = try makeStore()
        let segs = [
            TranscriptSegment(start: 0, end: 1, text: "Hallo.", speaker: "Spreker 1"),
            TranscriptSegment(start: 1, end: 2, text: "Dank.", speaker: "Spreker 2"),
        ]
        try store.add(entry(id: "e1", text: "x", segments: segs))
        try store.updateSegments(id: "e1", segments: segs)
        let fetched = try store.entries().first
        XCTAssertEqual(fetched?.text, "Hallo. Dank.")
        // Speaker labels are preserved on the segments.
        XCTAssertEqual(fetched?.segments.compactMap(\.speaker), ["Spreker 1", "Spreker 2"])
    }

    func testUpdateSegmentsPreservesSpeakerNamesAndPinned() throws {
        let store = try makeStore()
        let segs = [TranscriptSegment(start: 0, end: 1, text: "Hallo.", speaker: "Spreker 1")]
        try store.add(entry(id: "e1", text: "x", pinned: true, segments: segs))
        try store.setSpeakerName(transcriptId: "e1", rawSpeaker: "Spreker 1", name: "Baas")
        try store.updateSegments(id: "e1", segments: segs)
        let fetched = try store.entries().first
        XCTAssertEqual(fetched?.speakerNames["Spreker 1"], "Baas")
        XCTAssertTrue(fetched?.pinned ?? false)
    }

    func testSetSpeakerNameRoundTripsAndTrims() throws {
        let store = try makeStore()
        try store.add(entry(id: "e1", text: "x",
                            segments: [TranscriptSegment(start: 0, end: 1, text: "a", speaker: "Spreker 1")]))
        try store.setSpeakerName(transcriptId: "e1", rawSpeaker: "Spreker 1", name: "  Autoverkoper  ")
        var fetched = try store.entries().first
        XCTAssertEqual(fetched?.speakerNames["Spreker 1"], "Autoverkoper") // trimmed
        XCTAssertEqual(fetched?.displayName(forSpeaker: "Spreker 1"), "Autoverkoper")

        // Blank name clears the mapping (raw label shows again).
        try store.setSpeakerName(transcriptId: "e1", rawSpeaker: "Spreker 1", name: "   ")
        fetched = try store.entries().first
        XCTAssertNil(fetched?.speakerNames["Spreker 1"])
        XCTAssertEqual(fetched?.displayName(forSpeaker: "Spreker 1"), "Spreker 1")
    }

    func testSpeakerNamesRoundTripThroughInsert() throws {
        let store = try makeStore()
        try store.add(entry(id: "e1", text: "x"))
        try store.setSpeakerName(transcriptId: "e1", rawSpeaker: "Spreker 2", name: "Klant")
        // Re-fetch fresh (exercises the DB column decode path).
        let fetched = try store.entries(query: nil).first { $0.id == "e1" }
        XCTAssertEqual(fetched?.speakerNames, ["Spreker 2": "Klant"])
    }

    // MARK: - Ordering (newest first)

    func testNewestFirstOrdering() throws {
        let store = try makeStore()
        try store.add(entry(id: "old", text: "oud", createdAt: "2026-06-01T10:00:00+02:00"))
        try store.add(entry(id: "new", text: "nieuw", createdAt: "2026-06-21T10:00:00+02:00"))
        let all = try store.entries()
        XCTAssertEqual(all.map(\.id), ["new", "old"])
    }

    // MARK: - FTS5 search

    func testFTSSearchDutchWord() throws {
        let store = try makeStore()
        try store.add(entry(id: "a", text: "De boodschappen van Albert Heijn"))
        try store.add(entry(id: "b", text: "Een gesprek over de vakantie"))
        let hits = try store.entries(query: "boodschappen")
        XCTAssertEqual(hits.map(\.id), ["a"])
    }

    func testFTSPrefixMatch() throws {
        let store = try makeStore()
        try store.add(entry(id: "a", text: "boodschappenlijst voor vandaag"))
        // Prefix "boodsch" should still match "boodschappenlijst".
        let hits = try store.entries(query: "boodsch")
        XCTAssertEqual(hits.map(\.id), ["a"])
    }

    func testFTSMatchesName() throws {
        let store = try makeStore()
        var e = entry(id: "a", text: "irrelevante tekst")
        e.name = "Vergadernotulen"
        try store.add(e)
        let hits = try store.entries(query: "vergader")
        XCTAssertEqual(hits.map(\.id), ["a"])
    }

    func testFTSMultiTokenIsAnd() throws {
        let store = try makeStore()
        try store.add(entry(id: "a", text: "appel en peer samen"))
        try store.add(entry(id: "b", text: "alleen appel hier"))
        let hits = try store.entries(query: "appel peer")
        XCTAssertEqual(hits.map(\.id), ["a"])
    }

    func testEmptyQueryReturnsAll() throws {
        let store = try makeStore()
        try store.add(entry(id: "a", text: "een"))
        try store.add(entry(id: "b", text: "twee"))
        XCTAssertEqual(try store.entries(query: "   ").count, 2)
        XCTAssertNil(HistoryStore.ftsPattern(from: "   "))
    }

    func testFTSSpecialCharactersDoNotCrash() throws {
        let store = try makeStore()
        try store.add(entry(id: "a", text: "quote \"test\" hier"))
        // A raw quote in the query must be safely escaped, not throw.
        XCTAssertNoThrow(try store.entries(query: "\"test"))
    }

    // MARK: - Filters

    func testSourceFilter() throws {
        let store = try makeStore()
        try store.add(entry(id: "m", text: "mic tekst", source: "mic"))
        try store.add(entry(id: "f", text: "bestand tekst", source: "file"))
        XCTAssertEqual(try store.entries(filter: .mic).map(\.id), ["m"])
        XCTAssertEqual(try store.entries(filter: .file).map(\.id), ["f"])
        XCTAssertEqual(try store.entries(filter: .all).count, 2)
    }

    func testFilterCombinedWithSearch() throws {
        let store = try makeStore()
        try store.add(entry(id: "m", text: "notulen microfoon", source: "mic"))
        try store.add(entry(id: "f", text: "notulen bestand", source: "file"))
        let hits = try store.entries(query: "notulen", filter: .file)
        XCTAssertEqual(hits.map(\.id), ["f"])
    }

    // MARK: - Paging

    func testPaging() throws {
        let store = try makeStore()
        for i in 0..<10 {
            let day = String(format: "%02d", i + 1)
            try store.add(entry(id: "e\(i)", text: "tekst \(i)", createdAt: "2026-06-\(day)T10:00:00+02:00"))
        }
        let page1 = try store.entries(limit: 3, offset: 0)
        let page2 = try store.entries(limit: 3, offset: 3)
        XCTAssertEqual(page1.count, 3)
        XCTAssertEqual(page2.count, 3)
        // Newest first: e9 is newest.
        XCTAssertEqual(page1.first?.id, "e9")
        XCTAssertNotEqual(Set(page1.map(\.id)), Set(page2.map(\.id)))
        XCTAssertEqual(try store.count(), 10)
    }

    func testRecent() throws {
        let store = try makeStore()
        for i in 0..<5 {
            let day = String(format: "%02d", i + 1)
            try store.add(entry(id: "e\(i)", text: "t\(i)", createdAt: "2026-06-\(day)T10:00:00+02:00"))
        }
        let recent = try store.recent(2)
        XCTAssertEqual(recent.map(\.id), ["e4", "e3"])
    }

    // MARK: - Retention pruning (Python _trim semantics)

    func testRetentionPrunesUnpinned() throws {
        let store = try makeStore(retention: 3)
        for i in 0..<6 {
            let day = String(format: "%02d", i + 1)
            try store.add(entry(id: "e\(i)", text: "t\(i)", createdAt: "2026-06-\(day)T10:00:00+02:00"))
        }
        // Only the 3 newest unpinned survive.
        let ids = try store.entries().map(\.id)
        XCTAssertEqual(ids, ["e5", "e4", "e3"])
    }

    func testPinnedNeverPruned() throws {
        let store = try makeStore(retention: 2)
        // Add an old pinned entry, then flood with newer unpinned ones.
        try store.add(entry(id: "pinned", text: "belangrijk", pinned: true, createdAt: "2026-06-01T10:00:00+02:00"))
        for i in 0..<5 {
            let day = String(format: "%02d", i + 10)
            try store.add(entry(id: "e\(i)", text: "t\(i)", createdAt: "2026-06-\(day)T10:00:00+02:00"))
        }
        let ids = try store.entries().map(\.id)
        // Pinned survives despite being oldest; plus the 2 newest unpinned.
        XCTAssertTrue(ids.contains("pinned"))
        XCTAssertEqual(ids.filter { $0 != "pinned" }, ["e4", "e3"])
    }

    func testUnpinningReappliesRetention() throws {
        let store = try makeStore(retention: 2)
        try store.add(entry(id: "old", text: "oud", pinned: true, createdAt: "2026-06-01T10:00:00+02:00"))
        for i in 0..<2 {
            let day = String(format: "%02d", i + 10)
            try store.add(entry(id: "e\(i)", text: "t\(i)", createdAt: "2026-06-\(day)T10:00:00+02:00"))
        }
        // 3 entries kept (2 unpinned + 1 pinned). Unpin the old one → it now
        // competes in the unpinned budget of 2 and, being oldest, is pruned.
        try store.setPinned(id: "old", false)
        let ids = try store.entries().map(\.id)
        XCTAssertFalse(ids.contains("old"))
        XCTAssertEqual(ids, ["e1", "e0"])
    }

    func testZeroRetentionTreatedAsUnlimited() throws {
        // A retention of 0 must NOT wipe every unpinned entry (it would delete
        // the transcript the user just recorded). 0 is treated as disabled.
        let store = try makeStore(retention: 0)
        for i in 0..<5 {
            try store.add(entry(id: "e\(i)", text: "t\(i)"))
        }
        XCTAssertEqual(try store.count(), 5)
    }

    func testNilRetentionKeepsEverything() throws {
        let store = try makeStore(retention: nil)
        for i in 0..<30 {
            try store.add(entry(id: "e\(i)", text: "t\(i)"))
        }
        XCTAssertEqual(try store.count(), 30)
    }

    // MARK: - Migration from a v3 JSON fixture

    /// A minimal v3 history.json mirroring the real file's first entries
    /// (an unnamed segmented entry + an unnamed segmentless entry + a
    /// deliberately malformed row that must be skipped).
    private var v3FixtureJSON: String {
        """
        {
          "version": 3,
          "entries": [
            {
              "id": "a516804f-66d4-4ad7-ac37-332a6547fd7f",
              "text": "Twee dingen over de boodschappen van Albert Heijn.",
              "created_at": "2026-06-21T10:27:04+02:00",
              "name": "", "pinned": false, "language": "nl", "model": "medium",
              "source": "mic", "duration": 91.15,
              "segments": [
                {"start": 0.78, "end": 7.78, "text": "Twee dingen."}
              ]
            },
            {
              "id": "a4b1d4a3-249e-4eb2-a815-274bef29d6cc",
              "text": "Ja, maar je moet er ook bij schrijven.",
              "created_at": "2026-06-21T10:07:46+02:00",
              "name": "", "pinned": false, "language": "", "model": "",
              "source": "mic", "duration": 0.0, "segments": []
            },
            "just-a-string-not-an-object",
            null
          ]
        }
        """
    }

    /// Writes the fixture to a temp file and returns its URL (a COPY — never
    /// the live history.json).
    private func writeV3Fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wc-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.json")
        try v3FixtureJSON.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "wc-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testMigrationImportsEntries() throws {
        let store = try makeStore()
        let url = try writeV3Fixture()
        let defaults = freshDefaults()

        let imported = store.migrateFromV3IfNeeded(legacyURL: url, defaults: defaults)
        XCTAssertEqual(imported, 2) // 2 valid, 2 malformed skipped
        XCTAssertEqual(try store.count(), 2)
        XCTAssertTrue(defaults.bool(forKey: "migratedFromV3"))

        // The segmented entry preserves its segment.
        let segmented = try store.entries(query: "Albert").first
        XCTAssertEqual(segmented?.segments.count, 1)
    }

    func testMigrationIsIdempotent() throws {
        let store = try makeStore()
        let url = try writeV3Fixture()
        let defaults = freshDefaults()

        _ = store.migrateFromV3IfNeeded(legacyURL: url, defaults: defaults)
        // Second call is a no-op because the flag is set.
        let secondRun = store.migrateFromV3IfNeeded(legacyURL: url, defaults: defaults)
        XCTAssertEqual(secondRun, 0)
        XCTAssertEqual(try store.count(), 2)
    }

    func testMigrationLeavesFixtureFileUntouched() throws {
        let store = try makeStore()
        let url = try writeV3Fixture()
        let before = try Data(contentsOf: url)
        _ = store.migrateFromV3IfNeeded(legacyURL: url, defaults: freshDefaults())
        let after = try Data(contentsOf: url)
        XCTAssertEqual(before, after) // migration reads only, never writes
    }

    func testMigrationNoFileMarksDone() throws {
        let store = try makeStore()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let defaults = freshDefaults()
        let imported = store.migrateFromV3IfNeeded(legacyURL: missing, defaults: defaults)
        XCTAssertEqual(imported, 0)
        XCTAssertTrue(defaults.bool(forKey: "migratedFromV3"))
    }

    /// Finding #5: an in-memory (non-persistent) fallback store imports the legacy
    /// entries into RAM for the current session but must NOT persist the
    /// "migration done" flag — otherwise a later launch with a working on-disk DB
    /// would skip the migration and lose the legacy history for good.
    func testMigrationIntoInMemoryFallbackDoesNotPersistFlag() throws {
        let queue = try DatabaseQueue()
        let store = try HistoryStore(dbQueue: queue, retentionProvider: { nil }, isPersistent: false)
        let url = try writeV3Fixture()
        let defaults = freshDefaults()

        let imported = store.migrateFromV3IfNeeded(legacyURL: url, defaults: defaults)
        // Entries are imported so this session has usable data…
        XCTAssertEqual(imported, 2)
        XCTAssertEqual(try store.count(), 2)
        // …but the persistent flag stays UNSET so a real DB retries next launch.
        XCTAssertFalse(defaults.bool(forKey: "migratedFromV3"))
    }

    /// The no-legacy-file path also must not persist the flag on an in-memory
    /// fallback (a transient disk failure at first launch would otherwise mark the
    /// migration done before the real DB ever saw the file).
    func testMigrationNoFileOnInMemoryFallbackDoesNotPersistFlag() throws {
        let queue = try DatabaseQueue()
        let store = try HistoryStore(dbQueue: queue, retentionProvider: { nil }, isPersistent: false)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let defaults = freshDefaults()
        let imported = store.migrateFromV3IfNeeded(legacyURL: missing, defaults: defaults)
        XCTAssertEqual(imported, 0)
        XCTAssertFalse(defaults.bool(forKey: "migratedFromV3"))
    }

    // MARK: - Notities: losmaken

    /// `detachEntryFromNote` zet `note_id` terug op NULL zodat de opname weer als
    /// losse Geschiedenis-entry verschijnt (die filtert op `note_id IS NULL`).
    func testDetachEntryFromNote() throws {
        let store = try makeStore()
        let note = try store.createNote(title: "Reis")
        let e = entry(id: "e1", text: "Hallo notitie")
        try store.appendToNote(e, noteId: note.id)

        // Zit nu in de notitie, niet in de losse Geschiedenis.
        XCTAssertEqual(try store.noteEntries(noteId: note.id).count, 1)
        XCTAssertEqual(try store.count(), 0)

        try store.detachEntryFromNote(entryId: "e1")

        // Terug als losse opname; niet meer aan de notitie gekoppeld.
        XCTAssertEqual(try store.noteEntries(noteId: note.id).count, 0)
        XCTAssertEqual(try store.count(), 1)
        XCTAssertEqual(try store.entries().first?.id, "e1")
    }

    // MARK: - FTS pattern helper

    func testFTSPatternEscaping() {
        XCTAssertEqual(HistoryStore.ftsPattern(from: "hallo"), "\"hallo\"*")
        XCTAssertEqual(HistoryStore.ftsPattern(from: "twee woorden"), "\"twee\"* \"woorden\"*")
        XCTAssertNil(HistoryStore.ftsPattern(from: ""))
    }
}
