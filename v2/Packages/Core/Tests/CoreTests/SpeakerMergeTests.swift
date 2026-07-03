import Testing
import Foundation
@testable import Core

@Suite struct SpeakerMergeTests {

    private func seg(_ start: Double, _ end: Double, _ text: String = "x") -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text)
    }

    @Test func noTurnsLeavesSegmentsUnchanged() {
        let segments = [seg(0, 1), seg(1, 2)]
        let result = SpeakerMerge.assign(segments: segments, turns: [])
        #expect(result == segments)
        #expect(result.allSatisfy { $0.speaker == nil })
    }

    @Test func assignsSpeakerByMaxOverlap() {
        // Segment 0..1 overlaps A fully; segment 1..2 overlaps B fully.
        let segments = [seg(0, 1), seg(1, 2)]
        let turns = [
            SpeakerTurn(start: 0, end: 1, speakerId: "A"),
            SpeakerTurn(start: 1, end: 2, speakerId: "B"),
        ]
        let result = SpeakerMerge.assign(segments: segments, turns: turns)
        #expect(result[0].speaker == "Spreker 1")
        #expect(result[1].speaker == "Spreker 2")
    }

    @Test func partialOverlapPicksLargerShare() {
        // Segment 0..10: A covers 0..3 (3s), B covers 3..10 (7s) → B wins.
        let segments = [seg(0, 10)]
        let turns = [
            SpeakerTurn(start: 0, end: 3, speakerId: "A"),
            SpeakerTurn(start: 3, end: 10, speakerId: "B"),
        ]
        let result = SpeakerMerge.assign(segments: segments, turns: turns)
        // B appears first (only speaker), so it is renamed "Spreker 1".
        #expect(result[0].speaker == "Spreker 1")
    }

    @Test func segmentWithNoOverlapKeepsNil() {
        let segments = [seg(0, 1), seg(5, 6)]
        let turns = [SpeakerTurn(start: 0, end: 1, speakerId: "A")]  // only overlaps seg 0
        let result = SpeakerMerge.assign(segments: segments, turns: turns)
        #expect(result[0].speaker == "Spreker 1")
        #expect(result[1].speaker == nil)
    }

    @Test func renamesByFirstAppearanceNotRawId() {
        // Raw ids appear in the order Z (first), then A. Numbering follows the
        // transcript order, so Z → Spreker 1 and A → Spreker 2.
        let segments = [seg(0, 1), seg(1, 2), seg(2, 3)]
        let turns = [
            SpeakerTurn(start: 0, end: 1, speakerId: "Z"),
            SpeakerTurn(start: 1, end: 2, speakerId: "A"),
            SpeakerTurn(start: 2, end: 3, speakerId: "Z"),
        ]
        let result = SpeakerMerge.assign(segments: segments, turns: turns)
        #expect(result[0].speaker == "Spreker 1")  // Z
        #expect(result[1].speaker == "Spreker 2")  // A
        #expect(result[2].speaker == "Spreker 1")  // Z again → same label
    }

    @Test func summedOverlapAcrossMultipleTurnsWins() {
        // Segment 0..10: A has two short turns (2+2=4s), B one turn (3s).
        // A's summed overlap (4s) beats B (3s).
        let segments = [seg(0, 10)]
        let turns = [
            SpeakerTurn(start: 0, end: 2, speakerId: "A"),
            SpeakerTurn(start: 2, end: 5, speakerId: "B"),
            SpeakerTurn(start: 8, end: 10, speakerId: "A"),
        ]
        let result = SpeakerMerge.assign(segments: segments, turns: turns)
        #expect(result[0].speaker == "Spreker 1")  // A, first-appearing raw id here
    }

    @Test func tieBrokenDeterministically() {
        // Equal overlap for A and B; must be stable regardless of turn order.
        let segments = [seg(0, 2)]
        let turnsAB = [
            SpeakerTurn(start: 0, end: 1, speakerId: "A"),
            SpeakerTurn(start: 1, end: 2, speakerId: "B"),
        ]
        let turnsBA = [
            SpeakerTurn(start: 1, end: 2, speakerId: "B"),
            SpeakerTurn(start: 0, end: 1, speakerId: "A"),
        ]
        let r1 = SpeakerMerge.assign(segments: segments, turns: turnsAB)
        let r2 = SpeakerMerge.assign(segments: segments, turns: turnsBA)
        #expect(r1[0].speaker == r2[0].speaker)
        #expect(r1[0].speaker == "Spreker 1")
    }
}
