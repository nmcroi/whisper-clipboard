import Foundation
import GRDB

/// Een doorlopende, benoemde notitie (iPhone i2). Je start een notitie ("Vakantie"),
/// dicteert wat, en kunt er over uren/dagen aan blijven toevoegen: elke nieuwe
/// opname wordt als transcript-rij met `note_id` aan deze notitie gehangen en
/// achteraan de tekst samengevoegd.
///
/// Bewust een simpel, plat value type — géén afhankelijkheid van `Core`. De
/// sync-laag bewaart de metadata als een apart CloudKit-record; de inhoud blijft
/// bestaan uit de gekoppelde transcript-rijen.
public struct Note: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// Raw ISO-8601 string, consistent met `TranscriptEntry.createdAt`.
    public var createdAt: String
    /// Raw ISO-8601 string van de laatste wijziging (titel of nieuwe opname).
    public var modifiedAt: String

    public init(id: String, title: String, createdAt: String, modifiedAt: String) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Best-effort parse van `modifiedAt` als datum (voor relatieve weergave).
    public var modifiedDate: Date? { Self.parseISO8601(modifiedAt) }

    /// Best-effort parse van `createdAt` als datum.
    public var createdDate: Date? { Self.parseISO8601(createdAt) }

    private static func parseISO8601(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

/// GRDB persistence record voor een rij in de `notes`-tabel. Bridget naar/van
/// het `Note` value type.
public struct NoteRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "notes"

    public var id: String
    public var title: String
    public var createdAt: String
    public var modifiedAt: String
    /// Epoch-seconden afgeleid van `modifiedAt` voor snelle "laatst gewijzigd"-sortering.
    public var sortKey: Double

    public var modifiedAtMillis: Int64 {
        Int64((sortKey * 1000).rounded())
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case sortKey = "sort_key"
    }

    public init(id: String, title: String, createdAt: String, modifiedAt: String, sortKey: Double) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.sortKey = sortKey
    }

    public init(note: Note) {
        self.id = note.id
        self.title = note.title
        self.createdAt = note.createdAt
        self.modifiedAt = note.modifiedAt
        self.sortKey = Self.sortKey(for: note.modifiedAt)
    }

    public var note: Note {
        Note(id: id, title: title, createdAt: createdAt, modifiedAt: modifiedAt)
    }

    public static func sortKey(for iso8601: String) -> Double {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: iso8601) { return date.timeIntervalSince1970 }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso8601)?.timeIntervalSince1970 ?? 0
    }
}
