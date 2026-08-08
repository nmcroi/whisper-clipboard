import Foundation

/// User-facing state of iCloud history sync, surfaced in Settings on both
/// platforms. Deliberately small and `Sendable` so the UI can observe it.
public enum SyncStatus: Equatable, Sendable {
    /// Sync is turned off by the user (the toggle).
    case disabled
    /// iCloud is unavailable: no account signed in, or the build has no CloudKit
    /// entitlement (ad-hoc dev builds, CI). Sync stays dormant, quietly.
    case unavailable(reason: String)
    /// Local history exists but this database variant has not yet been approved
    /// to merge with the currently signed-in iCloud account.
    case requiresApproval(localCount: Int, accountChanged: Bool)
    /// Sync is active. `lastSync` is the last successful exchange, if any.
    case active(lastSync: Date?)
    /// A transient error surfaced from the engine; sync keeps retrying.
    case error(message: String)

    /// A Dutch one-line label for the status row.
    public var dutchLabel: String {
        switch self {
        case .disabled:
            return "Uitgeschakeld"
        case .unavailable:
            return "iCloud niet beschikbaar"
        case .requiresApproval(let localCount, let accountChanged):
            if accountChanged {
                return "Gepauzeerd — ander iCloud-account"
            }
            return "Wacht op toestemming voor \(localCount) lokale items"
        case .active(let lastSync):
            guard let lastSync else { return "Actief" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "nl_NL")
            f.dateStyle = .none
            f.timeStyle = .short
            return "Actief — laatst gesynchroniseerd om \(f.string(from: lastSync))"
        case .error(let message):
            return "Fout: \(message)"
        }
    }
}
