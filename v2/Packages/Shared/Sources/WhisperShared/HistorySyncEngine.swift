import CloudKit
import Core
import Foundation
import Observation
import Security

/// Drives two-way iCloud sync of the transcript history between the Mac app and
/// the iOS companion, using the modern `CKSyncEngine` on the user's PRIVATE
/// CloudKit database. One instance per app; construct it after the
/// `HistoryStore` exists and call ``start()`` once.
///
/// ## Graceful degradation (CRITICAL)
/// The engine is built to be a silent no-op whenever CloudKit isn't usable:
///   • no iCloud entitlement (ad-hoc dev builds, CI) → `CKContainer.accountStatus`
///     errors or reports `.couldNotDetermine`; the engine goes dormant.
///   • no iCloud account signed in → `.noAccount`; dormant.
///   • sync toggle off in settings → dormant.
/// In every dormant case the engine holds a descriptive ``SyncStatus`` the UI
/// can show and NEVER crashes or spams errors. All existing tests run without
/// iCloud and therefore never construct or exercise the live engine.
@MainActor
@Observable
public final class HistorySyncEngine: NSObject {

    /// The current user-facing status. Observed by both Settings screens.
    public private(set) var status: SyncStatus = .disabled

    private let containerIdentifier: String
    /// The CloudKit container — created LAZILY on first use inside `start()`,
    /// never in `init`. `CKContainer(identifier:)` traps for a container that is
    /// not in the app's entitlements (ad-hoc dev builds, CI, the test host), so
    /// we must not touch it until we have first confirmed an iCloud account is
    /// present (which an unentitled build never has → we return early before this
    /// is ever read).
    private var _container: CKContainer?
    private func container() -> CKContainer {
        if let c = _container { return c }
        let c = CKContainer(identifier: containerIdentifier)
        _container = c
        return c
    }

    private let store: HistoryStore
    private let journal: HistoryPendingJournal
    private let stateURL: URL
    /// Yields the live "iCloud sync enabled" setting each time it's read.
    private let isEnabled: () -> Bool

    /// The live CloudKit sync engine — nil until `start()` succeeds (and while
    /// dormant). All CloudKit access funnels through here.
    private var engine: CKSyncEngine?

    /// The container identifier the apps register in their entitlements.
    public static let containerIdentifier = "iCloud.nl.nielscroiset.whisperclipboard"

    /// - Parameters:
    ///   - store: the history store to observe (outbound) and apply into (inbound).
    ///   - isEnabled: reads `AppSettings.icloudSyncEnabled` live.
    ///   - stateFilename: the per-platform serialization file name (each app owns
    ///     its own so two platforms never clobber each other's engine state).
    public init(
        store: HistoryStore,
        isEnabled: @escaping () -> Bool,
        containerIdentifier: String = HistorySyncEngine.containerIdentifier,
        stateFilename: String = "sync-state.bin"
    ) {
        self.store = store
        self.isEnabled = isEnabled
        self.containerIdentifier = containerIdentifier
        self.journal = HistoryPendingJournal()
        self.stateURL = AppSupport.baseDirectory.appendingPathComponent(stateFilename, isDirectory: false)
        super.init()

        // Outbound hook: every local mutation records a pending op in the durable
        // journal AND, if the engine is live, is handed straight to it. The
        // journal is what makes offline / pre-start changes survive.
        store.onChange = { [weak self] change in
            self?.enqueueOutbound(change)
        }
    }

    // MARK: - Lifecycle

    /// Brings the engine up if sync is enabled and iCloud is available; otherwise
    /// sets a dormant status and returns. Safe to call more than once.
    public func start() async {
        guard isEnabled() else {
            status = .disabled
            return
        }
        // Check account availability first — this is where a build with no
        // CloudKit entitlement (ad-hoc dev / CI) fails, and we must go dormant
        // quietly rather than surface a crash or a noisy error.
        let available = await accountIsAvailable()
        guard available else { return } // status already set by accountIsAvailable()

        guard engine == nil else {
            status = .active(lastSync: nil)
            return
        }

        var config = CKSyncEngine.Configuration(
            database: container().privateCloudDatabase,
            stateSerialization: loadState(),
            delegate: self
        )
        config.automaticallySync = true
        let engine = CKSyncEngine(config)
        self.engine = engine
        status = .active(lastSync: nil)

        // Ensure the custom zone exists. Adding the same zone save when it is
        // already present is harmless — CloudKit treats it idempotently — so we
        // don't need to track "created" precisely across launches.
        engine.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneName: TranscriptCloudRecord.zoneName))
        ])

        // Replay any journaled pending ops (offline / pre-start changes) into the
        // freshly-started engine so nothing accumulated while dormant is lost.
        replayJournal()
    }

    /// Manual "Synchroniseer nu": kicks a fetch then a send. No-op when dormant.
    public func syncNow() async {
        guard let engine else {
            await start()
            return
        }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            status = .active(lastSync: Date())
        } catch {
            status = .error(message: error.localizedDescription)
        }
    }

    /// Call when the toggle changes. Enabling starts; disabling goes dormant
    /// (the engine reference is dropped; its serialized state stays on disk so a
    /// later re-enable resumes without a full refetch).
    public func settingChanged() async {
        if isEnabled() {
            await start()
        } else {
            engine = nil
            status = .disabled
        }
    }

    // MARK: - Availability

    /// Returns whether an iCloud account backed by a working CloudKit entitlement
    /// is available, setting `status` to a dormant value when not. Any thrown
    /// error (the usual symptom of a missing entitlement) is treated as
    /// "unavailable", never rethrown — dormancy must be silent.
    private func accountIsAvailable() async -> Bool {
        // Entitlement pre-check FIRST. `CKContainer(identifier:)` traps for a
        // container missing from the app's entitlements (ad-hoc dev, CI, the test
        // host), and a trap can't be caught — so we must confirm the entitlement
        // is present BEFORE ever touching CKContainer. This is the single guard
        // that keeps unentitled builds dormant instead of crashing.
        guard Self.hasCloudKitEntitlement(for: containerIdentifier) else {
            status = .unavailable(reason: "iCloud niet beschikbaar op deze build")
            return false
        }
        // Cheap local pre-check: no ubiquity token → definitely no usable account.
        if FileManager.default.ubiquityIdentityToken == nil {
            status = .unavailable(reason: "geen iCloud-account")
            return false
        }
        do {
            let accountStatus = try await container().accountStatus()
            switch accountStatus {
            case .available:
                return true
            case .noAccount:
                status = .unavailable(reason: "niet ingelogd bij iCloud")
                return false
            case .restricted:
                status = .unavailable(reason: "iCloud is beperkt op dit apparaat")
                return false
            case .couldNotDetermine, .temporarilyUnavailable:
                status = .unavailable(reason: "iCloud-status onbekend")
                return false
            @unknown default:
                status = .unavailable(reason: "iCloud niet beschikbaar")
                return false
            }
        } catch {
            // This is the ad-hoc-dev / no-entitlement path: accountStatus throws.
            NSLog("HistorySyncEngine: iCloud dormant (%@)", String(describing: error))
            status = .unavailable(reason: "iCloud niet beschikbaar op deze build")
            return false
        }
    }

    /// Whether the running binary carries the CloudKit container in its code-sign
    /// entitlements. This is the guard that keeps unentitled builds dormant:
    /// constructing a `CKContainer` for a container the app isn't entitled to
    /// ABORTS the process (uncatchable), so we must confirm the entitlement first.
    ///
    /// On **macOS** we read the entitlement straight off the running process's
    /// code signature via the Security framework (`SecTaskCreateFromSelf` /
    /// `SecTaskCopyValueForEntitlement`) — precise and non-trapping.
    ///
    /// On **iOS** those SecTask entitlement SPIs are not exposed in the public SDK
    /// (they don't compile there — confirmed by CI). Instead we probe the exact
    /// same entitlement via `FileManager.url(forUbiquityContainerIdentifier:)`: the
    /// `com.apple.developer.icloud-container-identifiers` key covers BOTH CloudKit
    /// containers and iCloud-Documents ubiquity containers, so this is testing the
    /// real, signed grant, not a proxy. It is an official, documented, always-safe
    /// Foundation API — returns nil whenever the app lacks the entitlement or
    /// iCloud is unavailable, and never traps. This directly fixes the original
    /// SIGTRAP: the previous iOS check read the embedded provisioning profile
    /// (what the App ID *may* have), not the real, signed grant.
    static func hasCloudKitEntitlement(for containerIdentifier: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let key = "com.apple.developer.icloud-container-identifiers" as CFString
        guard let value = SecTaskCopyValueForEntitlement(task, key, nil) else { return false }
        if let ids = value as? [String] {
            return ids.contains(containerIdentifier)
        }
        return false
        #else
        FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) != nil
        #endif
    }

    // MARK: - Outbound

    private func enqueueOutbound(_ change: HistoryChange) {
        journal.append(change)
        guard let engine else { return }
        let zoneID = CKRecordZone.ID(zoneName: TranscriptCloudRecord.zoneName)
        let recordID = CKRecord.ID(recordName: change.id, zoneID: zoneID)
        switch change {
        case .upsert:
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        case .delete:
            engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        }
    }

    /// Feeds the durable journal's pending ops into the live engine, then clears
    /// them (the engine's own state now owns them). Ordering is preserved.
    private func replayJournal() {
        let pending = journal.pending()
        guard !pending.isEmpty, engine != nil else { return }
        for change in pending {
            enqueueOutbound(change)
        }
        // enqueueOutbound re-appended each id to the journal, but it also handed
        // them to the engine; clear the journal now that the engine owns them.
        journal.clearAll()
    }

    // MARK: - State serialization

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func persistState(_ serialization: CKSyncEngine.State.Serialization) {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(serialization)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("HistorySyncEngine: failed to persist state (%@)", String(describing: error))
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension HistorySyncEngine: CKSyncEngineDelegate {

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            persistState(update.stateSerialization)

        case .accountChange(let change):
            handleAccountChange(change)

        case .fetchedRecordZoneChanges(let changes):
            applyFetched(changes)
            status = .active(lastSync: Date())

        case .sentRecordZoneChanges(let sent):
            handleSent(sent)
            status = .active(lastSync: Date())

        case .fetchedDatabaseChanges,
             .sentDatabaseChanges,
             .willFetchChanges, .didFetchChanges,
             .willSendChanges, .didSendChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    /// Provides the next batch of records to upload. Materializes each pending
    /// `saveRecord` from the current local row (so the freshest content ships).
    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }

        // Materialize every to-be-saved row up front on the main actor, so the
        // (non-isolated) batch-builder closure only reads from a captured, plain
        // dictionary. Rows that vanished locally are pruned from the pending set.
        var records: [CKRecord.ID: CKRecord] = [:]
        for change in changes {
            guard case .saveRecord(let recordID) = change else { continue }
            if let local = try? store.record(id: recordID.recordName) {
                let ck = CKRecord(recordType: TranscriptCloudRecord.recordType, recordID: recordID)
                TranscriptCloudRecord.apply(local, to: ck)
                records[recordID] = ck
            } else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            }
        }

        let materialized = records
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            materialized[recordID]
        }
    }

    // MARK: Inbound application

    private func applyFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        for modification in changes.modifications {
            let ck = modification.record
            let remote = TranscriptCloudRecord.local(from: ck)
            let localClock = (try? store.modifiedAt(ids: [remote.id]))?[remote.id]
            let resolution = TranscriptCloudRecord.resolve(
                localModifiedAt: localClock,
                remoteModifiedAt: remote.modifiedAt
            )
            switch resolution {
            case .takeRemote:
                try? store.applyRemoteUpsert(remote)
            case .keepLocal:
                // Our copy is newer: re-queue it so the server converges to us.
                let zoneID = CKRecordZone.ID(zoneName: TranscriptCloudRecord.zoneName)
                engine?.state.add(pendingRecordZoneChanges: [
                    .saveRecord(CKRecord.ID(recordName: remote.id, zoneID: zoneID))
                ])
            }
        }
        for deletion in changes.deletions {
            try? store.applyRemoteDelete(id: deletion.recordID.recordName)
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        // Resolve server conflicts on failed saves via last-writer-wins.
        for failed in sent.failedRecordSaves {
            let recordID = failed.record.recordID
            switch failed.error.code {
            case .serverRecordChanged:
                guard let serverRecord = failed.error.serverRecord else { break }
                let remote = TranscriptCloudRecord.local(from: serverRecord)
                let localClock = (try? store.modifiedAt(ids: [remote.id]))?[remote.id]
                let resolution = TranscriptCloudRecord.resolve(
                    localModifiedAt: localClock,
                    remoteModifiedAt: remote.modifiedAt
                )
                if resolution == .takeRemote {
                    try? store.applyRemoteUpsert(remote)
                } else {
                    // Keep local; resubmit against the server's change tag.
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                }
            case .zoneNotFound, .userDeletedZone:
                // Recreate the custom zone, then re-queue the save.
                engine?.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneName: TranscriptCloudRecord.zoneName))
                ])
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            default:
                NSLog("HistorySyncEngine: save failed for %@ (%@)", recordID.recordName, String(describing: failed.error))
            }
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signOut, .switchAccounts:
            // The account went away or changed: go dormant. Local history stays;
            // the serialized engine state is left on disk but a fresh account will
            // start clean.
            status = .unavailable(reason: "iCloud-account gewijzigd")
        case .signIn:
            Task { await start() }
        @unknown default:
            break
        }
    }
}
