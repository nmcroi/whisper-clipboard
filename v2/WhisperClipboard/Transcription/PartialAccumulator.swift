import Core
import Foundation

/// Pure accumulation logic for streaming transcription results, factored out of
/// ``AppleSpeechEngine`` so it can be unit-tested without any Speech framework
/// or audio hardware.
///
/// The Speech API delivers a sequence of results, each either *volatile*
/// (a best-guess tail that will be revised) or *final* (locked in). Finalized
/// results are appended to the running transcript; the latest volatile result
/// is held separately as the dimmed tail.
struct PartialAccumulator: Equatable {
    /// Locked-in finalized segments, in order.
    private(set) var segments: [Core.TranscriptSegment] = []
    /// The current volatile tail (revised on every volatile result).
    private(set) var volatileText: String = ""

    /// Finalized text, segments joined with single spaces and tidied.
    var finalizedText: String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A snapshot for the HUD stream.
    var partial: StreamingPartial {
        StreamingPartial(
            finalizedText: finalizedText,
            volatileText: volatileText.isEmpty ? "" : leadingSpace + volatileText
        )
    }

    private var leadingSpace: String {
        segments.isEmpty ? "" : " "
    }

    /// Records a finalized result: appends the segment and clears the volatile tail.
    mutating func appendFinal(text: String, start: Double, end: Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        volatileText = ""
        guard !trimmed.isEmpty else { return }
        segments.append(Core.TranscriptSegment(start: start, end: end, text: trimmed))
    }

    /// Records the current volatile tail, replacing any previous one.
    mutating func setVolatile(text: String) {
        volatileText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The finished result once the stream ends.
    var result: TranscriptionResult {
        TranscriptionResult(text: finalizedText, segments: segments)
    }
}
