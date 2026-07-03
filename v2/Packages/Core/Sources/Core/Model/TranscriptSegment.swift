import Foundation

/// A single timed segment of a transcript, mirroring the Python
/// `{"start": float, "end": float, "text": str}` segment dictionaries.
///
/// ## Speaker (optional, backward-compatible)
/// `speaker` carries a human-readable diarization label ("Spreker 1", …) when
/// speaker diarization ran on the source audio (file imports). It is optional
/// and **omitted from the encoded JSON when nil**, so existing history rows and
/// golden export fixtures — which have no speaker — round-trip byte-for-byte.
/// Decoding tolerates a missing `speaker` key (→ nil).
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    /// Diarization label, e.g. "Spreker 1". `nil` when no diarization was run.
    public var speaker: String?

    public init(start: Double, end: Double, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case text
        case speaker
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        text = try container.decode(String.self, forKey: .text)
        // Tolerant: missing key → nil.
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(text, forKey: .text)
        // Omit when nil so entries without speakers stay byte-identical to
        // their pre-diarization encoding (golden fixtures depend on this).
        try container.encodeIfPresent(speaker, forKey: .speaker)
    }
}
