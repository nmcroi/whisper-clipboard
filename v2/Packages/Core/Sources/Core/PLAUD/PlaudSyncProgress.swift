import Foundation

/// Taalneutrale toestand van een handmatige PLAUD-sync.
///
/// De UI bewaart deze toestand in plaats van een al vertaalde zin. Daardoor kan
/// dezelfde voortgang onmiddellijk opnieuw worden weergegeven wanneer de
/// gebruiker de interfacetaal wijzigt.
public enum PlaudSyncProgress: Equatable, Sendable {
    case notSynced
    case stopped
    case fetching
    case downloading(current: Int, total: Int)
    case transcribing(current: Int, total: Int)
    case upToDate
    case imported(Int)
    case failure(PlaudSyncFailure)

    public var localizationKey: String {
        switch self {
        case .notSynced:
            "Nog niet gesynchroniseerd"
        case .stopped:
            "Gestopt"
        case .fetching:
            "PLAUD-opnamen ophalen…"
        case .downloading:
            "Opname %1$lld van %2$lld downloaden…"
        case .transcribing:
            "Opname %1$lld van %2$lld transcriberen…"
        case .upToDate:
            "Alles is bijgewerkt"
        case .imported(1):
            "1 nieuwe PLAUD-opname toegevoegd"
        case .imported:
            "%lld nieuwe PLAUD-opnamen toegevoegd"
        case .failure(let failure):
            failure.localizationKey
        }
    }

    public var integerArguments: [Int64] {
        switch self {
        case .downloading(let current, let total), .transcribing(let current, let total):
            [Int64(current), Int64(total)]
        case .imported(let count) where count != 1:
            [Int64(count)]
        default:
            []
        }
    }

    public var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

public enum PlaudSyncFailure: Equatable, Sendable {
    case historyUnavailable
    case accountMissing
    case credentialsMissing
    case authenticationFailed(String)
    case network
    case rateLimited
    case unexpectedResponse(String)
    case server(String)
    case syncFailed

    public var localizationKey: String {
        switch self {
        case .historyUnavailable:
            "De geschiedenis kon niet worden geopend."
        case .accountMissing:
            "Stel eerst je PLAUD-account in."
        case .credentialsMissing:
            "Stel eerst je PLAUD e-mailadres en wachtwoord in bij Instellingen."
        case .authenticationFailed(let detail):
            detail.isEmpty
                ? "Inloggen bij PLAUD mislukte. Controleer je e-mailadres en wachtwoord."
                : "Inloggen bij PLAUD mislukte: %@"
        case .network:
            "Geen verbinding met PLAUD. Controleer je internetverbinding."
        case .rateLimited:
            "PLAUD beperkt het aantal aanvragen. Probeer het over een moment opnieuw."
        case .unexpectedResponse(let detail):
            detail.isEmpty
                ? "Onverwacht antwoord van PLAUD. Mogelijk is hun API gewijzigd."
                : "Onverwacht antwoord van PLAUD: %@"
        case .server(let detail):
            detail.isEmpty
                ? "Er ging iets mis bij het benaderen van PLAUD."
                : "PLAUD gaf een fout: %@"
        case .syncFailed:
            "PLAUD-synchronisatie mislukt."
        }
    }

    public var detail: String? {
        switch self {
        case .authenticationFailed(let detail),
             .unexpectedResponse(let detail),
             .server(let detail):
            detail.isEmpty ? nil : detail
        default:
            nil
        }
    }
}
