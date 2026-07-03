import Testing
import Foundation
@testable import Core

/// Pure-logic tests for PLAUD cloud sync: the new-recording decision and the
/// interval clamp. No network is touched.
@Suite struct PlaudSyncLogicTests {

    // MARK: - newRecordingIds

    @Test func allNewWhenNothingProcessed() {
        let ids = ["a", "b", "c"]
        #expect(PlaudSyncLogic.newRecordingIds(fetchedIds: ids, processed: []) == ["a", "b", "c"])
    }

    @Test func filtersOutAlreadyProcessed() {
        let ids = ["a", "b", "c", "d"]
        let processed: Set<String> = ["b", "d"]
        #expect(PlaudSyncLogic.newRecordingIds(fetchedIds: ids, processed: processed) == ["a", "c"])
    }

    @Test func preservesInputOrderNewestFirst() {
        // PLAUD returns newest-first; the order must be preserved so the newest
        // recording is enqueued first.
        let ids = ["newest", "middle", "oldest"]
        #expect(PlaudSyncLogic.newRecordingIds(fetchedIds: ids, processed: []) == ["newest", "middle", "oldest"])
    }

    @Test func dropsDuplicatesWithinBatch() {
        let ids = ["a", "a", "b", "b", "c"]
        #expect(PlaudSyncLogic.newRecordingIds(fetchedIds: ids, processed: []) == ["a", "b", "c"])
    }

    @Test func dropsBlankAndWhitespaceIds() {
        let ids = ["a", "", "   ", "b"]
        #expect(PlaudSyncLogic.newRecordingIds(fetchedIds: ids, processed: []) == ["a", "b"])
    }

    @Test func trimsBeforeComparing() {
        // A processed id stored without surrounding whitespace still matches a
        // fetched id that arrives padded.
        let ids = [" a ", "b"]
        let processed: Set<String> = ["a"]
        #expect(PlaudSyncLogic.newRecordingIds(fetchedIds: ids, processed: processed) == ["b"])
    }

    @Test func emptyWhenAllProcessed() {
        let ids = ["a", "b"]
        #expect(PlaudSyncLogic.newRecordingIds(fetchedIds: ids, processed: ["a", "b"]).isEmpty)
    }

    @Test func hasNewRecordingsMatchesDecision() {
        #expect(PlaudSyncLogic.hasNewRecordings(fetchedIds: ["a"], processed: []) == true)
        #expect(PlaudSyncLogic.hasNewRecordings(fetchedIds: ["a"], processed: ["a"]) == false)
        #expect(PlaudSyncLogic.hasNewRecordings(fetchedIds: [], processed: []) == false)
    }

    // MARK: - clampIntervalMinutes

    @Test func clampFloorsAtOneMinute() {
        #expect(PlaudSyncLogic.clampIntervalMinutes(0) == 1)
        #expect(PlaudSyncLogic.clampIntervalMinutes(-5) == 1)
    }

    @Test func clampCeilingsAtOneDay() {
        #expect(PlaudSyncLogic.clampIntervalMinutes(100_000) == 24 * 60)
    }

    @Test func clampPassesThroughReasonableValues() {
        #expect(PlaudSyncLogic.clampIntervalMinutes(15) == 15)
        #expect(PlaudSyncLogic.clampIntervalMinutes(1) == 1)
        #expect(PlaudSyncLogic.clampIntervalMinutes(1440) == 1440)
    }
}
