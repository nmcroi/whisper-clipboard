import Foundation
import NaturalLanguage

/// One displayed caption line: transcribed text plus the wall-clock moment it
/// was produced.
///
/// A line is **volatile** while its window is still open and being re-transcribed
/// in place (rendered dimmed, like the dictation HUD's in-progress text); it
/// becomes **final** (full white) once the window closes and a last transcription
/// replaces it.
struct CaptionLine: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var timestamp: Date
    /// `false` while the line's window is open and still being re-transcribed.
    var isFinal: Bool
    /// The Dutch translation of ``text``, filled in asynchronously when live
    /// translation is enabled (Part B). `nil` until (and unless) a translation
    /// arrives; only ever set on FINAL lines.
    var translation: String?

    init(
        id: UUID = UUID(),
        text: String,
        timestamp: Date = Date(),
        isFinal: Bool = true,
        translation: String? = nil
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.isFinal = isFinal
        self.translation = translation
    }

    static func == (lhs: CaptionLine, rhs: CaptionLine) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && lhs.isFinal == rhs.isFinal
            && lhs.translation == rhs.translation
    }
}

/// Pure rolling-window accumulator for live captioning — no Core Audio, no
/// Parakeet, so it is fully unit-testable.
///
/// ## Why rolling windows (not streaming)
/// The multilingual Parakeet v3 model this app uses is *batch-only*: it has no
/// cache-aware streaming path and emits no partials. To fake "live" captions we
/// accumulate 16 kHz mono samples and periodically cut a window to transcribe:
///
/// - **Time cut:** once the window reaches ``maxWindowSeconds`` (~3 s) it is cut
///   so captions keep flowing even during continuous speech.
/// - **Silence cut:** if the trailing ``silenceSeconds`` (~0.55 s) of audio are
///   below the RMS ``silenceThreshold``, the window is cut at a natural pause —
///   this yields cleaner sentence boundaries than a hard time cut.
/// - **Hard cap:** windows never exceed ``hardCapSeconds`` (~10 s) regardless.
///
/// A cut window is handed to the caller to transcribe; the resulting text becomes
/// the current caption line. This gives near-live captions with a ~1–3 s delay
/// (transcription latency + up to one window of buffering). Overlap between
/// windows is intentionally omitted — for read-only captions a dropped word at a
/// boundary is acceptable and overlap would duplicate text across lines.
struct CaptionWindowAccumulator {

    /// Sample rate of the fed audio (16 kHz mono Float32).
    let sampleRate: Double

    /// Cut the window once it reaches this many seconds of audio.
    var maxWindowSeconds: Double = 3.0
    /// Trailing quiet duration that triggers an early (natural-pause) cut.
    var silenceSeconds: Double = 0.55
    /// Absolute hard ceiling on window length.
    var hardCapSeconds: Double = 10.0
    /// RMS below this counts as silence.
    var silenceThreshold: Float = 0.01
    /// Minimum window length worth transcribing (shorter → skip, avoids noise).
    var minWindowSeconds: Double = 0.4

    private(set) var samples: [Float] = []

    init(sampleRate: Double = 16_000) {
        self.sampleRate = sampleRate
    }

    private var minSilenceSamples: Int { Int(silenceSeconds * sampleRate) }
    private var maxWindowSamples: Int { Int(maxWindowSeconds * sampleRate) }
    private var hardCapSamples: Int { Int(hardCapSeconds * sampleRate) }
    private var minWindowSamples: Int { Int(minWindowSeconds * sampleRate) }

    /// Appends captured samples to the current window.
    mutating func append(_ chunk: [Float]) {
        samples.append(contentsOf: chunk)
    }

    /// Seconds of audio currently buffered in the open window.
    var secondsBuffered: Double {
        Double(samples.count) / sampleRate
    }

    /// Whether the current window should be cut *now*, per the rules above.
    var shouldCut: Bool {
        let count = samples.count
        guard count >= minWindowSamples else { return false }
        if count >= hardCapSamples { return true }
        if count >= maxWindowSamples { return true }
        // Natural-pause cut: enough audio buffered AND the tail is quiet.
        if count >= minSilenceSamples, trailingIsSilent {
            return true
        }
        return false
    }

    /// RMS of the trailing ``silenceSeconds`` is below the silence threshold.
    private var trailingIsSilent: Bool {
        let tailCount = min(minSilenceSamples, samples.count)
        guard tailCount > 0 else { return false }
        let tail = samples[(samples.count - tailCount)...]
        return Self.rms(tail) < silenceThreshold
    }

    /// A non-destructive view of the current open window, for pseudo-streaming
    /// re-transcription while the window is still filling. Returns `nil` when
    /// there is too little audio yet to be worth transcribing. Does NOT reset the
    /// buffer (unlike ``cut()``).
    func snapshot() -> [Float]? {
        guard samples.count >= minWindowSamples else { return nil }
        return samples
    }

    /// Cuts and returns the accumulated window, resetting the buffer. Returns
    /// `nil` when there is too little audio to transcribe.
    mutating func cut() -> [Float]? {
        defer { samples.removeAll(keepingCapacity: true) }
        guard samples.count >= minWindowSamples else { return nil }
        return samples
    }

    /// Drains whatever remains (used at teardown for a final caption). Returns
    /// `nil` when the remainder is too short to be meaningful.
    mutating func drain() -> [Float]? {
        cut()
    }

    /// RMS amplitude of a sample slice.
    static func rms<S: Sequence>(_ samples: S) -> Float where S.Element == Float {
        var sum: Float = 0
        var n = 0
        for s in samples {
            sum += s * s
            n += 1
        }
        guard n > 0 else { return 0 }
        return (sum / Float(n)).squareRoot()
    }
}

/// A bounded ring of the most recent caption lines shown in the overlay.
struct CaptionLineBuffer: Equatable {
    /// Maximum lines kept for display (newest last).
    let capacity: Int
    private(set) var lines: [CaptionLine] = []

    init(capacity: Int = 3) {
        self.capacity = max(1, capacity)
    }

    /// Appends a non-empty caption line, evicting the oldest beyond capacity.
    /// Whitespace-only text is ignored. Returns whether a line was added.
    @discardableResult
    mutating func push(_ text: String, at timestamp: Date = Date()) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        lines.append(CaptionLine(text: trimmed, timestamp: timestamp))
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        return true
    }

    /// The full session transcript (all pushed lines, in order).
    func fullTranscript(pushedLines: [String]) -> String {
        pushedLines.joined(separator: " ")
    }

    mutating func clear() {
        lines.removeAll()
    }
}

/// Pure scheduler for pseudo-streaming re-transcription — no Core Audio, no
/// Parakeet, so it is fully unit-testable.
///
/// While a window is open, we want to re-transcribe its accumulated samples every
/// ``interval`` seconds so the current caption line updates in place. Two rules
/// keep this cheap and non-overlapping:
///
/// - **Cadence:** a tick fires only once at least ``interval`` seconds have
///   elapsed since the last one (or since the window opened).
/// - **Non-overlap:** a tick is suppressed while a previous transcription is
///   still in flight (``inFlight``), so slow transcriptions can never queue up.
struct CaptionTickPlanner {
    /// Minimum seconds between volatile re-transcriptions.
    var interval: Double = 0.6

    /// When the current window opened / last volatile tick fired.
    private var lastTick: Date?

    init(interval: Double = 0.6) {
        self.interval = interval
    }

    /// Whether a volatile re-transcription should start `now`, given whether a
    /// previous one is still running. When it returns `true`, the caller should
    /// record the tick via ``didTick(at:)`` and begin transcribing.
    func shouldTick(now: Date, inFlight: Bool) -> Bool {
        guard !inFlight else { return false }
        guard let lastTick else { return true }
        return now.timeIntervalSince(lastTick) >= interval
    }

    /// Records that a tick fired (or the window (re)opened) at `time`.
    mutating func didTick(at time: Date = Date()) {
        lastTick = time
    }

    /// Resets the cadence for a freshly opened window.
    mutating func reset(at time: Date = Date()) {
        lastTick = time
    }
}

/// Pure text-hygiene rules that keep the caption stream calm ("minder rommelig").
///
/// All functions are static and side-effect free so they are trivially unit
/// tested. ``CaptionsService`` calls them; ``CaptionWindowAccumulator`` remains
/// purely about audio timing.
enum CaptionText {

    /// Sentence-final punctuation that lets a window close eagerly.
    private static let sentenceFinal: Set<Character> = [".", "!", "?", "。", "！", "？"]

    /// Minimum buffered audio before an eager sentence-final close may fire.
    static let eagerCloseMinSeconds: Double = 1.2

    /// A window with a volatile transcription of `text` should be closed *now*
    /// (rather than waiting for the ~3 s soft cut) when the model has produced a
    /// sentence-final punctuation mark AND enough audio has accumulated that this
    /// is a real sentence, not a stray "Uh." — avoids chopping mid-thought while
    /// still snapping cleanly on natural sentence ends.
    ///
    /// - Parameters:
    ///   - text: the latest volatile transcription of the open window.
    ///   - secondsBuffered: seconds of audio currently in the open window.
    ///   - minSeconds: minimum audio (default 1.2 s) before an eager close fires.
    static func shouldEagerClose(
        after text: String,
        secondsBuffered: Double,
        minSeconds: Double = CaptionText.eagerCloseMinSeconds
    ) -> Bool {
        guard secondsBuffered >= minSeconds else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return sentenceFinal.contains(last)
    }

    /// Whether `text` carries no real content: empty, whitespace-only, or nothing
    /// but punctuation/symbols (e.g. "...", "?", "-"). Such results are dropped
    /// rather than shown as caption lines.
    static func isJunk(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // Junk if it contains no letter or number at all.
        return !trimmed.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
    }

    /// Normalised form for equality comparisons: lowercased, trimmed, internal
    /// whitespace collapsed, and surrounding punctuation ignored. Used for the
    /// near-duplicate suppression rule.
    static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        let words = lowered.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }

    /// A freshly finalized line that is a near-duplicate of the previous final
    /// line should be dropped (the model re-emitting the same window's text).
    static func isNearDuplicate(_ text: String, of previous: String?) -> Bool {
        guard let previous else { return false }
        let a = normalized(text)
        guard !a.isEmpty else { return true }
        return a == normalized(previous)
    }

    /// Conservative boundary-artifact trim. When two adjacent windows overlap at
    /// the seam, the model can repeat the last word(s) of the previous final line
    /// at the start of the new one. This trims an *exact* duplicated leading word
    /// sequence (case-insensitive) from `text` where it matches the trailing words
    /// of `previous`. Deliberately unfancy: it only removes whole-word runs that
    /// match exactly, never partial-word "Whisperk/Flipboard"-style fusions.
    ///
    /// Returns the (possibly shortened) text; never returns an empty string —
    /// if the entire line is a duplicated seam it is returned unchanged so the
    /// near-duplicate rule can decide to drop it instead.
    static func trimSeamOverlap(_ text: String, previousFinal previous: String?) -> String {
        guard let previous else { return text }
        let newWords = splitWords(text)
        let prevWords = splitWords(previous)
        guard !newWords.isEmpty, !prevWords.isEmpty else { return text }

        // Try the longest possible overlap first (up to min of both / a small cap).
        let maxOverlap = min(newWords.count, prevWords.count, 6)
        var overlap = 0
        var k = maxOverlap
        while k >= 1 {
            let newHead = newWords.prefix(k).map { normalizedWord($0) }
            let prevTail = prevWords.suffix(k).map { normalizedWord($0) }
            if newHead == prevTail {
                overlap = k
                break
            }
            k -= 1
        }
        guard overlap > 0, overlap < newWords.count else { return text }
        return newWords.dropFirst(overlap).joined(separator: " ")
    }

    /// The volatile line should only be replaced with `candidate` when it does not
    /// *regress* — i.e. the new text is longer, or materially different from the
    /// current one. This prevents flicker where a shorter re-transcription briefly
    /// replaces a longer, more complete line.
    static func shouldReplaceVolatile(current: String?, with candidate: String) -> Bool {
        guard let current, !current.isEmpty else { return true }
        if candidate.count >= current.count { return true }
        // Shorter candidate: only accept if it is materially different (not just a
        // truncated prefix of the current line).
        let a = normalized(candidate)
        let b = normalized(current)
        if a.isEmpty { return false }
        if b.hasPrefix(a) { return false }   // pure truncation → keep the longer line
        return a != b
    }

    /// Cheap on-device language detection: whether `text` is (dominantly) Dutch.
    /// Used to skip translating lines that are already in the target language.
    /// Conservative — returns `false` for very short/ambiguous text so we don't
    /// wrongly skip translation.
    static func detectedIsDutch(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Too little text to detect reliably; don't skip.
        guard trimmed.count >= 12 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let dominant = recognizer.dominantLanguage else { return false }
        return dominant == .dutch
    }

    // MARK: - Helpers

    private static func splitWords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Lowercased, punctuation-stripped word for overlap comparison.
    private static func normalizedWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}
