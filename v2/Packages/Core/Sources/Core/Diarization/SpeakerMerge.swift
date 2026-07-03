import Foundation

/// A raw diarization turn: a time span attributed to one raw speaker id.
///
/// Kept free of any FluidAudio type so the merge logic below is a pure,
/// dependency-free, unit-testable function. The app layer maps FluidAudio's
/// `TimedSpeakerSegment` onto this before calling ``SpeakerMerge``.
public struct SpeakerTurn: Equatable, Sendable {
    public var start: Double
    public var end: Double
    /// Opaque raw speaker id from the diarizer (e.g. "S1", "Speaker_2").
    public var speakerId: String

    public init(start: Double, end: Double, speakerId: String) {
        self.start = start
        self.end = end
        self.speakerId = speakerId
    }
}

/// Pure merge of ASR transcript segments with diarization speaker turns.
///
/// For each transcript segment it picks the speaker whose turns have the most
/// temporal overlap with the segment, then renames the raw speaker ids to
/// human-readable "Spreker 1 / Spreker 2 / …" labels ordered by **first
/// appearance in the transcript** (not by raw id). Segments with no overlapping
/// turn keep `speaker == nil`.
public enum SpeakerMerge {

    /// Localized display-label prefix. Dutch UI: "Spreker".
    public static let speakerPrefix = "Spreker"

    /// Assigns a speaker label to each segment by maximum temporal overlap and
    /// renames raw ids to "Spreker N" ordered by first appearance.
    ///
    /// - Parameters:
    ///   - segments: ASR segments (start/end/text), typically in time order.
    ///   - turns: Diarization turns (may overlap, any order).
    /// - Returns: The segments with `speaker` populated where an overlapping
    ///   turn exists; segments with no overlap keep `speaker == nil`.
    public static func assign(
        segments: [TranscriptSegment],
        turns: [SpeakerTurn]
    ) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return segments }

        // First pass: resolve each segment's raw speaker id by max overlap.
        var rawIds: [String?] = []
        rawIds.reserveCapacity(segments.count)
        for segment in segments {
            rawIds.append(bestSpeaker(for: segment, turns: turns))
        }

        // Build the raw-id → "Spreker N" map, numbered by first appearance in
        // the transcript order (stable, human-intuitive).
        var labelForRaw: [String: String] = [:]
        var nextIndex = 1
        for rawId in rawIds {
            guard let rawId, labelForRaw[rawId] == nil else { continue }
            labelForRaw[rawId] = "\(speakerPrefix) \(nextIndex)"
            nextIndex += 1
        }

        // Second pass: apply labels.
        var result = segments
        for i in result.indices {
            if let rawId = rawIds[i] {
                result[i].speaker = labelForRaw[rawId]
            } else {
                result[i].speaker = nil
            }
        }
        return result
    }

    /// Raw speaker id with the greatest total overlap with `segment`, or nil
    /// when no turn overlaps it at all.
    private static func bestSpeaker(for segment: TranscriptSegment, turns: [SpeakerTurn]) -> String? {
        var overlapById: [String: Double] = [:]
        for turn in turns {
            let overlap = overlapDuration(
                aStart: segment.start, aEnd: segment.end,
                bStart: turn.start, bEnd: turn.end
            )
            if overlap > 0 {
                overlapById[turn.speakerId, default: 0] += overlap
            }
        }
        guard !overlapById.isEmpty else { return nil }
        // Max overlap wins; ties broken deterministically by raw id so the
        // result is stable regardless of turn ordering.
        return overlapById
            .max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key > rhs.key
            }?
            .key
    }

    /// Overlap in seconds between spans [aStart,aEnd] and [bStart,bEnd].
    private static func overlapDuration(
        aStart: Double, aEnd: Double, bStart: Double, bEnd: Double
    ) -> Double {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }
}
