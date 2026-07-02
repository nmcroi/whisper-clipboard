import XCTest
@testable import WhisperClipboard

final class TransitionDebouncerTests: XCTestCase {
    func testFirstTransitionAccepted() {
        var debouncer = TransitionDebouncer(interval: 0.25)
        XCTAssertTrue(debouncer.shouldAccept(now: 100.0))
    }

    func testRapidSecondTransitionRejected() {
        var debouncer = TransitionDebouncer(interval: 0.25)
        XCTAssertTrue(debouncer.shouldAccept(now: 100.0))
        XCTAssertFalse(debouncer.shouldAccept(now: 100.1)) // within 0.25s
    }

    func testTransitionAfterIntervalAccepted() {
        var debouncer = TransitionDebouncer(interval: 0.25)
        XCTAssertTrue(debouncer.shouldAccept(now: 100.0))
        XCTAssertTrue(debouncer.shouldAccept(now: 100.30)) // beyond 0.25s
    }

    func testBoundaryIsExclusive() {
        var debouncer = TransitionDebouncer(interval: 0.25)
        XCTAssertTrue(debouncer.shouldAccept(now: 0))
        // Exactly at the interval is accepted (>= interval).
        XCTAssertTrue(debouncer.shouldAccept(now: 0.25))
    }

    func testResetClearsHistory() {
        var debouncer = TransitionDebouncer(interval: 0.25)
        XCTAssertTrue(debouncer.shouldAccept(now: 100.0))
        debouncer.reset()
        XCTAssertTrue(debouncer.shouldAccept(now: 100.05))
    }
}

final class LatencyMetricsTests: XCTestCase {
    func testIntervalsComputed() {
        var metrics = LatencyMetrics()
        metrics.recordStart = 10.0
        metrics.firstPartial = 10.4
        metrics.stop = 15.0
        metrics.finalized = 15.3
        metrics.clipboard = 15.35

        XCTAssertEqual(metrics.timeToFirstPartial ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(metrics.stopToFinalized ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertEqual(metrics.stopToClipboard ?? -1, 0.35, accuracy: 1e-9)
    }

    func testMissingTimestampsYieldNil() {
        var metrics = LatencyMetrics()
        metrics.recordStart = 10.0
        XCTAssertNil(metrics.timeToFirstPartial)
        XCTAssertNil(metrics.stopToFinalized)
    }

    func testNegativeDeltaRejected() {
        var metrics = LatencyMetrics()
        metrics.stop = 15.0
        metrics.finalized = 14.0 // impossible ordering
        XCTAssertNil(metrics.stopToFinalized)
    }

    func testDebugLineFormatsPresentAndMissing() {
        var metrics = LatencyMetrics()
        metrics.recordStart = 1
        metrics.firstPartial = 1.5
        let line = metrics.debugLine
        XCTAssertTrue(line.contains("partial 0.50s"))
        XCTAssertTrue(line.contains("final –"))
    }
}

final class PartialAccumulatorTests: XCTestCase {
    func testVolatileThenFinalPromotes() {
        var acc = PartialAccumulator()
        acc.setVolatile(text: "hallo")
        XCTAssertEqual(acc.partial.finalizedText, "")
        XCTAssertEqual(acc.partial.volatileText, "hallo")

        acc.appendFinal(text: "hallo", start: 0, end: 1)
        XCTAssertEqual(acc.finalizedText, "hallo")
        XCTAssertEqual(acc.partial.volatileText, "") // cleared on finalization
    }

    func testMultipleFinalsJoinWithSpace() {
        var acc = PartialAccumulator()
        acc.appendFinal(text: "een", start: 0, end: 1)
        acc.appendFinal(text: "twee", start: 1, end: 2)
        XCTAssertEqual(acc.finalizedText, "een twee")
        XCTAssertEqual(acc.result.segments.count, 2)
        XCTAssertEqual(acc.result.segments[1].text, "twee")
        XCTAssertEqual(acc.result.segments[1].start, 1)
    }

    func testVolatileTailGetsLeadingSpaceAfterFinal() {
        var acc = PartialAccumulator()
        acc.appendFinal(text: "goedemorgen", start: 0, end: 1)
        acc.setVolatile(text: "iedereen")
        XCTAssertEqual(acc.partial.finalizedText, "goedemorgen")
        XCTAssertEqual(acc.partial.volatileText, " iedereen")
        XCTAssertEqual(acc.partial.displayText, "goedemorgen iedereen")
    }

    func testEmptyFinalIgnored() {
        var acc = PartialAccumulator()
        acc.appendFinal(text: "   ", start: 0, end: 1)
        XCTAssertEqual(acc.result.segments.count, 0)
        XCTAssertEqual(acc.finalizedText, "")
    }

    func testResultReflectsAccumulation() {
        var acc = PartialAccumulator()
        acc.appendFinal(text: "test", start: 0, end: 0.5)
        let result = acc.result
        XCTAssertEqual(result.text, "test")
        XCTAssertEqual(result.segments.count, 1)
    }
}

final class StreamingPartialTests: XCTestCase {
    func testDisplayTextConcatenation() {
        let p = StreamingPartial(finalizedText: "hallo", volatileText: " wereld")
        XCTAssertEqual(p.displayText, "hallo wereld")
    }

    func testDisplayTextEmptyVolatile() {
        let p = StreamingPartial(finalizedText: "hallo", volatileText: "")
        XCTAssertEqual(p.displayText, "hallo")
    }
}
