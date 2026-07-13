import Core
import Foundation

/// Synct de woordenlijst (find/replace-regels) tussen Mac en iPhone via de
/// iCloud key-value store — één JSON-payload onder één key, last-writer-wins
/// (zie `ReplacementSyncLogic` in Core voor de pure conflictlogica).
///
/// Volledig los van de CKSyncEngine-geschiedenis-sync: de KV-store heeft geen
/// CloudKit-schema of container-provisioning nodig, alleen het
/// `com.apple.developer.ubiquity-kvstore-identifier`-entitlement. Zonder dat
/// entitlement of zonder iCloud-account degradeert dit stil — anders dan
/// `CKContainer` trapt `NSUbiquitousKeyValueStore` nooit; hij werkt dan als
/// lokale opslag zonder propagatie.
///
/// Lus-preventie in drie lagen:
/// 1. Alleen payloads die strikt nieuwer zijn dan wat dit apparaat zelf het
///    laatst publiceerde/toepaste gaan naar ``onRemoteChange``
///    (`ReplacementSyncLogic.shouldApplyRemote`).
/// 2. De consument zet tijdens het toepassen een eigen "applyingRemote"-vlag
///    zodat zijn didSet niet opnieuw ``publish(_:)`` aanroept.
/// 3. De consument vergelijkt op gelijkheid voordat hij toekent.
@MainActor
public final class ReplacementsCloudSync {

    /// Een extern (van het andere apparaat) gewijzigde lijst. Alleen aangeroepen
    /// wanneer de remote payload strikt nieuwer is dan de lokale stand.
    public var onRemoteChange: (([Replacement]) -> Void)?

    private let store: NSUbiquitousKeyValueStore
    /// `updatedAt` van de laatst gepubliceerde óf toegepaste payload. Remote
    /// payloads die hier niet bovenuit komen (waaronder de echo van een eigen
    /// publish) worden genegeerd. De consument bewaart deze waarde en geeft hem
    /// bij de volgende start terug als `seedUpdatedAt`.
    public private(set) var localUpdatedAt: Double
    private var observer: NSObjectProtocol?

    public init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
        self.localUpdatedAt = 0
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Start de sync: leest de huidige cloud-waarde (en levert die via
    /// ``onRemoteChange`` af als hij nieuwer is dan `seedUpdatedAt`), registreert
    /// de externe-wijziging-observer en vraagt een synchronize aan.
    ///
    /// - Parameter seedUpdatedAt: de `updatedAt` van de lokaal bewaarde lijst
    ///   (0 wanneer er nog nooit iets bewaard is).
    public func start(seedUpdatedAt: Double) {
        localUpdatedAt = seedUpdatedAt

        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] note in
            // De notificatie komt op de main queue binnen; dit object is
            // @MainActor, dus assumeIsolated is hier terecht.
            MainActor.assumeIsolated {
                self?.handleExternalChange(note)
            }
        }

        // Haal de actuele cloud-stand op. synchronize() geeft false zonder
        // entitlement/account — dan blijft alles gewoon lokaal werken.
        store.synchronize()
        applyRemoteIfNewer()
    }

    /// Publiceert de lokale lijst na een bewerking. Zet `updatedAt` op nu en
    /// onthoudt die, zodat de eigen didChangeExternally-echo genegeerd wordt.
    /// Geeft de gestempelde `updatedAt` terug zodat de consument exact dezelfde
    /// waarde kan bewaren voor de seed bij de volgende start.
    @discardableResult
    public func publish(_ replacements: [Replacement]) -> Double {
        let now = Date()
        guard let data = ReplacementSyncLogic.encode(replacements, updatedAt: now) else {
            return localUpdatedAt
        }
        localUpdatedAt = now.timeIntervalSince1970
        store.set(data, forKey: ReplacementSyncLogic.kvKey)
        store.synchronize()
        return localUpdatedAt
    }

    // MARK: - Inkomend

    private func handleExternalChange(_ note: Notification) {
        // Alleen server-wijzigingen en initiële syncs zijn interessant;
        // quota/account-meldingen wijzigen de payload niet.
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        if let reason,
           reason != NSUbiquitousKeyValueStoreServerChange,
           reason != NSUbiquitousKeyValueStoreInitialSyncChange {
            return
        }
        if let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
           !keys.contains(ReplacementSyncLogic.kvKey) {
            return
        }
        applyRemoteIfNewer()
    }

    private func applyRemoteIfNewer() {
        guard let data = store.data(forKey: ReplacementSyncLogic.kvKey),
              let payload = ReplacementSyncLogic.decode(data),
              ReplacementSyncLogic.shouldApplyRemote(remote: payload, localUpdatedAt: localUpdatedAt)
        else { return }
        localUpdatedAt = payload.updatedAt
        onRemoteChange?(payload.replacements)
    }
}
