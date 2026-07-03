import Core
import Foundation
import GRDB
import XCTest
@testable import WhisperClipboard

/// Tests for the M4 `ai_results` bridge on ``HistoryStore``, against a temp DB.
@MainActor
final class AIResultStoreTests: XCTestCase {

    private func makeStore() throws -> HistoryStore {
        let queue = try DatabaseQueue()
        return try HistoryStore(dbQueue: queue, retentionProvider: { nil })
    }

    private func transcript(id: String = "t1") -> TranscriptEntry {
        TranscriptEntry(
            id: id, text: "Bron transcript", createdAt: "2026-06-21T10:00:00+02:00",
            name: "", pinned: false, language: "nl", model: "parakeet",
            source: "mic", duration: 0, segments: []
        )
    }

    private func result(id: String, transcriptId: String = "t1", mode: String = "Samenvatting", createdAt: Date = Date()) -> AIResult {
        AIResult(
            id: id, transcriptId: transcriptId, modeId: "builtin.\(mode)",
            modeName: mode, output: "Resultaat \(id)", createdAt: createdAt
        )
    }

    func testAddAndFetch() throws {
        let store = try makeStore()
        try store.add(transcript())
        try store.addAIResult(result(id: "r1"))
        let results = try store.aiResults(forTranscript: "t1")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "r1")
        XCTAssertEqual(results.first?.modeName, "Samenvatting")
        XCTAssertEqual(results.first?.output, "Resultaat r1")
    }

    func testMultipleResultsPerTranscriptNewestFirst() throws {
        let store = try makeStore()
        try store.add(transcript())
        let old = result(id: "old", createdAt: Date(timeIntervalSince1970: 1000))
        let new = result(id: "new", mode: "E-mail", createdAt: Date(timeIntervalSince1970: 2000))
        try store.addAIResult(old)
        try store.addAIResult(new)
        let results = try store.aiResults(forTranscript: "t1")
        XCTAssertEqual(results.map(\.id), ["new", "old"])
    }

    func testResultsScopedToTranscript() throws {
        let store = try makeStore()
        try store.add(transcript(id: "a"))
        try store.add(transcript(id: "b"))
        try store.addAIResult(result(id: "ra", transcriptId: "a"))
        try store.addAIResult(result(id: "rb", transcriptId: "b"))
        XCTAssertEqual(try store.aiResults(forTranscript: "a").map(\.id), ["ra"])
        XCTAssertEqual(try store.aiResults(forTranscript: "b").map(\.id), ["rb"])
    }

    func testDeleteResult() throws {
        let store = try makeStore()
        try store.add(transcript())
        try store.addAIResult(result(id: "r1"))
        try store.addAIResult(result(id: "r2"))
        try store.deleteAIResult(id: "r1")
        XCTAssertEqual(try store.aiResults(forTranscript: "t1").map(\.id), ["r2"])
    }

    func testDeletingTranscriptCascadesResults() throws {
        let store = try makeStore()
        try store.add(transcript())
        try store.addAIResult(result(id: "r1"))
        // The ai_results FK is ON DELETE CASCADE (see HistorySchema v3).
        try store.delete(id: "t1")
        XCTAssertTrue(try store.aiResults(forTranscript: "t1").isEmpty)
    }

    func testCreatedAtRoundTrips() throws {
        let store = try makeStore()
        try store.add(transcript())
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.addAIResult(result(id: "r1", createdAt: date))
        let fetched = try XCTUnwrap(store.aiResults(forTranscript: "t1").first)
        XCTAssertEqual(fetched.createdAt.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1.0)
    }
}
