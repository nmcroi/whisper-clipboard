import Testing
import Foundation
@testable import Core

/// Exporter tests for the with-speaker rendering paths. The byte-parity of the
/// speaker-LESS paths is covered by the golden tests in `ExporterTests`; these
/// use hand-written expected strings for the new speaker-labelled output.
@Suite struct ExporterSpeakerTests {

    /// A two-speaker entry: two turns by Spreker 1, one interjection by Spreker 2,
    /// then Spreker 1 again — so grouping-per-turn is exercised.
    private func speakerEntry() -> TranscriptEntry {
        TranscriptEntry(
            id: "spk-1",
            text: "Goedemorgen allemaal. Fijn dat jullie er zijn. Dank je wel. Zullen we beginnen?",
            createdAt: "2026-06-20T22:42:00+02:00",
            name: "Interview",
            language: "nl",
            model: "parakeet-tdt-0.6b-v3",
            source: "file",
            duration: 8.0,
            segments: [
                TranscriptSegment(start: 0.0, end: 2.0, text: "Goedemorgen allemaal.", speaker: "Spreker 1"),
                TranscriptSegment(start: 2.0, end: 4.0, text: "Fijn dat jullie er zijn.", speaker: "Spreker 1"),
                TranscriptSegment(start: 4.0, end: 5.5, text: "Dank je wel.", speaker: "Spreker 2"),
                TranscriptSegment(start: 5.5, end: 8.0, text: "Zullen we beginnen?", speaker: "Spreker 1"),
            ]
        )
    }

    @Test func txtGroupsPerSpeakerTurn() {
        let expected =
            "Spreker 1: Goedemorgen allemaal. Fijn dat jullie er zijn.\n\n"
            + "Spreker 2: Dank je wel.\n\n"
            + "Spreker 1: Zullen we beginnen?\n"
        #expect(Exporter.toText(speakerEntry()) == expected)
    }

    @Test func markdownBoldSpeakerTurns() {
        let md = Exporter.toMarkdown(speakerEntry())
        #expect(md.hasPrefix("# Interview\n\n"))
        #expect(md.contains("**Spreker 1:** Goedemorgen allemaal. Fijn dat jullie er zijn."))
        #expect(md.contains("**Spreker 2:** Dank je wel."))
        #expect(md.contains("**Spreker 1:** Zullen we beginnen?"))
        #expect(md.hasSuffix("\n"))
    }

    @Test func srtPrefixesCueWithSpeaker() {
        let srt = Exporter.toSRT(speakerEntry())
        #expect(srt.hasPrefix("1\n00:00:00,000 --> 00:00:02,000\nSpreker 1: Goedemorgen allemaal.\n"))
        #expect(srt.contains("Spreker 2: Dank je wel."))
        // Four cues, one per segment.
        #expect(srt.contains("4\n"))
    }

    @Test func vttPrefixesCueWithSpeaker() {
        let vtt = Exporter.toVTT(speakerEntry())
        #expect(vtt.hasPrefix("WEBVTT\n"))
        #expect(vtt.contains("00:00:04.000 --> 00:00:05.500\nSpreker 2: Dank je wel."))
        #expect(vtt.contains("Spreker 1: Zullen we beginnen?"))
    }

    @Test func jsonIncludesSpeakerField() {
        let json = Exporter.toJSON(speakerEntry())
        #expect(json.contains("\"speaker\": \"Spreker 1\""))
        #expect(json.contains("\"speaker\": \"Spreker 2\""))
        // The text field still precedes speaker within a segment object.
        #expect(json.contains("\"text\": \"Dank je wel.\",\n      \"speaker\": \"Spreker 2\""))
    }

    // MARK: - Speaker rename map (display names)

    /// The same two-speaker entry, but with Spreker 1 renamed "Verkoper".
    private func renamedEntry() -> TranscriptEntry {
        var entry = speakerEntry()
        entry.speakerNames = ["Spreker 1": "Verkoper"]
        return entry
    }

    @Test func txtUsesRenamedSpeaker() {
        let expected =
            "Verkoper: Goedemorgen allemaal. Fijn dat jullie er zijn.\n\n"
            + "Spreker 2: Dank je wel.\n\n"
            + "Verkoper: Zullen we beginnen?\n"
        #expect(Exporter.toText(renamedEntry()) == expected)
    }

    @Test func markdownUsesRenamedSpeaker() {
        let md = Exporter.toMarkdown(renamedEntry())
        #expect(md.contains("**Verkoper:** Goedemorgen allemaal. Fijn dat jullie er zijn."))
        #expect(md.contains("**Spreker 2:** Dank je wel."))
        #expect(!md.contains("**Spreker 1:**"))
    }

    @Test func srtAndVttUseRenamedSpeaker() {
        let srt = Exporter.toSRT(renamedEntry())
        #expect(srt.contains("Verkoper: Goedemorgen allemaal."))
        #expect(!srt.contains("Spreker 1:"))
        let vtt = Exporter.toVTT(renamedEntry())
        #expect(vtt.contains("Verkoper: Zullen we beginnen?"))
    }

    @Test func jsonKeepsRawSpeakerLabelsNotDisplayNames() {
        // JSON is the machine format: it carries the raw diarization label, not
        // the user's rename (which is a UI/text-export concern).
        let json = Exporter.toJSON(renamedEntry())
        #expect(json.contains("\"speaker\": \"Spreker 1\""))
        #expect(!json.contains("Verkoper"))
    }

    @Test func emptyRenameMapIsByteIdenticalToNoMap() {
        // A present-but-empty map must not change any output.
        var entry = speakerEntry()
        entry.speakerNames = [:]
        #expect(Exporter.toText(entry) == Exporter.toText(speakerEntry()))
    }

    /// A mixed entry where some segments have a speaker and some do not: the
    /// speaker-less segments must still render (grouped under "Spreker ?" in
    /// txt/md, unprefixed in srt/vtt), and JSON omits the speaker key for them.
    @Test func mixedSpeakerAndNilSegments() {
        let entry = TranscriptEntry(
            id: "mixed",
            text: "Een. Twee.",
            createdAt: "2026-06-20T22:42:00+02:00",
            name: "Mixed",
            duration: 4.0,
            segments: [
                TranscriptSegment(start: 0, end: 2, text: "Een.", speaker: "Spreker 1"),
                TranscriptSegment(start: 2, end: 4, text: "Twee.", speaker: nil),
            ]
        )
        let json = Exporter.toJSON(entry)
        #expect(json.contains("\"text\": \"Een.\",\n      \"speaker\": \"Spreker 1\""))
        // The nil-speaker segment's object ends right after text (no speaker key).
        #expect(json.contains("\"text\": \"Twee.\"\n    }"))

        let srt = Exporter.toSRT(entry)
        #expect(srt.contains("Spreker 1: Een."))
        #expect(srt.contains("\nTwee.\n"))  // second cue unprefixed
    }
}
