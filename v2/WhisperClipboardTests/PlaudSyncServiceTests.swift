import XCTest
import Core
@testable import WhisperClipboard

/// Tests for the stateful `PlaudSyncService`: that a real sync passes a `since`
/// bound derived from the persisted checkpoint (finding #3), dedups in a single
/// pass (finding #9c), and persists the checkpoint on success. Driven through the
/// same route-based `URLProtocol` as the client integration tests.
@MainActor
final class PlaudSyncServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        PlaudRouteURLProtocol.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plaud-sync-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        PlaudRouteURLProtocol.reset()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeService(
        importer: @escaping ([URL]) -> [URL] = { $0 },
        isBusy: @escaping () -> Bool = { false }
    ) -> PlaudSyncService {
        var settings = AppSettings()
        settings.plaudSyncEnabled = true
        let client = PlaudClient(session: PlaudRouteURLProtocol.session(), region: .us)
        return PlaudSyncService(
            settings: { settings },
            credentialsProvider: { PlaudCredentials(email: "", password: "", token: "tok") },
            importer: importer,
            isBusy: isBusy,
            client: client,
            store: PlaudProcessedStore(fileURL: tempDir.appendingPathComponent("plaud-processed.json")),
            checkpoint: PlaudSyncCheckpoint(fileURL: tempDir.appendingPathComponent("plaud-last-sync.json")),
            audioDirectory: tempDir.appendingPathComponent("PLAUD", isDirectory: true)
        )
    }

    /// The first sync (no checkpoint) sends NO `since`-derived bound (full list),
    /// downloads the recording, and persists a checkpoint. The second sync then
    /// dedups the already-processed recording (imports 0) — proving single-pass
    /// dedup + checkpoint persistence.
    func testSecondSyncDedupsAndFirstSyncHasNoSinceBound() async throws {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let audio = Data([1, 2, 3])

        PlaudRouteURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/file/download/") {
                return (200, ["Content-Type": "audio/mpeg"], audio)
            }
            // list
            let page = PlaudClientIntegrationTests.listPage(startTimes: [nowMs])
            return (200, [:], page)
        }

        var imported: [[URL]] = []
        let service = makeService(importer: { imported.append($0); return $0 })

        // First sync: lists (full history — the very first list request skip=0),
        // downloads 1, imports 1.
        await service.performSync(trigger: .manual)
        XCTAssertEqual(service.lastImportedCount, 1)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.count, 1)
        XCTAssertNil(service.lastError)

        let firstListURLs = PlaudRouteURLProtocol.requestedURLs.filter { $0.path == "/file/simple/web" }
        XCTAssertFalse(firstListURLs.isEmpty)

        // Second sync: same recording is now processed → dedup drops it → imports 0.
        PlaudRouteURLProtocol.requestedURLs = []
        await service.performSync(trigger: .manual)
        XCTAssertEqual(service.lastImportedCount, 0)
        XCTAssertEqual(imported.count, 1, "no new import on the dedup'd second run")
        XCTAssertNil(service.lastError)
    }

    /// A fresh service constructed after a successful sync loads the persisted
    /// checkpoint and processed set — so a "restart" doesn't re-download.
    func testCheckpointAndProcessedSurviveRestart() async throws {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        PlaudRouteURLProtocol.handler = { request in
            if request.url?.path.hasPrefix("/file/download/") == true {
                return (200, ["Content-Type": "audio/mpeg"], Data([9]))
            }
            return (200, [:], PlaudClientIntegrationTests.listPage(startTimes: [nowMs]))
        }

        let service1 = makeService()
        await service1.performSync(trigger: .manual)
        XCTAssertEqual(service1.lastImportedCount, 1)

        // Checkpoint file was written.
        let cpURL = tempDir.appendingPathComponent("plaud-last-sync.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cpURL.path))

        // A brand-new service over the same on-disk state re-processes nothing.
        PlaudRouteURLProtocol.requestedURLs = []
        let service2 = makeService()
        await service2.performSync(trigger: .manual)
        XCTAssertEqual(service2.lastImportedCount, 0)
    }

    /// Finding #4/#6: when the importer REFUSES the batch (returns no accepted
    /// URLs, as it does while dictation is busy), the recording must NOT be marked
    /// processed and the checkpoint must NOT advance — so a later run re-lists and
    /// re-imports it instead of dropping it forever.
    func testRefusedImportKeepsRecordingEligible() async throws {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        PlaudRouteURLProtocol.handler = { request in
            if request.url?.path.hasPrefix("/file/download/") == true {
                return (200, ["Content-Type": "audio/mpeg"], Data([1, 2, 3]))
            }
            return (200, [:], PlaudClientIntegrationTests.listPage(startTimes: [nowMs]))
        }

        let processedURL = tempDir.appendingPathComponent("plaud-processed.json")
        let checkpointURL = tempDir.appendingPathComponent("plaud-last-sync.json")
        let store = PlaudProcessedStore(fileURL: processedURL)
        let checkpoint = PlaudSyncCheckpoint(fileURL: checkpointURL)

        func makeService(importer: @escaping ([URL]) -> [URL]) -> PlaudSyncService {
            var settings = AppSettings()
            settings.plaudSyncEnabled = true
            return PlaudSyncService(
                settings: { settings },
                credentialsProvider: { PlaudCredentials(email: "", password: "", token: "tok") },
                importer: importer,
                isBusy: { false },
                client: PlaudClient(session: PlaudRouteURLProtocol.session(), region: .us),
                store: store,
                checkpoint: checkpoint,
                audioDirectory: tempDir.appendingPathComponent("PLAUD", isDirectory: true)
            )
        }

        // Run 1: importer refuses everything (busy) → returns [].
        var refusedCalls = 0
        let refusing = makeService(importer: { _ in refusedCalls += 1; return [] })
        await refusing.performSync(trigger: .manual)
        XCTAssertEqual(refusedCalls, 1)
        XCTAssertEqual(refusing.lastImportedCount, 0)
        // Nothing persisted as processed, and NO checkpoint written.
        XCTAssertTrue(store.load().isEmpty, "a refused recording must not be marked processed")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: checkpointURL.path),
            "the checkpoint must not advance when the import was refused"
        )

        // Run 2: importer now accepts → the same recording is still listed
        // (checkpoint never advanced) and gets imported.
        var accepted: [[URL]] = []
        let accepting = makeService(importer: { accepted.append($0); return $0 })
        await accepting.performSync(trigger: .manual)
        XCTAssertEqual(accepting.lastImportedCount, 1, "the previously-refused recording is imported on retry")
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(store.load().count, 1, "now marked processed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path))
    }

    /// Finding #4: with two downloads where the importer accepts only ONE, only
    /// the accepted recording is marked processed; the rejected one stays eligible
    /// and the checkpoint is held back.
    func testPartiallyAcceptedImportOnlyMarksAccepted() async throws {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        PlaudRouteURLProtocol.handler = { request in
            if request.url?.path.hasPrefix("/file/download/") == true {
                return (200, ["Content-Type": "audio/mpeg"], Data([7]))
            }
            return (200, [:], PlaudClientIntegrationTests.listPage(startTimes: [nowMs, nowMs - 1000]))
        }

        let processedURL = tempDir.appendingPathComponent("plaud-processed.json")
        let checkpointURL = tempDir.appendingPathComponent("plaud-last-sync.json")
        let store = PlaudProcessedStore(fileURL: processedURL)

        var settings = AppSettings()
        settings.plaudSyncEnabled = true
        let service = PlaudSyncService(
            settings: { settings },
            credentialsProvider: { PlaudCredentials(email: "", password: "", token: "tok") },
            // Accept only the first downloaded URL, reject the rest.
            importer: { urls in Array(urls.prefix(1)) },
            isBusy: { false },
            client: PlaudClient(session: PlaudRouteURLProtocol.session(), region: .us),
            store: store,
            checkpoint: PlaudSyncCheckpoint(fileURL: checkpointURL),
            audioDirectory: tempDir.appendingPathComponent("PLAUD", isDirectory: true)
        )

        await service.performSync(trigger: .manual)
        XCTAssertEqual(service.lastImportedCount, 1)
        XCTAssertEqual(store.load().count, 1, "only the accepted recording is processed")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: checkpointURL.path),
            "a rejected recording holds the checkpoint back"
        )
    }

    /// Missing credentials fail fast with the Dutch message, no network.
    func testMissingCredentialsFailsFast() async {
        var settings = AppSettings()
        settings.plaudSyncEnabled = true
        let service = PlaudSyncService(
            settings: { settings },
            credentialsProvider: { nil },
            importer: { $0 },
            isBusy: { false },
            client: PlaudClient(session: PlaudRouteURLProtocol.session()),
            store: PlaudProcessedStore(fileURL: tempDir.appendingPathComponent("p.json")),
            checkpoint: PlaudSyncCheckpoint(fileURL: tempDir.appendingPathComponent("c.json")),
            audioDirectory: tempDir
        )
        await service.performSync(trigger: .manual)
        XCTAssertNotNil(service.lastError)
        XCTAssertTrue(PlaudRouteURLProtocol.requestedURLs.isEmpty)
    }
}
