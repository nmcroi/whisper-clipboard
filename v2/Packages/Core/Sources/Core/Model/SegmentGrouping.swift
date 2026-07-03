import Foundation

/// A speaker-attributed span of transcript text: one contiguous turn during
/// which a single speaker was talking. Purely derived from `[TranscriptSegment]`
/// for display and export — it never mutates the stored word-level data.
///
/// (Named `SpeakerTurn2` to avoid a clash with ``SpeakerTurn`` in
/// `Diarization/SpeakerMerge.swift`, which is a *raw diarizer* turn — a
/// different concept: that one carries an opaque `speakerId`, this one carries a
/// resolved display label and the joined text.)
public struct SpeakerTurn2: Equatable, Sendable {
    public var start: Double
    public var end: Double
    /// Resolved display label, e.g. "Spreker 1", or `nil` when the whole turn is
    /// unattributed (a single-speaker or no-diarization transcript).
    public var speaker: String?
    public var text: String

    public init(start: Double, end: Double, speaker: String?, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

/// Pure, dependency-free helpers that coalesce Parakeet's *word-level*
/// `[TranscriptSegment]` into readable units.
///
/// Parakeet emits one segment per word, so the raw list is unreadable one-word-
/// per-row and — for diarized imports — flickers a speaker chip on/off per word.
/// These functions derive sentence- and speaker-turn-level groupings for display
/// and export **without mutating the stored data**.
public enum SegmentGrouping {

    /// A time gap (seconds) between a word's end and the next word's start large
    /// enough to force a new sentence even without terminal punctuation. Real
    /// dictation/imports routinely show multi-second pauses between phrases.
    public static let sentenceGapThreshold: Double = 1.5

    // MARK: - Sentences

    /// Merges consecutive word segments into sentence-level segments.
    ///
    /// A sentence break is forced after a word whose text ends in sentence-final
    /// punctuation (`.`, `!`, `?`, optionally followed by a closing quote/bracket)
    /// or when the gap to the next word exceeds ``sentenceGapThreshold``.
    ///
    /// Each grouped segment spans `start` of its first word … `end` of its last,
    /// joins the word texts with single spaces, and carries a speaker when the
    /// grouped words agree on one (the majority label; any label present beats
    /// `nil`, so a sentence is attributed whenever possible).
    ///
    /// Empty / whitespace-only words are skipped. Empty input → empty output.
    public static func sentences(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let words = cleanedWords(segments)
        guard !words.isEmpty else { return [] }

        var result: [TranscriptSegment] = []
        var current: [TranscriptSegment] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            let speaker = majoritySpeaker(current)
            result.append(TranscriptSegment(start: first.start, end: last.end, text: text, speaker: speaker))
            current.removeAll(keepingCapacity: true)
        }

        for (index, word) in words.enumerated() {
            current.append(word)
            let endsSentence = Self.endsWithSentencePunctuation(word.text)
            let gapToNext: Bool
            if index + 1 < words.count {
                gapToNext = words[index + 1].start - word.end > sentenceGapThreshold
            } else {
                gapToNext = false
            }
            if endsSentence || gapToNext {
                flush()
            }
        }
        flush() // trailing words with no terminal punctuation
        return result
    }

    // MARK: - Speaker turns

    /// A maximal block of consecutive words sharing the same (possibly nil)
    /// speaker. Internal to turn-building.
    private struct Run {
        var speaker: String?
        var words: [TranscriptSegment]
    }

    /// Groups consecutive segments into speaker turns so a diarized transcript
    /// renders as "Spreker 1: <paragraph>", "Spreker 2: <paragraph>", … instead
    /// of one row per word.
    ///
    /// Consecutive same-speaker words merge into one turn; a speaker *change*
    /// starts a new turn. Words with a `nil` speaker attach to the surrounding
    /// turn rather than creating nil-gaps mid-turn:
    ///  - a leading run of `nil` words (before diarization locks on) attaches to
    ///    the first labelled turn that follows;
    ///  - `nil` words between/after labelled turns attach to the *preceding* turn;
    ///  - if there are no labelled words at all, the whole thing is one `nil` turn
    ///    (a single-speaker or non-diarized transcript).
    ///
    /// Text within a turn is joined with single spaces. Empty input → empty output.
    public static func speakerTurns(from segments: [TranscriptSegment]) -> [SpeakerTurn2] {
        let words = cleanedWords(segments)
        guard !words.isEmpty else { return [] }

        // Split into same-speaker runs.
        var runs: [Run] = []
        for word in words {
            if var last = runs.last, last.speaker == word.speaker {
                last.words.append(word)
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(speaker: word.speaker, words: [word]))
            }
        }

        // Resolve each nil run to an owning label: prefer the previous labelled
        // run; if none precedes (leading nil run), borrow the next labelled run's
        // label. With no labelled run anywhere, labels stay nil throughout.
        var resolved: [String?] = runs.map(\.speaker)
        for i in runs.indices where resolved[i] == nil {
            if let prev = lastNonNil(in: resolved, before: i) {
                resolved[i] = prev
            } else if let next = firstLabel(in: runs, after: i) {
                resolved[i] = next
            }
        }

        // Coalesce adjacent runs that now share a resolved label into turns.
        var turns: [SpeakerTurn2] = []
        for (i, run) in runs.enumerated() {
            let label = resolved[i]
            let text = run.words.map(\.text).joined(separator: " ")
            let end = run.words.last!.end
            if var last = turns.last, last.speaker == label {
                last.text += " " + text
                last.end = end
                turns[turns.count - 1] = last
            } else {
                turns.append(
                    SpeakerTurn2(start: run.words.first!.start, end: end, speaker: label, text: text)
                )
            }
        }
        return turns
    }

    // MARK: - Helpers

    /// Drops empty/whitespace-only words and trims each word's text.
    private static func cleanedWords(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.compactMap { seg in
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return TranscriptSegment(start: seg.start, end: seg.end, text: trimmed, speaker: seg.speaker)
        }
    }

    /// The most common non-nil speaker among `words`, or `nil` when none carry a
    /// label. Ties are broken by first appearance so the result is stable.
    private static func majoritySpeaker(_ words: [TranscriptSegment]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for word in words {
            guard let s = word.speaker, !s.isEmpty else { continue }
            if counts[s] == nil { order.append(s) }
            counts[s, default: 0] += 1
        }
        guard !counts.isEmpty else { return nil }
        return order.max { a, b in
            let ca = counts[a] ?? 0, cb = counts[b] ?? 0
            if ca != cb { return ca < cb }
            // Tie → earlier first-appearance wins (treat earlier index as greater).
            return (order.firstIndex(of: a) ?? 0) > (order.firstIndex(of: b) ?? 0)
        }
    }

    /// Terminal-punctuation test: after stripping trailing closing quotes /
    /// brackets and whitespace, the final character is `.`, `!`, or `?`. A bare
    /// comma does NOT end a sentence.
    static func endsWithSentencePunctuation(_ text: String) -> Bool {
        var view = Substring(text)
        let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "}", "\u{00BB}"]
        while let last = view.last, closers.contains(last) || last.isWhitespace {
            view.removeLast()
        }
        guard let last = view.last else { return false }
        return last == "." || last == "!" || last == "?"
    }

    private static func lastNonNil(in labels: [String?], before index: Int) -> String? {
        var i = index - 1
        while i >= 0 {
            if let label = labels[i] { return label }
            i -= 1
        }
        return nil
    }

    private static func firstLabel(in runs: [Run], after index: Int) -> String? {
        var i = index + 1
        while i < runs.count {
            if let label = runs[i].speaker { return label }
            i += 1
        }
        return nil
    }
}
