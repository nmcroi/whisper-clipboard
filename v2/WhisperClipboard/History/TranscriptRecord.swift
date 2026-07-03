import Core
import Foundation
import GRDB

/// GRDB persistence record for a row in the `transcripts` table. Bridges to and
/// from `Core.TranscriptEntry` (which stays a pure value type in the Core
/// package, free of any database dependency).
struct TranscriptRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcripts"

    var id: String
    var text: String
    var createdAt: String
    var name: String
    var pinned: Bool
    var language: String
    var model: String
    var source: String
    var duration: Double
    /// JSON-encoded `[TranscriptSegment]`.
    var segments: String
    /// Epoch seconds derived from `createdAt` for fast newest-first ordering.
    var sortKey: Double

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case createdAt = "created_at"
        case name
        case pinned
        case language
        case model
        case source
        case duration
        case segments
        case sortKey = "sort_key"
    }
}

extension TranscriptRecord {
    private static let segmentEncoder = JSONEncoder()
    private static let segmentDecoder = JSONDecoder()

    /// Builds a record from a Core entry, encoding segments to JSON and deriving
    /// the sort key from the entry's timestamp (falling back to 0 when absent).
    init(entry: TranscriptEntry) {
        self.id = entry.id
        self.text = entry.text
        self.createdAt = entry.createdAt
        self.name = entry.name
        self.pinned = entry.pinned
        self.language = entry.language
        self.model = entry.model
        self.source = entry.source
        self.duration = entry.duration
        if let data = try? Self.segmentEncoder.encode(entry.segments),
           let json = String(data: data, encoding: .utf8) {
            self.segments = json
        } else {
            self.segments = "[]"
        }
        self.sortKey = entry.timestamp?.timeIntervalSince1970 ?? 0
    }

    /// Reconstructs the Core entry, decoding the segments JSON.
    var entry: TranscriptEntry {
        let decodedSegments: [TranscriptSegment]
        if let data = segments.data(using: .utf8),
           let parsed = try? Self.segmentDecoder.decode([TranscriptSegment].self, from: data) {
            decodedSegments = parsed
        } else {
            decodedSegments = []
        }
        return TranscriptEntry(
            id: id,
            text: text,
            createdAt: createdAt,
            name: name,
            pinned: pinned,
            language: language,
            model: model,
            source: source,
            duration: duration,
            segments: decodedSegments
        )
    }
}
