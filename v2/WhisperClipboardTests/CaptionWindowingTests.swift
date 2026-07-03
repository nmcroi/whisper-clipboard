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
        acc.append(silent(0.6))   // > 0.55s of trailing quiet
        XCTAssertTrue(acc.shouldCut)
    }

    /// The tightened silence window (0.55s) does not cut on a shorter pause.
    func testDoesNotCutBelowSilenceWindow() {
        var acc = CaptionWindowAccumulator(sampleRate: sampleRate)
        acc.append(loud(1.0))
        acc.append(silent(0.4))   // < 0.55s trailing quiet
        XCTAssertFalse(acc.shouldCut)
    }

    func testSecondsBufferedTracksAppend() {
        var acc = CaptionWindowAccumulator(sampleRate: sampleRate)
        acc.append(loud(1.5))
        XCTAssertEqual(acc.secondsBuffered, 1.5, accuracy: 1e-6)
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

    // MARK: - Snapshot (pseudo-streaming)

    func testSnapshotReturnsOpenWindowWithoutCutting() {
        var acc = CaptionWindowAccumulator(sampleRate: sampleRate)
        acc.append(loud(1.0)) // above 0.4s min, below 3s max — window still open
        XCTAssertFalse(acc.shouldCut)
        let snap = acc.snapshot()
        XCTAssertEqual(snap?.count, Int(1.0 * sampleRate))
        // Snapshot is non-destructive: the buffer is untouched.
        XCTAssertEqual(acc.samples.count, Int(1.0 * sampleRate))
    }

    func testSnapshotNilBelowMinWindow() {
        var acc = CaptionWindowAccumulator(sampleRate: sampleRate)
        acc.append(loud(0.2)) // below the 0.4s min meaningful window
        XCTAssertNil(acc.snapshot())
    }

    // MARK: - Tick planner (pseudo-streaming cadence)

    func testTickPlannerFiresFirstTimeThenWaitsForInterval() {
        var planner = CaptionTickPlanner(interval: 0.9)
        let t0 = Date(timeIntervalSince1970: 1000)
        // First tick allowed immediately (no prior tick).
        XCTAssertTrue(planner.shouldTick(now: t0, inFlight: false))
        planner.didTick(at: t0)
        // Too soon after.
        XCTAssertFalse(planner.shouldTick(now: t0.addingTimeInterval(0.5), inFlight: false))
        // After the interval elapses.
        XCTAssertTrue(planner.shouldTick(now: t0.addingTimeInterval(0.95), inFlight: false))
    }

    func testTickPlannerSuppressedWhileInFlight() {
        var planner = CaptionTickPlanner(interval: 0.9)
        let t0 = Date(timeIntervalSince1970: 2000)
        planner.didTick(at: t0)
        // Even well past the interval, an in-flight transcription blocks the tick.
        XCTAssertFalse(planner.shouldTick(now: t0.addingTimeInterval(5), inFlight: true))
        XCTAssertTrue(planner.shouldTick(now: t0.addingTimeInterval(5), inFlight: false))
    }

    func testTickPlannerResetRestartsCadence() {
        var planner = CaptionTickPlanner(interval: 0.9)
        let t0 = Date(timeIntervalSince1970: 3000)
        planner.reset(at: t0)
        XCTAssertFalse(planner.shouldTick(now: t0.addingTimeInterval(0.4), inFlight: false))
        XCTAssertTrue(planner.shouldTick(now: t0.addingTimeInterval(1.0), inFlight: false))
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

/// Tests for the tightened default cadence.
final class CaptionTickPlannerDefaultsTests: XCTestCase {
    func testDefaultIntervalIsFasterAt06() {
        var planner = CaptionTickPlanner()
        let t0 = Date(timeIntervalSince1970: 4000)
        planner.didTick(at: t0)
        // 0.5s < 0.6s default → no tick yet.
        XCTAssertFalse(planner.shouldTick(now: t0.addingTimeInterval(0.5), inFlight: false))
        // 0.65s ≥ 0.6s → tick.
        XCTAssertTrue(planner.shouldTick(now: t0.addingTimeInterval(0.65), inFlight: false))
    }
}

/// Tests for the pure caption text-hygiene rules (Part A "calmer" fixes).
final class CaptionTextTests: XCTestCase {

    // MARK: - Eager punctuation close

    func testEagerCloseOnSentenceFinalWithEnoughAudio() {
        XCTAssertTrue(CaptionText.shouldEagerClose(after: "Hallo daar.", secondsBuffered: 1.5))
        XCTAssertTrue(CaptionText.shouldEagerClose(after: "Echt waar?", secondsBuffered: 2.0))
        XCTAssertTrue(CaptionText.shouldEagerClose(after: "Geweldig!", secondsBuffered: 1.3))
    }

    func testNoEagerCloseWithTooLittleAudio() {
        // Sentence-final punctuation but < 1.2s buffered → keep filling.
        XCTAssertFalse(CaptionText.shouldEagerClose(after: "Ja.", secondsBuffered: 0.8))
    }

    func testNoEagerCloseWithoutSentenceFinalPunctuation() {
        XCTAssertFalse(CaptionText.shouldEagerClose(after: "en toen ging ik", secondsBuffered: 2.0))
        XCTAssertFalse(CaptionText.shouldEagerClose(after: "een komma,", secondsBuffered: 2.0))
    }

    func testEagerCloseIgnoresTrailingWhitespace() {
        XCTAssertTrue(CaptionText.shouldEagerClose(after: "Klaar.  \n", secondsBuffered: 1.5))
    }

    // MARK: - Junk suppression

    func testJunkDetection() {
        XCTAssertTrue(CaptionText.isJunk(""))
        XCTAssertTrue(CaptionText.isJunk("   "))
        XCTAssertTrue(CaptionText.isJunk("..."))
        XCTAssertTrue(CaptionText.isJunk("?!"))
        XCTAssertTrue(CaptionText.isJunk(" - — "))
        XCTAssertFalse(CaptionText.isJunk("Hallo"))
        XCTAssertFalse(CaptionText.isJunk("a."))
    }

    // MARK: - Near-duplicate suppression

    func testNearDuplicateIgnoresCaseAndPunctuation() {
        XCTAssertTrue(CaptionText.isNearDuplicate("Hallo wereld.", of: "hallo wereld"))
        XCTAssertTrue(CaptionText.isNearDuplicate("  De kat,  ", of: "de kat"))
    }

    func testNotNearDuplicateForDifferentText() {
        XCTAssertFalse(CaptionText.isNearDuplicate("Hallo wereld", of: "Tot ziens"))
    }

    func testNearDuplicateWithNoPreviousIsFalse() {
        XCTAssertFalse(CaptionText.isNearDuplicate("iets", of: nil))
    }

    // MARK: - Seam-overlap trim

    func testSeamOverlapTrimsDuplicatedLeadingWords() {
        // Previous ended with "naar de winkel"; new repeats "de winkel" at the seam.
        let trimmed = CaptionText.trimSeamOverlap(
            "de winkel om melk te kopen",
            previousFinal: "ik ging naar de winkel"
        )
        XCTAssertEqual(trimmed, "om melk te kopen")
    }

    func testSeamOverlapSingleWord() {
        let trimmed = CaptionText.trimSeamOverlap("wereld is groot", previousFinal: "hallo wereld")
        XCTAssertEqual(trimmed, "is groot")
    }

    func testSeamOverlapCaseInsensitive() {
        let trimmed = CaptionText.trimSeamOverlap("Winkel is dicht", previousFinal: "de winkel")
        XCTAssertEqual(trimmed, "is dicht")
    }

    func testSeamOverlapNoOverlapUnchanged() {
        let trimmed = CaptionText.trimSeamOverlap("iets heel anders", previousFinal: "de winkel")
        XCTAssertEqual(trimmed, "iets heel anders")
    }

    func testSeamOverlapEntireLineDuplicatedReturnsUnchanged() {
        // If the whole new line duplicates the seam, leave it for the near-dup rule.
        let trimmed = CaptionText.trimSeamOverlap("de winkel", previousFinal: "ik ging naar de winkel")
        XCTAssertEqual(trimmed, "de winkel")
    }

    func testSeamOverlapNilPreviousUnchanged() {
        XCTAssertEqual(CaptionText.trimSeamOverlap("hallo", previousFinal: nil), "hallo")
    }

    // MARK: - Volatile no-regress rule

    func testVolatileReplacesWhenLonger() {
        XCTAssertTrue(CaptionText.shouldReplaceVolatile(current: "hallo", with: "hallo wereld"))
    }

    func testVolatileDoesNotRegressToTruncatedPrefix() {
        // Shorter candidate that is a prefix of the current line → keep the longer.
        XCTAssertFalse(CaptionText.shouldReplaceVolatile(current: "hallo wereld", with: "hallo"))
    }

    func testVolatileReplacesWhenMateriallyDifferent() {
        // Shorter but genuinely different wording → accept.
        XCTAssertTrue(CaptionText.shouldReplaceVolatile(current: "hallo wereld daar", with: "tot ziens"))
    }

    func testVolatileReplacesWhenNoCurrent() {
        XCTAssertTrue(CaptionText.shouldReplaceVolatile(current: nil, with: "iets"))
        XCTAssertTrue(CaptionText.shouldReplaceVolatile(current: "", with: "iets"))
    }

    // MARK: - Dutch detection (translation skip)

    func testDetectsDutchSkipsTranslation() {
        XCTAssertTrue(CaptionText.detectedIsDutch("Ik ga vanavond naar de bioscoop met mijn vrienden."))
    }

    func testDetectsEnglishAsNotDutch() {
        XCTAssertFalse(CaptionText.detectedIsDutch("I am going to the cinema with my friends tonight."))
    }

    func testShortTextNotTreatedAsDutch() {
        // Too short to detect reliably → don't skip translation.
        XCTAssertFalse(CaptionText.detectedIsDutch("Ja hoor"))
    }
}

/// Tests for the volatile/final caption-line model.
final class CaptionLineTests: XCTestCase {
    func testDefaultsToFinal() {
        XCTAssertTrue(CaptionLine(text: "klaar").isFinal)
    }

    func testVolatileFlagPreserved() {
        let line = CaptionLine(text: "bezig", isFinal: false)
        XCTAssertFalse(line.isFinal)
    }

    func testEqualityConsidersFinalFlag() {
        let id = UUID()
        let volatile = CaptionLine(id: id, text: "x", isFinal: false)
        let final = CaptionLine(id: id, text: "x", isFinal: true)
        XCTAssertNotEqual(volatile, final)
    }

    func testEqualityConsidersTranslation() {
        let id = UUID()
        let untranslated = CaptionLine(id: id, text: "hello", isFinal: true)
        let translated = CaptionLine(id: id, text: "hello", isFinal: true, translation: "hallo")
        XCTAssertNotEqual(untranslated, translated)
    }

    func testTranslationDefaultsToNil() {
        XCTAssertNil(CaptionLine(text: "x").translation)
    }
}
