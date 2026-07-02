import Foundation

/// Swift mirror of the Python `HistoryEntry` dataclass (v3 history.json schema).
///
/// `createdAt` is intentionally kept as the raw ISO-8601 `String` from the
/// JSON so that round-tripping through this type reproduces the exact
/// original string byte-for-byte (the Python side stores
/// `datetime.now().astimezone().isoformat(timespec="seconds")`, which can
/// carry a UTC offset that `Date` would otherwise normalize away).
public struct TranscriptEntry: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var createdAt: String
    public var name: String
    public var pinned: Bool
    public var language: String
    public var model: String
    public var source: String
    public var duration: Double
    public var segments: [TranscriptSegment]

    public init(
        id: String,
        text: String,
        createdAt: String,
        name: String = "",
        pinned: Bool = false,
        language: String = "",
        model: String = "",
        source: String = "mic",
        duration: Double = 0.0,
        segments: [TranscriptSegment] = []
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
    }

    /// Best-effort parse of `createdAt` as an ISO-8601 date, mirroring the
    /// Python `HistoryEntry.timestamp` property
    /// (`datetime.fromisoformat(self.created_at)`).
    public var timestamp: Date? {
        Self.parseISO8601(createdAt)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }
        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        return withoutFractional.date(from: string)
    }

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
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "mic"
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0.0
        segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(name, forKey: .name)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(language, forKey: .language)
        try container.encode(model, forKey: .model)
        try container.encode(source, forKey: .source)
        try container.encode(duration, forKey: .duration)
        try container.encode(segments, forKey: .segments)
    }
}
