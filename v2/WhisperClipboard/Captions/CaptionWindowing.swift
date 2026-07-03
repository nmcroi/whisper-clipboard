import Foundation

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

    init(id: UUID = UUID(), text: String, timestamp: Date = Date(), isFinal: Bool = true) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.isFinal = isFinal
    }

    static func == (lhs: CaptionLine, rhs: CaptionLine) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.isFinal == rhs.isFinal
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
/// - **Silence cut:** if the trailing ``silenceSeconds`` (~0.7 s) of audio are
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
    var silenceSeconds: Double = 0.7
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
    var interval: Double = 0.9

    /// When the current window opened / last volatile tick fired.
    private var lastTick: Date?

    init(interval: Double = 0.9) {
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
