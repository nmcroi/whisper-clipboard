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

    // MARK: - windowCutoff

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    @Test func windowCutoffZeroIsNil() {
        #expect(PlaudSyncLogic.windowCutoff(windowDays: 0, now: Self.now) == nil)
    }

    @Test func windowCutoffNegativeIsNil() {
        // Defensive: a negative day count is treated as "no window".
        #expect(PlaudSyncLogic.windowCutoff(windowDays: -5, now: Self.now) == nil)
    }

    @Test func windowCutoffSubtractsDays() {
        let cutoff = PlaudSyncLogic.windowCutoff(windowDays: 30, now: Self.now)
        #expect(cutoff == Self.now.addingTimeInterval(-30 * Self.day))
    }

    // MARK: - effectiveSince

    /// windowDays == 0, no checkpoint → nil (first run lists the full history).
    @Test func effectiveSinceNoWindowNoCheckpointIsNil() {
        let since = PlaudSyncLogic.effectiveSince(
            checkpoint: nil, overlap: Self.day, windowDays: 0, now: Self.now
        )
        #expect(since == nil)
    }

    /// windowDays == 0, with a checkpoint → checkpoint − overlap (incremental).
    @Test func effectiveSinceNoWindowUsesCheckpointMinusOverlap() {
        let checkpoint = Self.now.addingTimeInterval(-2 * Self.day)
        let since = PlaudSyncLogic.effectiveSince(
            checkpoint: checkpoint, overlap: Self.day, windowDays: 0, now: Self.now
        )
        #expect(since == checkpoint.addingTimeInterval(-Self.day))
    }

    /// The key first-run guard: windowDays > 0 with NO checkpoint returns the
    /// window cutoff (not nil), so a first sync only pulls the last N days.
    @Test func effectiveSinceWindowFirstRunIsWindowCutoff() {
        let since = PlaudSyncLogic.effectiveSince(
            checkpoint: nil, overlap: Self.day, windowDays: 30, now: Self.now
        )
        #expect(since == Self.now.addingTimeInterval(-30 * Self.day))
    }

    /// A recent checkpoint (newer than the window cutoff) wins, so incremental
    /// syncs stay cheap instead of re-listing the whole window every time.
    @Test func effectiveSinceRecentCheckpointWinsOverWindow() {
        let checkpoint = Self.now.addingTimeInterval(-1 * Self.day) // 1 day ago
        let since = PlaudSyncLogic.effectiveSince(
            checkpoint: checkpoint, overlap: Self.day, windowDays: 30, now: Self.now
        )
        // checkpoint − overlap (2 days ago) is more recent than the 30-day cutoff.
        #expect(since == checkpoint.addingTimeInterval(-Self.day))
    }

    /// An ancient checkpoint (older than the window cutoff) must NOT drag the
    /// fetch back past the window — the window cutoff wins.
    @Test func effectiveSinceWindowCapsAncientCheckpoint() {
        let checkpoint = Self.now.addingTimeInterval(-365 * Self.day) // a year ago
        let since = PlaudSyncLogic.effectiveSince(
            checkpoint: checkpoint, overlap: Self.day, windowDays: 30, now: Self.now
        )
        #expect(since == Self.now.addingTimeInterval(-30 * Self.day))
    }
}
