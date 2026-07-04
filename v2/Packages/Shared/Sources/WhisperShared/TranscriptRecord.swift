import Core
import Foundation
import GRDB

/// GRDB persistence record for a row in the `transcripts` table. Bridges to and
/// from `Core.TranscriptEntry` (which stays a pure value type in the Core
/// package, free of any database dependency).
public struct TranscriptRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcripts"

    public var id: String
    public var text: String
    public var createdAt: String
    public var name: String
    public var pinned: Bool
    public var language: String
    public var model: String
    public var source: String
    public var duration: Double
    /// JSON-encoded `[TranscriptSegment]`.
    public var segments: String
    /// Epoch seconds derived from `createdAt` for fast newest-first ordering.
    public var sortKey: Double
    /// JSON-encoded `[String: String]` speaker rename map (raw label → name).
    public var speakerNames: String
    /// Last-writer-wins clock for iCloud sync (i2): milliseconds since the 1970
    /// epoch, bumped on every local mutation. Not part of `Core.TranscriptEntry`
    /// (a pure display value type) — it is sync metadata carried only at this
    /// persistence layer and on the CloudKit record.
    public var modifiedAt: Int64

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
        case speakerNames = "speaker_names"
        case modifiedAt = "modified_at"
    }

    /// Explicit field-by-field initializer. Declared in the main type (not an
    /// extension) so it *suppresses* the synthesized internal memberwise init and
    /// becomes the single public one. Used by the CloudKit mapping to build a
    /// record straight from a fetched `CKRecord`'s fields, carrying the remote
    /// `modifiedAt` and pre-computed `sortKey` through unchanged.
    public init(
        id: String,
        text: String,
        createdAt: String,
        name: String,
        pinned: Bool,
        language: String,
        model: String,
        source: String,
        duration: Double,
        segments: String,
        sortKey: Double,
        speakerNames: String,
        modifiedAt: Int64
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.name = name
        self.pinned = pinned
        self.language = language
        self.model = model
        self.source = source
        self.duration = duration
        self.segments = segments
        self.sortKey = sortKey
        self.speakerNames = speakerNames
        self.modifiedAt = modifiedAt
    }
}

extension TranscriptRecord {
    private static let segmentEncoder = JSONEncoder()
    private static let segmentDecoder = JSONDecoder()

    /// Current wall-clock time as milliseconds since the 1970 epoch — the unit of
    /// the `modified_at` last-writer-wins clock.
    public static func nowMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    /// Builds a record from a Core entry, encoding segments to JSON and deriving
    /// the sort key from the entry's timestamp (falling back to 0 when absent).
    ///
    /// - Parameter modifiedAt: the last-writer-wins clock in epoch milliseconds.
    ///   Defaults to "now" for locally-originated writes; the remote-apply path
    ///   passes the timestamp carried on the incoming CloudKit record so the LWW
    ///   comparison stays meaningful.
    public init(entry: TranscriptEntry, modifiedAt: Int64 = TranscriptRecord.nowMillis()) {
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
        if !entry.speakerNames.isEmpty,
           let data = try? Self.segmentEncoder.encode(entry.speakerNames),
           let json = String(data: data, encoding: .utf8) {
            self.speakerNames = json
        } else {
            self.speakerNames = "{}"
        }
        self.modifiedAt = modifiedAt
    }

    /// Reconstructs the Core entry, decoding the segments JSON.
    public var entry: TranscriptEntry {
        let decodedSegments: [TranscriptSegment]
        if let data = segments.data(using: .utf8),
           let parsed = try? Self.segmentDecoder.decode([TranscriptSegment].self, from: data) {
            decodedSegments = parsed
        } else {
            decodedSegments = []
        }
        let decodedNames: [String: String]
        if let data = speakerNames.data(using: .utf8),
           let parsed = try? Self.segmentDecoder.decode([String: String].self, from: data) {
            decodedNames = parsed
        } else {
            decodedNames = [:]
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
            segments: decodedSegments,
            speakerNames: decodedNames
        )
    }
}
