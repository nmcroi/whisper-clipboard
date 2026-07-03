import XCTest
@testable import WhisperClipboard

/// Pure unit tests for the rolling-window captioning logic (no Core Audio).
final class CaptionWindowingTests: XCTestCase {

    private let sampleRate = 16_000.0

    /// Constant-amplitude tone-ish samples (RMS ≈ amplitude).
    private func loud(_ seconds: Double, amplitude: Float = 0.5) -> [Float] {
        Array(repeating: amplitude, count: Int(seconds * sampleRate))
    }

    private func silent(_ seconds: Double) -> [Float] {
        Array(repeating: 0.0, count: Int(seconds * sampleRate))
    }

    // MARK: - Time-based cut

    func testDoesNotCutBelowMaxWindow() {
        var acc = CaptionWindowAccumulator(sampleRate: sampleRate)
        acc.append(loud(1.5)) // < 3s max, no trailing silence
        XCTAssertFalse(acc.shouldCut)
    }

    func testCutsAtMaxWindow() {
        var acc = CaptionWindowAccumulator(sampleRate: sampleRate)
        acc.append(loud(3.1)) // exceeds 3s max
        XCTAssertTrue(acc.shouldCut)
    }

    func testCutsAtHardCapEvenWithoutSilence() {
        var acc = CaptionWindowAccumulator(sampleRate: sampleRate)
        acc.maxWindowSeconds = 100 // disable the normal time cut
        acc.append(loud(10.5))     // still exceeds the 10s hard cap
        XCTAssertTrue(acc.shouldCut)
    }

    // MARK: - Silence-based cut

    func testCutsOnTrailingSilence() {
        var acc = CaptionWindowAccumulator(sampleRate: sampleRate)
        acc.append(loud(1.0))     // enough audio to be worth a window
        acc.append(silent(0.8))   // > 0.7s of trailing quiet
        XCTAssertTrue(acc.shouldCut)
    }

    func testNoCutBelowMinWindowEvenIfSilent() {
        var acc = CaptionWindowAccumulator(sampleRate: sampleRate)
        acc.append(silent(0.3))   // below the 0.4s min meaningful window
        XCTAssertFalse(acc.shouldCut)
    }

    func testLoudTailDoesNotSilenceCut() {
        var acc = CaptionWindowAccumulator(sampleRate: sampleRate)
        acc.append(loud(2.0))     // 2s, under max, tail is loud
        XCTAssertFalse(acc.shouldCut)
    }

    // MARK: - Cutting / draining

    func testCutReturnsSamplesAndResets() {
        var acc = CaptionWindowAccumulator(sampleRate: sampleRate)
        acc.append(loud(3.1))
        let window = acc.cut()
        XCTAssertNotNil(window)
        XCTAssertEqual(window?.count, Int(3.1 * sampleRate))
        XCTAssertTrue(acc.samples.isEmpty)
        XCTAssertFalse(acc.shouldCut) // empty again
    }

    func testCutBelowMinReturnsNil() {
        var acc = CaptionWindowAccumulator(sampleRate: sampleRate)
        acc.append(loud(0.2)) // below 0.4s min window
        XCTAssertNil(acc.cut())
    }

    func testDrainEqualsCut() {
        var acc = CaptionWindowAccumulator(sampleRate: sampleRate)
        acc.append(loud(1.0))
        let drained = acc.drain()
        XCTAssertEqual(drained?.count, Int(1.0 * sampleRate))
    }

    // MARK: - Full sequence simulation

    func testSpeechPauseSpeechYieldsTwoWindows() {
        var acc = CaptionWindowAccumulator(sampleRate: sampleRate)
        var windows: [[Float]] = []

        // Feed in 0.1s chunks: 1s speech, 0.8s silence, 1s speech, 0.8s silence.
        let script: [(Double, Bool)] = [(1.0, true), (0.8, false), (1.0, true), (0.8, false)]
        for (duration, isLoud) in script {
            let total = Int(duration / 0.1)
            for _ in 0..<total {
                acc.append(isLoud ? loud(0.1) : silent(0.1))
                if acc.shouldCut, let w = acc.cut() { windows.append(w) }
            }
        }
        if let tail = acc.drain() { windows.append(tail) }

        // Two natural-pause cuts expected (one per speech+silence pair).
        XCTAssertEqual(windows.count, 2)
    }

    // MARK: - RMS

    func testRMSOfSilenceIsZero() {
        XCTAssertEqual(CaptionWindowAccumulator.rms(silent(0.1)), 0, accuracy: 1e-6)
    }

    func testRMSOfConstantEqualsAmplitude() {
        XCTAssertEqual(CaptionWindowAccumulator.rms(loud(0.1, amplitude: 0.5)), 0.5, accuracy: 1e-4)
    }
}

/// Tests for the bounded caption-line display buffer.
final class CaptionLineBufferTests: XCTestCase {

    func testPushKeepsCapacity() {
        var buffer = CaptionLineBuffer(capacity: 3)
        buffer.push("een")
        buffer.push("twee")
        buffer.push("drie")
        buffer.push("vier")
        XCTAssertEqual(buffer.lines.map(\.text), ["twee", "drie", "vier"])
    }

    func testPushIgnoresBlank() {
        var buffer = CaptionLineBuffer(capacity: 3)
        XCTAssertFalse(buffer.push("   "))
        XCTAssertTrue(buffer.lines.isEmpty)
    }

    func testPushTrimsWhitespace() {
        var buffer = CaptionLineBuffer(capacity: 3)
        buffer.push("  hallo wereld  ")
        XCTAssertEqual(buffer.lines.first?.text, "hallo wereld")
    }

    func testNewestIsLast() {
        var buffer = CaptionLineBuffer(capacity: 2)
        buffer.push("oud")
        buffer.push("nieuw")
        XCTAssertEqual(buffer.lines.last?.text, "nieuw")
    }

    func testClearEmptiesBuffer() {
        var buffer = CaptionLineBuffer(capacity: 3)
        buffer.push("iets")
        buffer.clear()
        XCTAssertTrue(buffer.lines.isEmpty)
    }

    func testCapacityFloorIsOne() {
        var buffer = CaptionLineBuffer(capacity: 0)
        buffer.push("a")
        buffer.push("b")
        XCTAssertEqual(buffer.lines.map(\.text), ["b"])
    }
}
