import Foundation

/// A single timed segment of a transcript, mirroring the Python
/// `{"start": float, "end": float, "text": str}` segment dictionaries.
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}
