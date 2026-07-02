import Foundation

/// Pure debounce gate for start/stop transitions, factored out of
/// ``DictationController`` so it can be unit-tested deterministically by
/// injecting the clock.
///
/// A transition is allowed only when at least `interval` seconds have elapsed
/// since the previously accepted transition. The caller supplies the current
/// time, so tests need no real waiting.
struct TransitionDebouncer {
    let interval: TimeInterval
    private var lastAccepted: TimeInterval?

    init(interval: TimeInterval = 0.25) {
        self.interval = interval
    }

    /// Returns `true` and records the time if the transition is allowed.
    mutating func shouldAccept(now: TimeInterval) -> Bool {
        if let lastAccepted, now - lastAccepted < interval {
            return false
        }
        lastAccepted = now
        return true
    }

    /// Clears history so the next transition is always accepted.
    mutating func reset() {
        lastAccepted = nil
    }
}
