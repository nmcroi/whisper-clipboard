import XCTest
import WhisperShared

/// Pure-logic tests for the Parakeet download progress + watchdog + validation
/// support added for the iOS on-device test fixes (Issues 2 & 3). These exercise
/// the side-effect-free helpers only; the live download/load path needs Apple
/// Silicon + network and is covered by manual on-device testing.
final class ParakeetDownloadLogicTests: XCTestCase {

    // MARK: - Watchdog decision logic

    func testWatchdogTripsAfterTimeoutWithNoAdvance() {
        // No progress and no byte growth, past the timeout → stalled.
        let sample = ParakeetEngine.watchdogSample(
            lastProgress: 0.3,
            lastBytes: 100,
            currentProgress: 0.3,
            currentBytes: 100,
            secondsSinceLastAdvance: 61,
            timeout: 60
        )
        XCTAssertFalse(sample.advanced)
        XCTAssertTrue(sample.stalled)
    }

    func testWatchdogDoesNotTripBeforeTimeout() {
        // No advance but still inside the timeout window → not yet stalled.
        let sample = ParakeetEngine.watchdogSample(
            lastProgress: 0.3,
            lastBytes: 100,
            currentProgress: 0.3,
            currentBytes: 100,
            secondsSinceLastAdvance: 59.9,
            timeout: 60
        )
        XCTAssertFalse(sample.advanced)
        XCTAssertFalse(sample.stalled)
    }

    func testWatchdogResetsWhenFractionAdvances() {
        // The fraction moved even though bytes didn't — counts as advance,
        // never stalled regardless of elapsed time.
        let sample = ParakeetEngine.watchdogSample(
            lastProgress: 0.3,
            lastBytes: 100,
            currentProgress: 0.31,
            currentBytes: 100,
            secondsSinceLastAdvance: 120,
            timeout: 60
        )
        XCTAssertTrue(sample.advanced)
        XCTAssertFalse(sample.stalled)
    }

    func testWatchdogResetsWhenDiskBytesGrow() {
        // Bytes on disk grew even though FluidAudio's fraction sat still on the
        // big encoder file — this is exactly the "0% for minutes" case, and it
        // must count as progress so the watchdog does NOT trip.
        let sample = ParakeetEngine.watchdogSample(
            lastProgress: 0.0,
            lastBytes: 100_000_000,
            currentProgress: 0.0,
            currentBytes: 130_000_000,
            secondsSinceLastAdvance: 120,
            timeout: 60
        )
        XCTAssertTrue(sample.advanced)
        XCTAssertFalse(sample.stalled)
    }

    func testWatchdogExactlyAtTimeoutTrips() {
        // Boundary: elapsed == timeout with no advance → stalled (>=).
        let sample = ParakeetEngine.watchdogSample(
            lastProgress: 0.5,
            lastBytes: 200,
            currentProgress: 0.5,
            currentBytes: 200,
            secondsSinceLastAdvance: 60,
            timeout: 60
        )
        XCTAssertTrue(sample.stalled)
    }

    // MARK: - Directory size (disk-byte measurement)

    func testDirectorySizeOfMissingDirectoryIsZero() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("wc-does-not-exist-\(UUID().uuidString)")
        XCTAssertEqual(ParakeetEngine.directorySize(at: missing), 0)
    }

    func testDirectorySizeSumsNestedFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wc-dirsize-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Encoder.mlmodelc")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 1000 bytes at the root, 2500 bytes nested → 3500 total.
        try Data(count: 1000).write(to: root.appendingPathComponent("vocab.json"))
        try Data(count: 2500).write(to: nested.appendingPathComponent("coremldata.bin"))

        XCTAssertEqual(ParakeetEngine.directorySize(at: root), 3500)
    }

    // MARK: - Retry backoff

    func testRetryBackoffGrowsExponentially() {
        // 2s, 4s, 8s, 16s for the first four attempts.
        XCTAssertEqual(ParakeetEngine.retryBackoff(forAttempt: 1), 2)
        XCTAssertEqual(ParakeetEngine.retryBackoff(forAttempt: 2), 4)
        XCTAssertEqual(ParakeetEngine.retryBackoff(forAttempt: 3), 8)
        XCTAssertEqual(ParakeetEngine.retryBackoff(forAttempt: 4), 16)
    }

    func testRetryBackoffIsCappedAt30s() {
        // 2^5 = 32 would exceed the cap; 2^10 is far beyond it.
        XCTAssertEqual(ParakeetEngine.retryBackoff(forAttempt: 5), 30)
        XCTAssertEqual(ParakeetEngine.retryBackoff(forAttempt: 10), 30)
    }

    // MARK: - Retry classification

    func testStalledDownloadIsRecoverable() {
        // The stall-watchdog firing is the primary retry trigger.
        XCTAssertTrue(ParakeetEngine.isRecoverableDownloadError(ParakeetEngineError.downloadStalled))
    }

    func testHardOfflineIsNotRecoverable() {
        // Fully offline: retrying without connectivity is pointless, surface now.
        XCTAssertFalse(ParakeetEngine.isRecoverableDownloadError(ParakeetEngineError.noNetwork))
        let notConnected = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertFalse(ParakeetEngine.isRecoverableDownloadError(notConnected))
    }

    func testTransientNetworkErrorsAreRecoverable() {
        // Connection blips a resume/retry can recover from.
        for code in [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorSecureConnectionFailed,
        ] {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertTrue(
                ParakeetEngine.isRecoverableDownloadError(error),
                "URLError code \(code) should be retryable"
            )
        }
    }

    func testUnrelatedErrorIsNotRecoverable() {
        // A random non-network error shouldn't burn the retry budget.
        let error = NSError(domain: "SomeOtherDomain", code: 42)
        XCTAssertFalse(ParakeetEngine.isRecoverableDownloadError(error))
    }

    // MARK: - Byte-progress display model

    func testByteProgressMegabyteConversion() {
        let progress = ModelDownloadByteProgress(
            downloadedBytes: 210_000_000,
            totalBytes: 460_000_000
        )
        XCTAssertEqual(progress.downloadedMB, 210)
        XCTAssertEqual(progress.totalMB, 460)
    }

    func testByteProgressRoundsToNearestMegabyte() {
        // 1_600_000 bytes → 1.6 MB → rounds to 2 MB.
        let progress = ModelDownloadByteProgress(
            downloadedBytes: 1_600_000,
            totalBytes: 3_000_000
        )
        XCTAssertEqual(progress.downloadedMB, 2)
        XCTAssertEqual(progress.totalMB, 3)
    }
}
