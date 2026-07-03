import Foundation
import os

/// Captured latency figures for one dictation run. All intervals are seconds.
///
/// Timestamps are monotonic (`Date`-independent) values sampled from a single
/// clock, so only the *differences* are meaningful. The type is a pure value —
/// no timing side effects — so it is trivially unit-testable.
struct LatencyMetrics: Equatable, Sendable {
    /// Reference instants, all on the same monotonic clock (seconds).
    var recordStart: Double?
    var firstPartial: Double?
    var stop: Double?
    var finalized: Double?
    var clipboard: Double?

    /// recordStart → first partial result surfaced.
    var timeToFirstPartial: Double? {
        Self.delta(from: recordStart, to: firstPartial)
    }

    /// stop pressed → finalized transcript available.
    var stopToFinalized: Double? {
        Self.delta(from: stop, to: finalized)
    }

    /// stop pressed → text on the clipboard.
    var stopToClipboard: Double? {
        Self.delta(from: stop, to: clipboard)
    }

    private static func delta(from: Double?, to: Double?) -> Double? {
        guard let from, let to, to >= from else { return nil }
        return to - from
    }

    /// Whether any streaming partial was surfaced this run (batch engines like
    /// Parakeet emit none, so partial-based figures should be hidden).
    var hadPartials: Bool { firstPartial != nil }

    /// Human-readable Dutch completion figure, e.g. `"0,7 s"`. Uses the
    /// stop→clipboard time (what the user actually waited). `nil` if unmeasured.
    var dutchClipboardSeconds: String? {
        guard let value = stopToClipboard else { return nil }
        return Self.dutchSeconds(value)
    }

    /// Detailed debug summary (behind the `showLatencyHUD` flag). Omits the
    /// partial field entirely when the engine emitted no partials.
    var debugLine: String {
        func fmt(_ value: Double?) -> String {
            guard let value else { return "–" }
            return String(format: "%.2fs", value)
        }
        var parts: [String] = []
        if hadPartials {
            parts.append("partial \(fmt(timeToFirstPartial))")
        }
        parts.append("final \(fmt(stopToFinalized))")
        parts.append("plak \(fmt(stopToClipboard))")
        return parts.joined(separator: " · ")
    }

    /// Formats seconds with a Dutch decimal comma and one decimal, e.g. `0,7 s`.
    static func dutchSeconds(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let whole = Int(rounded)
        let tenths = Int((rounded - Double(whole)) * 10 + 0.5)
        return "\(whole),\(tenths) s"
    }
}

/// Records latency timestamps against a monotonic clock and emits os_signpost
/// intervals + an `.info` summary. Not thread-confined by design: the owning
/// `DictationController` is `@MainActor`, so it is only touched there.
final class LatencyRecorder {
    static let subsystem = "nl.nielscroiset.whisperclipboard"

    private let log = Logger(subsystem: subsystem, category: "latency")
    private let signposter = OSSignposter(
        subsystem: subsystem,
        category: "latency"
    )

    private(set) var metrics = LatencyMetrics()
    private var recordState: OSSignpostIntervalState?

    /// Monotonic seconds since an arbitrary reference — safe against wall-clock changes.
    private func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    func begin() {
        metrics = LatencyMetrics()
        metrics.recordStart = now()
        recordState = signposter.beginInterval("dictation")
    }

    func markFirstPartial() {
        guard metrics.firstPartial == nil else { return }
        metrics.firstPartial = now()
        signposter.emitEvent("firstPartial")
    }

    func markStop() {
        metrics.stop = now()
        signposter.emitEvent("stop")
    }

    func markFinalized() {
        metrics.finalized = now()
        signposter.emitEvent("finalized")
    }

    func markClipboard() {
        metrics.clipboard = now()
        signposter.emitEvent("clipboard")
        if let recordState {
            signposter.endInterval("dictation", recordState)
            self.recordState = nil
        }
        log.info("Dictation latency: \(self.metrics.debugLine, privacy: .public)")
    }
}
