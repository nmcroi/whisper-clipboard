import Foundation

/// De payload zoals de woordenlijst in de iCloud key-value store staat: één
/// key met JSON. De lijst is klein (handvol regels), dus hij synct als geheel —
/// last-writer-wins op de hele lijst, geen per-regel-merge.
public struct ReplacementsPayload: Codable, Equatable, Sendable {
    /// Formaatversie, voor toekomstige migraties. Nu altijd 1.
    public var version: Int
    /// Epoch-seconden van de laatste bewerking op het publicerende apparaat.
    public var updatedAt: Double
    public var replacements: [Replacement]

    public init(version: Int = 1, updatedAt: Double, replacements: [Replacement]) {
        self.version = version
        self.updatedAt = updatedAt
        self.replacements = replacements
    }
}

/// Pure codeer- en conflictlogica voor de woordenlijst-sync tussen Mac en
/// iPhone. Bewust zonder NSUbiquitousKeyValueStore-afhankelijkheid: dat
/// OS-koppelstuk zit in WhisperShared (`ReplacementsCloudSync`); alles hier is
/// plat Foundation en draait dus ook in de Linux-CI-tests.
public enum ReplacementSyncLogic {

    /// De key in de iCloud key-value store.
    public static let kvKey = "replacements.v1"

    /// Codeert de lijst als payload-JSON voor de KV-store.
    public static func encode(_ replacements: [Replacement], updatedAt: Date) -> Data? {
        let payload = ReplacementsPayload(
            updatedAt: updatedAt.timeIntervalSince1970,
            replacements: replacements
        )
        return try? JSONEncoder().encode(payload)
    }

    /// Decodeert een payload; `nil` bij onleesbare of corrupte data (dan geldt
    /// de payload als afwezig en wint de lokale lijst vanzelf).
    public static func decode(_ data: Data) -> ReplacementsPayload? {
        try? JSONDecoder().decode(ReplacementsPayload.self, from: data)
    }

    /// Last-writer-wins over de hele lijst. Bij exact gelijke timestamps wint
    /// de langste lijst — bewuste tie-break: bij twijfel nooit stilletjes
    /// regels kwijtraken.
    public static func resolve(
        local: ReplacementsPayload?,
        remote: ReplacementsPayload?
    ) -> ReplacementsPayload? {
        switch (local, remote) {
        case (nil, nil): return nil
        case (let l?, nil): return l
        case (nil, let r?): return r
        case (let l?, let r?):
            if l.updatedAt != r.updatedAt {
                return l.updatedAt > r.updatedAt ? l : r
            }
            return l.replacements.count >= r.replacements.count ? l : r
        }
    }

    /// True wanneer een extern binnengekomen payload strikt nieuwer is dan wat
    /// dit apparaat zelf het laatst publiceerde of toepaste — alleen dan hoort
    /// hij lokaal toegepast te worden. "Strikt" voorkomt dat de echo van een
    /// eigen publish opnieuw wordt toegepast (sync-lus).
    public static func shouldApplyRemote(
        remote: ReplacementsPayload,
        localUpdatedAt: Double
    ) -> Bool {
        remote.updatedAt > localUpdatedAt
    }
}
