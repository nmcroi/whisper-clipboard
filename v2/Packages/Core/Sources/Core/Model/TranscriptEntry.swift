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
    /// Per-transcript speaker rename map: raw diarization label ("Spreker 1") →
    /// user-chosen display name ("Autoverkoper"). Empty when the user has not
    /// renamed anyone. **Display/export only** — it is not part of the v3 JSON
    /// schema and is deliberately omitted from this type's `Codable` encoding so
    /// the golden export fixtures and v3 round-trip stay byte-identical; it is
    /// persisted separately in its own DB column.
    public var speakerNames: [String: String]

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
        segments: [TranscriptSegment] = [],
        speakerNames: [String: String] = [:]
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
        self.speakerNames = speakerNames
    }

    /// The display name for a raw speaker label, or the raw label itself when the
    /// user has not renamed it. E.g. `displayName(for: "Spreker 1")` → "Autoverkoper".
    public func displayName(forSpeaker rawSpeaker: String) -> String {
        let mapped = speakerNames[rawSpeaker]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mapped, !mapped.isEmpty { return mapped }
        return rawSpeaker
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
        // Not part of the v3 JSON schema: never decoded here, persisted separately.
        speakerNames = [:]
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
