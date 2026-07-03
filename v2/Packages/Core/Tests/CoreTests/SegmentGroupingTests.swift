import Testing
import Foundation
@testable import Core

@Suite struct SegmentGroupingTests {

    /// A word segment. `speaker` defaults to nil.
    private func w(_ start: Double, _ end: Double, _ text: String, _ speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, speaker: speaker)
    }

    // MARK: - Sentences

    @Test func sentencesEmptyInput() {
        #expect(SegmentGrouping.sentences(from: []) == [])
    }

    @Test func sentencesBreakOnTerminalPunctuation() {
        // "Hallo wereld." then "Hoe gaat het?" — two sentences from six words.
        let words = [
            w(0.0, 0.5, "Hallo"),
            w(0.5, 1.0, "wereld."),
            w(1.2, 1.6, "Hoe"),
            w(1.6, 1.9, "gaat"),
            w(1.9, 2.2, "het?"),
        ]
        let out = SegmentGrouping.sentences(from: words)
        #expect(out.count == 2)
        #expect(out[0].text == "Hallo wereld.")
        #expect(out[0].start == 0.0)
        #expect(out[0].end == 1.0)
        #expect(out[1].text == "Hoe gaat het?")
        #expect(out[1].start == 1.2)
        #expect(out[1].end == 2.2)
    }

    @Test func sentencesBreakOnLargeGap() {
        // No terminal punctuation, but a 3s gap splits the phrase in two.
        let words = [
            w(0.0, 0.5, "eerste"),
            w(0.5, 1.0, "stuk"),
            w(4.0, 4.5, "tweede"),  // gap 3.0s > 1.5s threshold
            w(4.5, 5.0, "stuk"),
        ]
        let out = SegmentGrouping.sentences(from: words)
        #expect(out.count == 2)
        #expect(out[0].text == "eerste stuk")
        #expect(out[1].text == "tweede stuk")
    }

    @Test func sentencesCommaDoesNotBreak() {
        // A comma is not sentence-final: the whole thing stays one sentence.
        let words = [
            w(0.0, 0.4, "ja,"),
            w(0.4, 0.8, "maar"),
            w(0.8, 1.2, "toch"),
        ]
        let out = SegmentGrouping.sentences(from: words)
        #expect(out.count == 1)
        #expect(out[0].text == "ja, maar toch")
    }

    @Test func sentencesTrailingWordsWithoutPunctuationStillFlush() {
        let words = [w(0, 0.5, "een"), w(0.5, 1.0, "twee")]
        let out = SegmentGrouping.sentences(from: words)
        #expect(out.count == 1)
        #expect(out[0].text == "een twee")
        #expect(out[0].end == 1.0)
    }

    @Test func sentencesTerminalPunctuationWithClosingQuote() {
        // A closing quote after the period must still count as sentence-final.
        let words = [
            w(0.0, 0.4, "hij"),
            w(0.4, 0.8, "zei"),
            w(0.8, 1.4, "\u{201C}genoeg.\u{201D}"),
            w(1.5, 1.9, "Toen"),
            w(1.9, 2.3, "stopte."),
        ]
        let out = SegmentGrouping.sentences(from: words)
        #expect(out.count == 2)
        #expect(out[0].text.hasSuffix("\u{201D}"))
        #expect(out[1].text == "Toen stopte.")
    }

    @Test func sentencesCarrySpeakerByMajority() {
        // Three words: two Spreker 1, one Spreker 2 → sentence attributed to 1.
        let words = [
            w(0.0, 0.4, "a", "Spreker 1"),
            w(0.4, 0.8, "b", "Spreker 2"),
            w(0.8, 1.2, "c.", "Spreker 1"),
        ]
        let out = SegmentGrouping.sentences(from: words)
        #expect(out.count == 1)
        #expect(out[0].speaker == "Spreker 1")
    }

    @Test func sentencesWithNoSpeakersHaveNilSpeaker() {
        let words = [w(0, 0.4, "a"), w(0.4, 0.8, "b.")]
        let out = SegmentGrouping.sentences(from: words)
        #expect(out.count == 1)
        #expect(out[0].speaker == nil)
    }

    @Test func sentencesSkipEmptyWords() {
        let words = [w(0, 0.4, "a"), w(0.4, 0.8, "   "), w(0.8, 1.2, "b.")]
        let out = SegmentGrouping.sentences(from: words)
        #expect(out.count == 1)
        #expect(out[0].text == "a b.")
    }

    // MARK: - Speaker turns

    @Test func turnsEmptyInput() {
        #expect(SegmentGrouping.speakerTurns(from: []) == [])
    }

    @Test func turnsSingleSpeakerWholeThingIsOneTurn() {
        // No speaker labels at all → a single nil-speaker turn spanning everything.
        let words = [w(0, 0.5, "een"), w(0.5, 1.0, "twee"), w(1.0, 1.5, "drie.")]
        let out = SegmentGrouping.speakerTurns(from: words)
        #expect(out.count == 1)
        #expect(out[0].speaker == nil)
        #expect(out[0].text == "een twee drie.")
        #expect(out[0].start == 0)
        #expect(out[0].end == 1.5)
    }

    @Test func turnsCoalesceConsecutiveSameSpeaker() {
        let words = [
            w(0.0, 0.5, "Hallo", "Spreker 1"),
            w(0.5, 1.0, "daar.", "Spreker 1"),
            w(1.2, 1.7, "Dank", "Spreker 2"),
            w(1.7, 2.2, "je.", "Spreker 2"),
            w(2.4, 2.9, "Graag.", "Spreker 1"),
        ]
        let out = SegmentGrouping.speakerTurns(from: words)
        #expect(out.count == 3)
        #expect(out[0].speaker == "Spreker 1")
        #expect(out[0].text == "Hallo daar.")
        #expect(out[1].speaker == "Spreker 2")
        #expect(out[1].text == "Dank je.")
        #expect(out[2].speaker == "Spreker 1")
        #expect(out[2].text == "Graag.")
    }

    @Test func turnsLeadingNilAttachesToFollowingTurn() {
        // Mirrors the real dev-DB shape: a leading run of nil words before
        // diarization locks on, then Spreker 1. The nil words join Spreker 1's
        // turn (not a separate nil turn).
        let words = [
            w(0.0, 0.4, "maken"),
            w(0.4, 0.8, "de"),
            w(0.8, 1.2, "moeite.", "Spreker 1"),
            w(1.3, 1.7, "Ja.", "Spreker 1"),
        ]
        let out = SegmentGrouping.speakerTurns(from: words)
        #expect(out.count == 1)
        #expect(out[0].speaker == "Spreker 1")
        #expect(out[0].text == "maken de moeite. Ja.")
        #expect(out[0].start == 0.0)
    }

    @Test func turnsMidNilAttachesToPrecedingTurn() {
        // A nil word between two Spreker 1 words stays inside Spreker 1's turn.
        let words = [
            w(0.0, 0.4, "een", "Spreker 1"),
            w(0.4, 0.8, "tussen"),          // nil
            w(0.8, 1.2, "drie", "Spreker 1"),
            w(1.4, 1.8, "vier", "Spreker 2"),
        ]
        let out = SegmentGrouping.speakerTurns(from: words)
        #expect(out.count == 2)
        #expect(out[0].speaker == "Spreker 1")
        #expect(out[0].text == "een tussen drie")
        #expect(out[1].speaker == "Spreker 2")
        #expect(out[1].text == "vier")
    }

    @Test func turnsNilBetweenDifferentSpeakersAttachesToPreceding() {
        // Spreker 1, then a nil bridge, then Spreker 2: the nil bridge attaches
        // to the preceding (Spreker 1) turn.
        let words = [
            w(0.0, 0.4, "een", "Spreker 1"),
            w(0.4, 0.8, "brug"),            // nil — should join Spreker 1
            w(0.8, 1.2, "twee", "Spreker 2"),
        ]
        let out = SegmentGrouping.speakerTurns(from: words)
        #expect(out.count == 2)
        #expect(out[0].speaker == "Spreker 1")
        #expect(out[0].text == "een brug")
        #expect(out[1].speaker == "Spreker 2")
        #expect(out[1].text == "twee")
    }

    @Test func turnsTrailingNilAttachesToPreceding() {
        let words = [
            w(0.0, 0.4, "een", "Spreker 1"),
            w(0.4, 0.8, "staart"),          // trailing nil
        ]
        let out = SegmentGrouping.speakerTurns(from: words)
        #expect(out.count == 1)
        #expect(out[0].speaker == "Spreker 1")
        #expect(out[0].text == "een staart")
    }

    @Test func turnsEndUpdatesToLastWord() {
        let words = [
            w(0.0, 0.4, "a", "Spreker 1"),
            w(0.4, 0.8, "b"),               // nil, joins Spreker 1
            w(0.8, 1.5, "c", "Spreker 1"),
        ]
        let out = SegmentGrouping.speakerTurns(from: words)
        #expect(out.count == 1)
        #expect(out[0].end == 1.5)
    }
}
