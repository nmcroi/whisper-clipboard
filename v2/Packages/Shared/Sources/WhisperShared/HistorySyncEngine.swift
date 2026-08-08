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
    private let accountBinding: HistorySyncAccountBinding
    private let seedLedger: HistorySyncSeedLedger
    private let stateURL: URL
    /// Yields the live "iCloud sync enabled" setting each time it's read.
    private let isEnabled: () -> Bool

    /// The live CloudKit sync engine — nil until `start()` succeeds (and while
    /// dormant). All CloudKit access funnels through here.
    private var engine: CKSyncEngine?
    /// Journal token captured when a record/delete is materialized for a send.
    /// A later local mutation replaces the journal token and therefore cannot be
    /// cleared by the older send's success event.
    private var inFlightJournalTokens: [CKRecord.ID: (journalKey: String, token: String)] = [:]
    /// Server versions returned with a conflict. A retry must preserve their
    /// change tag; creating a brand-new CKRecord would conflict forever.
    private var conflictRetryRecords: [CKRecord.ID: CKRecord] = [:]
    /// The container identifier the apps register in their entitlements.
    public static let containerIdentifier = "iCloud.nl.nielscroiset.whisperclipboard"

    /// - Parameters:
    ///   - store: the history store to observe (outbound) and apply into (inbound).
    ///   - isEnabled: reads `AppSettings.icloudSyncEnabled` live.
    /// Sync sidecars default to build-variant-specific names. Callers normally
    /// leave these defaults alone; explicit names are useful for isolated tests.
    public init(
        store: HistoryStore,
        isEnabled: @escaping () -> Bool,
        containerIdentifier: String = HistorySyncEngine.containerIdentifier,
        stateFilename: String = HistorySyncStorage.stateFilename,
        pendingFilename: String = HistorySyncStorage.pendingFilename,
        accountFilename: String = HistorySyncStorage.accountFilename,
        seedFilename: String = HistorySyncStorage.seedFilename
    ) {
        self.store = store
        self.isEnabled = isEnabled
        self.containerIdentifier = containerIdentifier
        self.journal = HistoryPendingJournal(filename: pendingFilename)
        self.accountBinding = HistorySyncAccountBinding(filename: accountFilename)
        self.seedLedger = HistorySyncSeedLedger(filename: seedFilename)
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

        guard engine == nil else {
            status = .active(lastSync: nil)
            return
        }

        // Resolve the actual private-database owner before constructing the sync
        // engine. This is a read-only preflight and prevents a local database
        // from being silently uploaded after an iCloud account switch.
        guard let currentUser = await currentUserRecordName() else { return }
        let localCount = localSyncItemCount()
        if let approvedUser = accountBinding.userRecordName() {
            guard approvedUser == currentUser else {
                status = .requiresApproval(localCount: localCount, accountChanged: true)
                return
            }
        } else if localCount > 0 {
            status = .requiresApproval(localCount: localCount, accountChanged: false)
            return
        } else if !accountBinding.bind(to: currentUser) {
            status = .error(message: "Kon de iCloud-accountkoppeling niet veilig bewaren")
            return
        }

        startApprovedEngine(for: currentUser)
    }

    /// Explicitly approves merging the complete local database with the iCloud
    /// account that is signed in at the moment of confirmation. No stored or
    /// previously-observed account id is trusted without checking again.
    public func approveCurrentAccountMerge() async {
        guard isEnabled() else {
            status = .disabled
            return
        }
        guard let currentUser = await currentUserRecordName() else { return }
        guard accountBinding.bind(to: currentUser) else {
            status = .error(message: "Kon de iCloud-accountkoppeling niet veilig bewaren")
            return
        }
        engine = nil
        startApprovedEngine(for: currentUser)
    }

    private func startApprovedEngine(for currentUser: String) {
        guard engine == nil else { return }
        guard seedLocalHistoryIfNeeded(for: currentUser) else { return }

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
            .saveZone(CKRecordZone(zoneName: TranscriptCloudRecord.zoneName)),
            .saveZone(CKRecordZone(zoneName: NoteCloudRecord.zoneName))
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
            if journal.pendingItems().isEmpty {
                status = .active(lastSync: Date())
            } else {
                if case .error = status {
                    // Keep the specific error reported by the delegate event.
                } else {
                    status = .error(message: "Niet alle wijzigingen konden naar iCloud worden gestuurd")
                }
            }
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

    /// Returns the current account's opaque record name after the entitlement
    /// and account-status checks. `userRecordID()` is a read-only CloudKit call.
    private func currentUserRecordName() async -> String? {
        guard await accountIsAvailable() else { return nil }
        do {
            return try await container().userRecordID().recordName
        } catch {
            NSLog("HistorySyncEngine: user identity unavailable (%@)", String(describing: error))
            status = .unavailable(reason: "iCloud-account kon niet worden vastgesteld")
            return nil
        }
    }

    /// Whether the running binary carries the CloudKit container in its code-sign
    /// entitlements. This is the guard that keeps unentitled builds dormant:
    /// constructing a `CKContainer` for a container the app isn't entitled to
    /// ABORTS the process (uncatchable), so we must confirm the entitlement first.
    ///
    /// On **macOS** we read the entitlement off the current task via the Security
    /// framework (`SecTask*`), which is precise and non-trapping — this correctly
    /// returns false for ad-hoc dev builds, CI, and the test host.
    ///
    /// On **iOS** the `SecTask*` entitlement SPIs are not in the public SDK, so we
    /// read `com.apple.developer.icloud-container-identifiers` from the embedded
    /// provisioning profile instead. Dev and TestFlight builds always embed
    /// `embedded.mobileprovision`; a build signed WITHOUT the iCloud container (the
    /// wifi test builds, whose App ID has no iCloud capability yet) carries a
    /// profile that doesn't list the container, so this returns false and the
    /// engine stays dormant instead of trapping in `CKContainer(identifier:)`.
    /// An App Store build has no embedded profile → we assume entitled, since
    /// Apple guarantees the signed entitlements match the App ID. This matches
    /// every signing path this project uses: we either sign with the real iCloud
    /// entitlements against an iCloud-enabled App ID (→ profile lists it → true),
    /// or without them against a plain App ID (→ absent → false).
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
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            // No embedded profile (App Store build) → trust the signed entitlements.
            return true
        }
        guard let ids = Self.icloudContainerIDs(fromProfile: data) else { return false }
        return ids.contains(containerIdentifier)
        #endif
    }

    #if !os(macOS)
    /// Extracts `icloud-container-identifiers` from a `.mobileprovision`. The file
    /// is CMS-signed, but the profile plist sits as plain XML between the `<plist>`
    /// tags — we slice that out and parse it (no CMS decoding needed).
    private static func icloudContainerIDs(fromProfile data: Data) -> [String]? {
        guard let start = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else { return nil }
        let plistData = data[start.lowerBound..<end.upperBound]
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any]
        else { return nil }
        return entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
    }
    #endif

    // MARK: - Outbound

    private func enqueueOutbound(_ change: HistoryChange) {
        guard journal.append(change) else {
            status = .error(message: "Kon een lokale wijziging niet veilig klaarzetten voor iCloud")
            return
        }
        guard let engine else { return }
        addPending(change, to: engine)
    }

    private func addPending(_ change: HistoryChange, to engine: CKSyncEngine) {
        let zoneID = CKRecordZone.ID(zoneName: change.zoneName)
        let recordID = CKRecord.ID(recordName: change.id, zoneID: zoneID)
        switch change {
        case .upsert, .noteUpsert:
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        case .delete, .noteDelete:
            engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        }
    }

    /// Adds every pre-existing local row to the durable journal once per approved
    /// account. The marker is only written after every journal append succeeded.
    private func seedLocalHistoryIfNeeded(for userRecordName: String) -> Bool {
        let seedKey = "\(userRecordName)|transcripts-and-notes-v1"
        guard !seedLedger.contains(seedKey) else { return true }
        let transcriptIDs: [String]
        let noteIDs: [String]
        do {
            transcriptIDs = try store.allRecordIDs()
            noteIDs = try store.allNoteRecordIDs()
        } catch {
            status = .error(message: "Kon lokale geschiedenis niet voorbereiden: \(error.localizedDescription)")
            return false
        }

        for id in transcriptIDs {
            guard journal.append(.upsert(id: id)) else {
                status = .error(message: "Kon de eerste synchronisatie niet veilig voorbereiden")
                return false
            }
        }
        for id in noteIDs {
            guard journal.append(.noteUpsert(id: id)) else {
                status = .error(message: "Kon bestaande notities niet veilig voorbereiden")
                return false
            }
        }
        guard seedLedger.markSeeded(seedKey) else {
            status = .error(message: "Kon de eerste synchronisatie niet veilig markeren")
            return false
        }
        return true
    }

    /// Feeds the durable journal's pending ops into the live engine. Entries stay
    /// journaled until CloudKit confirms each save/delete, so a crash after an
    /// engine-state update cannot lose unsent local changes.
    private func replayJournal() {
        let pendingItems = journal.pendingItems()
        guard !pendingItems.isEmpty, let engine else { return }
        for item in pendingItems {
            addPending(item.change, to: engine)
        }
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
            // bevinding 2026-08-03: een mislukte lokale schrijfactie werd stil
            // ingeslikt en daarna als geslaagde sync gemeld. Nu wordt hij als
            // foutstatus getoond in plaats van "gesynchroniseerd".
            if let failure = applyFetched(changes, syncEngine: syncEngine) {
                status = .error(
                    message: "Kon iCloud-wijzigingen niet lokaal opslaan: \(failure.localizedDescription)"
                )
            } else if journal.pendingItems().isEmpty {
                status = .active(lastSync: Date())
            }

        case .sentRecordZoneChanges(let sent):
            handleSent(sent)
            if sent.failedRecordSaves.isEmpty,
               sent.failedRecordDeletes.isEmpty,
               journal.pendingItems().isEmpty {
                status = .active(lastSync: Date())
            } else {
                let firstError = sent.failedRecordSaves.first?.error
                    ?? sent.failedRecordDeletes.values.first
                status = .error(
                    message: firstError?.localizedDescription
                        ?? "Niet alle wijzigingen konden naar iCloud worden gestuurd"
                )
            }

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

        let journalItems = Dictionary(
            uniqueKeysWithValues: journal.pendingItems().map { ($0.change.journalKey, $0) }
        )

        // Materialize every to-be-saved row up front on the main actor, so the
        // (non-isolated) batch-builder closure only reads from a captured, plain
        // dictionary. Rows that vanished locally are pruned from the pending set.
        var records: [CKRecord.ID: CKRecord] = [:]
        for change in changes {
            let recordID: CKRecord.ID
            let isNote = recordIDZoneName(change) == NoteCloudRecord.zoneName
            let expectedJournalChange: HistoryChange
            switch change {
            case .saveRecord(let id):
                recordID = id
                expectedJournalChange = isNote ? .noteUpsert(id: id.recordName) : .upsert(id: id.recordName)
            case .deleteRecord(let id):
                recordID = id
                expectedJournalChange = isNote ? .noteDelete(id: id.recordName) : .delete(id: id.recordName)
            @unknown default:
                continue
            }
            if let item = journalItems[expectedJournalChange.journalKey], item.change == expectedJournalChange {
                inFlightJournalTokens[recordID] = (item.change.journalKey, item.token)
            }

            guard case .saveRecord = change else { continue }
            if isNote, let local = try? store.noteRecord(id: recordID.recordName) {
                let ck = conflictRetryRecords[recordID]
                    ?? CKRecord(recordType: NoteCloudRecord.recordType, recordID: recordID)
                NoteCloudRecord.apply(local, to: ck)
                records[recordID] = ck
            } else if !isNote, let local = try? store.record(id: recordID.recordName) {
                let ck = conflictRetryRecords[recordID]
                    ?? CKRecord(recordType: TranscriptCloudRecord.recordType, recordID: recordID)
                TranscriptCloudRecord.apply(local, to: ck)
                records[recordID] = ck
            } else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                // The row no longer exists and no matching delete survived in
                // the journal, so this stale save can never be materialized.
                if let item = inFlightJournalTokens.removeValue(forKey: recordID) {
                    journal.clear(journalKey: item.journalKey, token: item.token)
                }
            }
        }

        let materialized = records
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            materialized[recordID]
        }
    }

    // MARK: Inbound application

    /// Past opgehaalde records lokaal toe. Geeft de eerste mislukte schrijfactie
    /// terug, zodat de aanroeper geen schone sync meldt.
    ///
    /// bevinding 2026-08-03: de lokale schrijfactie gebeurt nu VÓÓR
    /// `discardPendingLocalChange`, en de lokale wijziging wordt alleen
    /// losgelaten als het schrijven écht lukte. Andersom hield de rij bij een
    /// fout zijn oude inhoud terwijl de lokale wijziging uit het journaal én uit
    /// de wachtrij verdween — die rij liep dan permanent uit de pas, want hij
    /// werd nooit meer verstuurd of opnieuw opgehaald. Alleen de volgorde en de
    /// foutafhandeling veranderen; de conflictafhandeling blijft gelijk.
    private func applyFetched(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) -> Error? {
        var firstFailure: Error?
        func recordFailure(_ error: Error, _ recordName: String) {
            NSLog(
                "HistorySyncEngine: applying fetched change failed for %@ (%@)",
                recordName, String(describing: error)
            )
            if firstFailure == nil { firstFailure = error }
        }

        for modification in changes.modifications {
            let ck = modification.record
            if ck.recordType == NoteCloudRecord.recordType {
                let remote = NoteCloudRecord.local(from: ck)
                let localUpsert = HistoryChange.noteUpsert(id: remote.id)
                if journal.pendingItem(journalKey: localUpsert.journalKey)?.change
                    == .noteDelete(id: remote.id) {
                    addPending(.noteDelete(id: remote.id), to: syncEngine)
                    continue
                }
                let localClock = (try? store.noteModifiedAt(ids: [remote.id]))?[remote.id]
                if NoteCloudRecord.resolve(
                    localModifiedAt: localClock,
                    remoteModifiedAt: remote.modifiedAtMillis
                ) == .takeRemote {
                    do {
                        try store.applyRemoteNoteUpsert(remote)
                        discardPendingLocalChange(for: localUpsert)
                    } catch {
                        recordFailure(error, remote.id)
                    }
                } else {
                    enqueueOutbound(localUpsert)
                }
            } else {
                let remote = TranscriptCloudRecord.local(from: ck)
                let localUpsert = HistoryChange.upsert(id: remote.id)
                if journal.pendingItem(journalKey: localUpsert.journalKey)?.change
                    == .delete(id: remote.id) {
                    addPending(.delete(id: remote.id), to: syncEngine)
                    continue
                }
                let localClock = (try? store.modifiedAt(ids: [remote.id]))?[remote.id]
                if TranscriptCloudRecord.resolve(
                    localModifiedAt: localClock,
                    remoteModifiedAt: remote.modifiedAt
                ) == .takeRemote {
                    do {
                        try store.applyRemoteUpsert(
                            remote,
                            includesNoteLink: TranscriptCloudRecord.carriesNoteLink(ck)
                        )
                        discardPendingLocalChange(for: localUpsert)
                    } catch {
                        recordFailure(error, remote.id)
                    }
                } else {
                    enqueueOutbound(localUpsert)
                }
            }
        }
        for deletion in changes.deletions {
            if deletion.recordID.zoneID.zoneName == NoteCloudRecord.zoneName {
                let upsert = HistoryChange.noteUpsert(id: deletion.recordID.recordName)
                let delete = HistoryChange.noteDelete(id: deletion.recordID.recordName)
                if journal.pendingItem(journalKey: upsert.journalKey)?.change == upsert {
                    addPending(upsert, to: syncEngine)
                } else {
                    do {
                        try store.applyRemoteNoteDelete(id: deletion.recordID.recordName)
                        discardPendingLocalChange(for: delete)
                    } catch {
                        recordFailure(error, deletion.recordID.recordName)
                    }
                }
            } else {
                let upsert = HistoryChange.upsert(id: deletion.recordID.recordName)
                let delete = HistoryChange.delete(id: deletion.recordID.recordName)
                if journal.pendingItem(journalKey: upsert.journalKey)?.change == upsert {
                    addPending(upsert, to: syncEngine)
                } else {
                    do {
                        try store.applyRemoteDelete(id: deletion.recordID.recordName)
                        discardPendingLocalChange(for: delete)
                    } catch {
                        recordFailure(error, deletion.recordID.recordName)
                    }
                }
            }
        }
        return firstFailure
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        // A journal entry is retired only after CloudKit confirms the operation.
        // Failed operations remain durable and can be replayed after relaunch.
        for record in sent.savedRecords {
            conflictRetryRecords.removeValue(forKey: record.recordID)
            acknowledgeJournalEntry(for: record.recordID)
        }
        for recordID in sent.deletedRecordIDs {
            acknowledgeJournalEntry(for: recordID)
        }
        for failed in sent.failedRecordSaves {
            inFlightJournalTokens.removeValue(forKey: failed.record.recordID)
        }
        for recordID in sent.failedRecordDeletes.keys {
            inFlightJournalTokens.removeValue(forKey: recordID)
        }

        // Resolve server conflicts on failed saves via last-writer-wins.
        for failed in sent.failedRecordSaves {
            let recordID = failed.record.recordID
            switch failed.error.code {
            case .serverRecordChanged:
                guard let serverRecord = failed.error.serverRecord else { break }
                if serverRecord.recordType == NoteCloudRecord.recordType {
                    let remote = NoteCloudRecord.local(from: serverRecord)
                    let localClock = (try? store.noteModifiedAt(ids: [remote.id]))?[remote.id]
                    if NoteCloudRecord.resolve(
                        localModifiedAt: localClock,
                        remoteModifiedAt: remote.modifiedAtMillis
                    ) == .takeRemote {
                        // bevinding 2026-08-03: eerst schrijven, pas daarna de
                        // lokale wijziging laten vallen. Mislukt het schrijven,
                        // dan blijft die wijziging staan en draait de
                        // conflictafhandeling bij een volgende poging opnieuw.
                        do {
                            try store.applyRemoteNoteUpsert(remote)
                            discardPendingLocalChange(for: .noteUpsert(id: remote.id))
                        } catch {
                            NSLog(
                                "HistorySyncEngine: applying server record failed for %@ (%@)",
                                remote.id, String(describing: error)
                            )
                        }
                    } else {
                        conflictRetryRecords[recordID] = serverRecord
                        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    }
                } else {
                    let remote = TranscriptCloudRecord.local(from: serverRecord)
                    let localClock = (try? store.modifiedAt(ids: [remote.id]))?[remote.id]
                    if TranscriptCloudRecord.resolve(
                        localModifiedAt: localClock,
                        remoteModifiedAt: remote.modifiedAt
                    ) == .takeRemote {
                        // bevinding 2026-08-03: zie hierboven — schrijven eerst,
                        // pas bij succes de lokale wijziging laten vallen.
                        do {
                            try store.applyRemoteUpsert(
                                remote,
                                includesNoteLink: TranscriptCloudRecord.carriesNoteLink(serverRecord)
                            )
                            discardPendingLocalChange(for: .upsert(id: remote.id))
                        } catch {
                            NSLog(
                                "HistorySyncEngine: applying server record failed for %@ (%@)",
                                remote.id, String(describing: error)
                            )
                        }
                    } else {
                        conflictRetryRecords[recordID] = serverRecord
                        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    }
                }
            case .zoneNotFound, .userDeletedZone:
                // Recreate the custom zone, then re-queue the save.
                engine?.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: recordID.zoneID))
                ])
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            default:
                NSLog("HistorySyncEngine: save failed for %@ (%@)", recordID.recordName, String(describing: failed.error))
            }
        }

        // A delete can conflict when the server record changed after our last
        // fetch. A local pending deletion is intentional, so retry it against
        // the current server state; transient failures stay in the journal.
        for (recordID, error) in sent.failedRecordDeletes {
            switch error.code {
            case .serverRecordChanged:
                engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            case .zoneNotFound, .userDeletedZone:
                engine?.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: recordID.zoneID))
                ])
                engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            default:
                NSLog("HistorySyncEngine: delete failed for %@ (%@)", recordID.recordName, String(describing: error))
            }
        }
    }

    private func acknowledgeJournalEntry(for recordID: CKRecord.ID) {
        guard let item = inFlightJournalTokens.removeValue(forKey: recordID) else { return }
        journal.clear(journalKey: item.journalKey, token: item.token)
    }

    /// Drops only the currently journaled mutation for this record and removes
    /// its matching pending engine operation. Used when an equal/newer remote
    /// value wins, so an obsolete local save cannot overwrite it later.
    private func discardPendingLocalChange(for change: HistoryChange) {
        guard let item = journal.pendingItem(journalKey: change.journalKey) else { return }
        let recordID = CKRecord.ID(
            recordName: change.id,
            zoneID: CKRecordZone.ID(zoneName: change.zoneName)
        )
        switch item.change {
        case .upsert, .noteUpsert:
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        case .delete, .noteDelete:
            engine?.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        }
        inFlightJournalTokens.removeValue(forKey: recordID)
        conflictRetryRecords.removeValue(forKey: recordID)
        journal.clear(journalKey: item.change.journalKey, token: item.token)
    }

    private func localSyncItemCount() -> Int {
        let transcriptCount = (try? store.allRecordIDs().count) ?? 0
        let noteCount = (try? store.allNoteRecordIDs().count) ?? 0
        return transcriptCount + noteCount
    }

    private func recordIDZoneName(_ change: CKSyncEngine.PendingRecordZoneChange) -> String {
        switch change {
        case .saveRecord(let id), .deleteRecord(let id): id.zoneID.zoneName
        @unknown default: ""
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signOut:
            // Keep local data and its binding, but drop the live engine. A later
            // sign-in is preflighted against that binding before any upload.
            engine = nil
            status = .unavailable(reason: "uitgelogd bij iCloud")

        case .switchAccounts(_, let currentUser):
            engine = nil
            let localCount = localSyncItemCount()
            let changed = accountBinding.userRecordName() != currentUser.recordName
            status = .requiresApproval(localCount: localCount, accountChanged: changed)

        case .signIn(let currentUser):
            if accountBinding.userRecordName() == currentUser.recordName {
                status = .active(lastSync: nil)
            } else {
                engine = nil
                let localCount = localSyncItemCount()
                status = .requiresApproval(
                    localCount: localCount,
                    accountChanged: accountBinding.userRecordName() != nil
                )
            }
        @unknown default:
            break
        }
    }
}
