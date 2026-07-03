import Testing
import Foundation
@testable import Core

@Suite struct WatchedFolderLogicTests {

    private typealias File = WatchedFolderLogic.ScannedFile

    private func file(_ path: String, size: Int64, mtime: Int64 = 1_000) -> File {
        File(path: path, size: size, modifiedAt: mtime)
    }

    // MARK: - Stability gating

    /// A file seen for the very first time (not in the previous scan) is held
    /// back one tick — we don't yet know it has finished copying.
    @Test func brandNewFileIsHeldBackOneTick() {
        let current = [file("/w/a.wav", size: 100)]
        let toEnqueue = WatchedFolderLogic.filesToEnqueue(
            currentScan: current,
            previousScan: [],
            processed: []
        )
        #expect(toEnqueue.isEmpty)
    }

    /// A file whose size is unchanged across the two most-recent scans is stable
    /// and gets enqueued.
    @Test func stableFileIsEnqueued() {
        let previous = [file("/w/a.wav", size: 100)]
        let current = [file("/w/a.wav", size: 100)]
        let toEnqueue = WatchedFolderLogic.filesToEnqueue(
            currentScan: current,
            previousScan: previous,
            processed: []
        )
        #expect(toEnqueue == current)
    }

    /// A file still growing (size changed since the previous scan) is a partial
    /// copy and must NOT be enqueued yet.
    @Test func growingFileIsSkipped() {
        let previous = [file("/w/a.wav", size: 100)]
        let current = [file("/w/a.wav", size: 250)]
        let toEnqueue = WatchedFolderLogic.filesToEnqueue(
            currentScan: current,
            previousScan: previous,
            processed: []
        )
        #expect(toEnqueue.isEmpty)
    }

    // MARK: - Processed-set gating

    /// A file already processed (same identity) is never re-enqueued, even when
    /// stable.
    @Test func alreadyProcessedFileIsSkipped() {
        let f = file("/w/a.wav", size: 100, mtime: 42)
        let toEnqueue = WatchedFolderLogic.filesToEnqueue(
            currentScan: [f],
            previousScan: [f],
            processed: [f.identity]
        )
        #expect(toEnqueue.isEmpty)
    }

    /// Replacing a processed file with new content (different size or mtime →
    /// different identity) makes it eligible again once stable.
    @Test func replacedFileWithNewIdentityIsEnqueuedAgain() {
        let old = file("/w/a.wav", size: 100, mtime: 42)
        // New content: same path, new size + mtime → new identity.
        let new = file("/w/a.wav", size: 500, mtime: 99)
        let toEnqueue = WatchedFolderLogic.filesToEnqueue(
            currentScan: [new],
            previousScan: [new],
            processed: [old.identity]
        )
        #expect(toEnqueue == [new])
    }

    // MARK: - Ordering & multiplicity

    /// Output preserves the current-scan order and only includes stable, unseen
    /// files (mixed batch).
    @Test func mixedBatchEnqueuesOnlyStableUnprocessedInOrder() {
        let stableA = file("/w/a.wav", size: 100)
        let growingB = file("/w/b.wav", size: 300)   // grew since prev
        let stableC = file("/w/c.wav", size: 50)
        let processedD = file("/w/d.wav", size: 10, mtime: 7)

        let previous = [
            stableA,
            file("/w/b.wav", size: 200), // b was smaller last tick
            stableC,
            processedD,
        ]
        let current = [stableA, growingB, stableC, processedD]

        let toEnqueue = WatchedFolderLogic.filesToEnqueue(
            currentScan: current,
            previousScan: previous,
            processed: [processedD.identity]
        )
        #expect(toEnqueue == [stableA, stableC])
    }

    /// Identity is path + mtime + size and is stable/deterministic.
    @Test func identityCombinesPathMtimeSize() {
        let f = file("/w/a.wav", size: 123, mtime: 456)
        #expect(f.identity == "/w/a.wav|456|123")
    }
}
