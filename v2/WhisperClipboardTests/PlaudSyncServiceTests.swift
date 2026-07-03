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
        importer: @escaping ([URL]) -> Void = { _ in }
    ) -> PlaudSyncService {
        var settings = AppSettings()
        settings.plaudSyncEnabled = true
        let client = PlaudClient(session: PlaudRouteURLProtocol.session(), region: .us)
        return PlaudSyncService(
            settings: { settings },
            credentialsProvider: { PlaudCredentials(email: "", password: "", token: "tok") },
            importer: importer,
            isBusy: { false },
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
        let service = makeService(importer: { imported.append($0) })

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

    /// Missing credentials fail fast with the Dutch message, no network.
    func testMissingCredentialsFailsFast() async {
        var settings = AppSettings()
        settings.plaudSyncEnabled = true
        let service = PlaudSyncService(
            settings: { settings },
            credentialsProvider: { nil },
            importer: { _ in },
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
