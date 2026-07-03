import Core
import XCTest
@testable import WhisperClipboard

// MARK: - Auto-export

@MainActor
final class AutoExportServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("wc_autoexport_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func entry(name: String = "Interview met Jan", text: String = "Hallo wereld") -> TranscriptEntry {
        TranscriptEntry(
            id: UUID().uuidString,
            text: text,
            createdAt: "2026-07-03T12:00:00+02:00",
            name: name,
            source: "mic",
            duration: 1.0
        )
    }

    /// A completed transcript produces the expected file at
    /// `<dir>/<suggested_name>.<fmt>`, with the format's writer content.
    func testExportsToExpectedPathAndFormat() {
        var settings = AppSettings()
        settings.autoExportEnabled = true
        settings.autoExportDirectory = tempDir.path
        settings.autoExportFormat = "md"

        let service = AutoExportService(
            settings: { settings },
            resolveBookmark: { _ in nil }, // force plain-path branch
            notify: { _ in }
        )
        let e = entry()
        service.exportIfEnabled(e)

        let expected = tempDir.appendingPathComponent("Interview-met-Jan.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                      "expected \(expected.path) to exist")
        let content = try? String(contentsOf: expected, encoding: .utf8)
        // Markdown writer emits a title header + the body.
        XCTAssertEqual(content, Exporter.toMarkdown(e))
    }

    /// The chosen format drives both the extension and the writer.
    func testFormatSelectionPicksSrtWriterAndExtension() {
        var settings = AppSettings()
        settings.autoExportEnabled = true
        settings.autoExportDirectory = tempDir.path
        settings.autoExportFormat = "srt"

        let service = AutoExportService(settings: { settings }, resolveBookmark: { _ in nil }, notify: { _ in })
        let e = entry()
        service.exportIfEnabled(e)

        let expected = tempDir.appendingPathComponent("Interview-met-Jan.srt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    /// An unknown/blank format falls back to markdown (matches settings default).
    func testUnknownFormatFallsBackToMarkdown() {
        var settings = AppSettings()
        settings.autoExportEnabled = true
        settings.autoExportDirectory = tempDir.path
        settings.autoExportFormat = "totally-bogus"

        let service = AutoExportService(settings: { settings }, resolveBookmark: { _ in nil }, notify: { _ in })
        service.exportIfEnabled(entry())

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Interview-met-Jan.md").path))
    }

    /// Disabled → nothing is written.
    func testDisabledWritesNothing() {
        var settings = AppSettings()
        settings.autoExportEnabled = false
        settings.autoExportDirectory = tempDir.path

        let service = AutoExportService(settings: { settings }, resolveBookmark: { _ in nil }, notify: { _ in })
        service.exportIfEnabled(entry())

        let contents = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(contents?.count, 0)
    }

    /// Enabled but no directory configured → nothing written, no crash.
    func testEnabledWithoutDirectoryWritesNothing() {
        var settings = AppSettings()
        settings.autoExportEnabled = true
        settings.autoExportDirectory = ""

        let service = AutoExportService(settings: { settings }, resolveBookmark: { _ in nil }, notify: { _ in })
        service.exportIfEnabled(entry()) // must not throw/crash
    }

    /// Two transcripts with the same suggested name don't overwrite each other:
    /// the second gets a "-2" suffix.
    func testCollisionGetsUniqueSuffix() {
        var settings = AppSettings()
        settings.autoExportEnabled = true
        settings.autoExportDirectory = tempDir.path
        settings.autoExportFormat = "txt"

        let service = AutoExportService(settings: { settings }, resolveBookmark: { _ in nil }, notify: { _ in })
        service.exportIfEnabled(entry(name: "Zelfde", text: "eerste"))
        service.exportIfEnabled(entry(name: "Zelfde", text: "tweede"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Zelfde.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Zelfde-2.txt").path))
    }

    /// A failure (unwritable destination) notifies at most once and never throws.
    func testUnwritableDestinationNotifiesOnceAndSurvives() {
        var settings = AppSettings()
        settings.autoExportEnabled = true
        // A path under a regular file cannot be created as a directory.
        let blocker = tempDir.appendingPathComponent("blocker")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        settings.autoExportDirectory = blocker.appendingPathComponent("nested").path
        settings.autoExportFormat = "txt"

        var notifications = 0
        let service = AutoExportService(settings: { settings }, resolveBookmark: { _ in nil }, notify: { _ in notifications += 1 })
        service.exportIfEnabled(entry())
        service.exportIfEnabled(entry())

        XCTAssertEqual(notifications, 1, "should nag at most once per run")
    }
}

// MARK: - Watched folder scanning + end-to-end decision

@MainActor
final class WatchedFolderServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("wc_watch_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeFile(_ name: String, bytes: Int) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    /// `scanDirectory` returns only supported media, with size + mtime, ignoring
    /// unsupported files and hidden entries.
    func testScanDirectoryReturnsSupportedMediaWithMetadata() throws {
        _ = try writeFile("a.wav", bytes: 128)
        _ = try writeFile("b.mp3", bytes: 64)
        _ = try writeFile("notes.txt", bytes: 10)      // unsupported
        _ = try writeFile(".hidden.wav", bytes: 10)    // hidden

        let scanned = WatchedFolderService.scanDirectory(tempDir.path)
        let names = Set(scanned.map { ($0.path as NSString).lastPathComponent })
        XCTAssertEqual(names, ["a.wav", "b.mp3"])
        let wav = scanned.first { ($0.path as NSString).lastPathComponent == "a.wav" }
        XCTAssertEqual(wav?.size, 128)
        XCTAssertGreaterThan(wav?.modifiedAt ?? 0, 0)
    }

    /// Scanning a nonexistent directory yields an empty result, not a crash.
    func testScanMissingDirectoryIsEmpty() {
        let scanned = WatchedFolderService.scanDirectory("/no/such/folder/here")
        XCTAssertTrue(scanned.isEmpty)
    }

    /// End-to-end over the real service + FS: a file present across two scans and
    /// stable in size is enqueued exactly once; a second tick does not re-enqueue.
    func testStableFileIsEnqueuedOnceAcrossTicks() throws {
        _ = try writeFile("clip.wav", bytes: 256)
        let folderPath = tempDir.path

        var enqueued: [[URL]] = []
        // Isolate the processed-store to a temp file so we don't touch real state.
        let store = WatchedProcessedStore(fileURL: tempDir.appendingPathComponent("processed.json"))
        let service = WatchedFolderService(
            foldersProvider: { [folderPath] },
            importer: { enqueued.append($0) },
            isBusy: { false },
            store: store
        )

        service.start()          // tick 1: seeds previous scan, nothing stable yet
        XCTAssertTrue(enqueued.isEmpty, "first tick should not enqueue a brand-new file")

        service.refresh()        // tick 2: file unchanged → stable → enqueue
        XCTAssertEqual(enqueued.count, 1)
        XCTAssertEqual(enqueued.first?.map { $0.lastPathComponent }, ["clip.wav"])

        service.refresh()        // tick 3: already processed → no re-enqueue
        XCTAssertEqual(enqueued.count, 1)

        service.stop()
    }

    /// A file still growing between the two scans is held back until it settles.
    func testGrowingFileIsNotEnqueuedUntilStable() throws {
        let url = try writeFile("partial.wav", bytes: 100)
        let folderPath = tempDir.path

        var enqueued: [[URL]] = []
        let store = WatchedProcessedStore(fileURL: tempDir.appendingPathComponent("processed.json"))
        let service = WatchedFolderService(
            foldersProvider: { [folderPath] },
            importer: { enqueued.append($0) },
            isBusy: { false },
            store: store
        )

        service.start()                       // tick 1: sees size 100
        try Data(count: 500).write(to: url)   // file grows before next tick
        service.refresh()                      // tick 2: size changed → skip
        XCTAssertTrue(enqueued.isEmpty)

        service.refresh()                      // tick 3: size 500 stable → enqueue
        XCTAssertEqual(enqueued.count, 1)
        service.stop()
    }

    /// When busy, files are not enqueued but remain eligible for a later tick.
    func testBusyGuardDefersEnqueue() throws {
        _ = try writeFile("clip.wav", bytes: 256)
        let folderPath = tempDir.path

        var enqueued: [[URL]] = []
        var busy = true
        let store = WatchedProcessedStore(fileURL: tempDir.appendingPathComponent("processed.json"))
        let service = WatchedFolderService(
            foldersProvider: { [folderPath] },
            importer: { enqueued.append($0) },
            isBusy: { busy },
            store: store
        )

        service.start()
        service.refresh()                 // stable but busy → deferred
        XCTAssertTrue(enqueued.isEmpty)

        busy = false
        service.refresh()                 // now free → enqueue
        XCTAssertEqual(enqueued.count, 1)
        service.stop()
    }

    /// The processed-set persists: a fresh service with the same store does not
    /// reprocess a file it already handed off (restart de-duplication).
    func testProcessedSetSurvivesRestart() throws {
        _ = try writeFile("clip.wav", bytes: 256)
        let folderPath = tempDir.path
        let storeURL = tempDir.appendingPathComponent("processed.json")

        var firstEnqueued: [[URL]] = []
        let store1 = WatchedProcessedStore(fileURL: storeURL)
        let service1 = WatchedFolderService(
            foldersProvider: { [folderPath] },
            importer: { firstEnqueued.append($0) },
            isBusy: { false },
            store: store1
        )
        service1.start()
        service1.refresh()
        XCTAssertEqual(firstEnqueued.count, 1)
        service1.stop()

        // "Restart": brand-new service reading the same persisted processed set.
        var secondEnqueued: [[URL]] = []
        let store2 = WatchedProcessedStore(fileURL: storeURL)
        let service2 = WatchedFolderService(
            foldersProvider: { [folderPath] },
            importer: { secondEnqueued.append($0) },
            isBusy: { false },
            store: store2
        )
        service2.start()
        service2.refresh()
        service2.refresh()
        XCTAssertTrue(secondEnqueued.isEmpty, "already-processed file must not be re-enqueued after restart")
        service2.stop()
    }
}

// MARK: - Automation bookmarks (path-key stability)

final class AutomationBookmarksKeyTests: XCTestCase {
    /// The per-watched-folder key is deterministic and distinct per path.
    func testWatchedKeyIsStableAndPerPath() {
        let k1 = AutomationBookmarks.watchedKey(forPath: "/Users/x/Inbox")
        let k1again = AutomationBookmarks.watchedKey(forPath: "/Users/x/Inbox")
        let k2 = AutomationBookmarks.watchedKey(forPath: "/Users/x/Other")
        XCTAssertEqual(k1, k1again)
        XCTAssertNotEqual(k1, k2)
        XCTAssertTrue(k1.hasPrefix("automation.watched.bookmark."))
    }
}
