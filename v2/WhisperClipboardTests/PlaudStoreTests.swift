import XCTest
@testable import WhisperClipboard

/// Tests for the shared `JSONIdentitySet` store extracted in finding #8, and the
/// PLAUD-specific stores that wrap it — proving the on-disk format is unchanged
/// (a sorted `[String]`) so no existing state is lost, plus the sync checkpoint.
final class PlaudStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plaud-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - JSONIdentitySet

    func testIdentitySetRoundTrips() {
        let url = tempDir.appendingPathComponent("ids.json")
        let store = JSONIdentitySet(filename: "ids.json", fileURL: url)
        store.save(["b", "a", "c"])
        XCTAssertEqual(store.load(), ["a", "b", "c"])
    }

    func testIdentitySetOnDiskFormatIsSortedArray() throws {
        let url = tempDir.appendingPathComponent("ids.json")
        JSONIdentitySet(filename: "ids.json", fileURL: url).save(["z", "a", "m"])
        // Exact on-disk bytes: a JSON array of strings, sorted ascending.
        let decoded = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded, ["a", "m", "z"])
    }

    func testIdentitySetReadsLegacyPlainArrayFile() throws {
        // A file written by the OLD store (a plain sorted [String]) still loads —
        // proving no state is lost by the extraction.
        let url = tempDir.appendingPathComponent("legacy.json")
        try Data(#"["id-1","id-2"]"#.utf8).write(to: url)
        XCTAssertEqual(JSONIdentitySet(filename: "legacy.json", fileURL: url).load(), ["id-1", "id-2"])
    }

    func testIdentitySetMissingFileIsEmpty() {
        let url = tempDir.appendingPathComponent("nope.json")
        XCTAssertTrue(JSONIdentitySet(filename: "nope.json", fileURL: url).load().isEmpty)
    }

    // MARK: - Filenames preserved (finding #8)

    func testProcessedStoreFilenamesAreUnchanged() {
        XCTAssertEqual(WatchedProcessedStore.filename, "watched-processed.json")
        XCTAssertEqual(PlaudProcessedStore.filename, "plaud-processed.json")
    }

    func testPlaudProcessedStoreRoundTrips() {
        let url = tempDir.appendingPathComponent("plaud-processed.json")
        let store = PlaudProcessedStore(fileURL: url)
        store.save(["rec-2", "rec-1"])
        XCTAssertEqual(store.load(), ["rec-1", "rec-2"])
    }

    func testWatchedProcessedStoreRoundTrips() {
        let url = tempDir.appendingPathComponent("watched-processed.json")
        let store = WatchedProcessedStore(fileURL: url)
        store.save(["x", "y"])
        XCTAssertEqual(store.load(), ["x", "y"])
    }

    // MARK: - Sync checkpoint

    func testCheckpointRoundTrips() {
        let url = tempDir.appendingPathComponent("plaud-last-sync.json")
        let cp = PlaudSyncCheckpoint(fileURL: url)
        XCTAssertNil(cp.load())

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        cp.save(date)
        XCTAssertEqual(cp.load()?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.5)
    }

    func testCheckpointFilename() {
        XCTAssertEqual(PlaudSyncCheckpoint.filename, "plaud-last-sync.json")
    }
}
