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
/// Publiceren is gedebounced: de woordenlijst-editors vuren per toetsaanslag,
/// maar pas na een korte rustperiode gaat de lijst echt de cloud in (met de
/// LWW-timestamp van dát moment). Sluit de app binnen dat venster, dan is er
/// niets kwijt — de lijst staat lokaal al bewaard en de eerstvolgende
/// bewerking publiceert opnieuw.
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
    private let defaults: UserDefaults
    /// UserDefaults-key waaronder dit component zelf `localUpdatedAt` bewaart,
    /// als seed voor de volgende start (per platform een eigen key).
    private let updatedAtKey: String

    /// `updatedAt` van de laatst gepubliceerde óf toegepaste payload. Remote
    /// payloads die hier niet bovenuit komen (waaronder de echo van een eigen
    /// publish) worden genegeerd.
    public private(set) var localUpdatedAt: Double = 0

    /// De didChangeExternally-observer. Bewust nooit verwijderd: beide
    /// consumenten (AppEnvironment op de Mac, AppModel op iOS) leven zo lang
    /// als het app-proces, dus dit object ook.
    private var observer: NSObjectProtocol?

    /// Rustperiode voordat een bewerking echt gepubliceerd wordt.
    private static let debounceSeconds: Double = 1.0
    private var pendingReplacements: [Replacement]?
    private var pendingPublish: Task<Void, Never>?

    public init(
        updatedAtKey: String,
        store: NSUbiquitousKeyValueStore = .default,
        defaults: UserDefaults = .standard
    ) {
        self.updatedAtKey = updatedAtKey
        self.store = store
        self.defaults = defaults
    }

    /// Start de sync: leest de eigen seed uit UserDefaults, registreert de
    /// externe-wijziging-observer, vraagt een synchronize aan en levert een
    /// nieuwere cloud-lijst direct af via ``onRemoteChange``.
    public func start() {
        localUpdatedAt = defaults.double(forKey: updatedAtKey)

        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] note in
            // Pak de (Sendable) waarden uit de notificatie VÓÓR de actor-hop —
            // de Notification zelf is niet Sendable en mag de MainActor niet in.
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            // De notificatie komt op de main queue binnen; dit object is
            // @MainActor, dus assumeIsolated is hier terecht.
            MainActor.assumeIsolated {
                self?.handleExternalChange(reason: reason, keys: keys)
            }
        }

        // Haal de actuele cloud-stand op. synchronize() geeft false zonder
        // entitlement/account — dan blijft alles gewoon lokaal werken.
        store.synchronize()
        applyRemoteIfNewer()
    }

    /// Meldt een lokale bewerking aan voor publicatie. Gedebounced: de laatste
    /// aangemelde lijst gaat pas na ``debounceSeconds`` rust echt de store in,
    /// met de LWW-timestamp van dat flush-moment.
    public func publish(_ replacements: [Replacement]) {
        pendingReplacements = replacements
        pendingPublish?.cancel()
        pendingPublish = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.debounceSeconds))
            guard !Task.isCancelled else { return }
            self?.flushPendingPublish()
        }
    }

    private func flushPendingPublish() {
        pendingPublish = nil
        guard let replacements = pendingReplacements else { return }
        pendingReplacements = nil

        let now = Date()
        guard let data = ReplacementSyncLogic.encode(replacements, updatedAt: now) else { return }
        localUpdatedAt = now.timeIntervalSince1970
        defaults.set(localUpdatedAt, forKey: updatedAtKey)
        store.set(data, forKey: ReplacementSyncLogic.kvKey)
        store.synchronize()
    }

    // MARK: - Inkomend

    private func handleExternalChange(reason: Int?, keys: [String]?) {
        // Alleen server-wijzigingen en initiële syncs zijn interessant;
        // quota/account-meldingen wijzigen de payload niet.
        if let reason,
           reason != NSUbiquitousKeyValueStoreServerChange,
           reason != NSUbiquitousKeyValueStoreInitialSyncChange {
            return
        }
        if let keys, !keys.contains(ReplacementSyncLogic.kvKey) {
            return
        }
        applyRemoteIfNewer()
    }

    private func applyRemoteIfNewer() {
        // Een lokale bewerking die op de debounce wacht is per definitie de
        // nieuwste stand op dit apparaat: laat de remote dan links liggen —
        // de flush stempelt zo een nieuwere timestamp en wint via LWW.
        guard pendingPublish == nil else { return }
        guard let data = store.data(forKey: ReplacementSyncLogic.kvKey),
              let payload = ReplacementSyncLogic.decode(data),
              ReplacementSyncLogic.shouldApplyRemote(remote: payload, localUpdatedAt: localUpdatedAt)
        else { return }
        localUpdatedAt = payload.updatedAt
        defaults.set(localUpdatedAt, forKey: updatedAtKey)
        onRemoteChange?(payload.replacements)
    }
}
