import Foundation

/// Pure decision logic for PLAUD cloud sync.
///
/// The live `PlaudSyncService` (app target) fetches the recording list from
/// PLAUD's cloud and feeds the ids here, together with the set of ids it has
/// already processed, to decide which recordings are new and must be downloaded
/// + transcribed. Keeping the decision pure — a function over
/// (fetchedIds, processedSet) → idsToDownload — makes the "is this recording
/// new?" rule fully unit-testable without any network.
///
/// De-duplication mirrors the watched-folder feature: a small
/// `plaud-processed.json` persists the processed recording ids across launches,
/// so relaunching never re-downloads a recording already run through the
/// pipeline. The dedup key is PLAUD's stable recording `id`.
public enum PlaudSyncLogic {

    /// Returns the ids from `fetchedIds`, in order, that are **not** already in
    /// `processed`. Preserves input order (PLAUD returns newest-first) and drops
    /// blanks/duplicates within the same batch.
    public static func newRecordingIds(fetchedIds: [String], processed: Set<String>) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in fetchedIds {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !processed.contains(trimmed) else { continue }
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    /// Whether any of `fetchedIds` is new relative to `processed`.
    public static func hasNewRecordings(fetchedIds: [String], processed: Set<String>) -> Bool {
        !newRecordingIds(fetchedIds: fetchedIds, processed: processed).isEmpty
    }

    /// Clamps a user-entered poll interval (minutes) to a sane range so a typo
    /// can't hammer PLAUD or effectively disable polling. 1 minute floor, 24 hour
    /// ceiling.
    public static func clampIntervalMinutes(_ minutes: Int) -> Int {
        min(max(minutes, 1), 24 * 60)
    }

    // MARK: - Sync window

    /// The earliest recording start-time a sync of `windowDays` should consider,
    /// relative to `now`. `windowDays <= 0` means "no window" (all history) → nil.
    /// Negative day counts are treated as 0 (defensive; the UI clamps to ≥ 0).
    public static func windowCutoff(windowDays: Int, now: Date) -> Date? {
        guard windowDays > 0 else { return nil }
        return now.addingTimeInterval(-Double(windowDays) * 24 * 60 * 60)
    }

    /// The effective `since` to hand PLAUD's list endpoint, combining the persisted
    /// checkpoint (minus an overlap margin, so a recording that landed slightly out
    /// of order is never missed) with the sync window:
    ///
    /// - `windowDays == 0` → checkpoint-only behaviour: `checkpoint − overlap`, or
    ///   `nil` on a first run (no checkpoint = list all history once).
    /// - `windowDays > 0` → the **later** (more recent) of the checkpoint bound and
    ///   the window cutoff, so even a first sync with an empty checkpoint only pulls
    ///   the last N days instead of the entire history. Once a checkpoint exists and
    ///   is newer than the cutoff, it wins (incremental sync stays cheap).
    public static func effectiveSince(
        checkpoint: Date?,
        overlap: TimeInterval,
        windowDays: Int,
        now: Date
    ) -> Date? {
        let checkpointBound = checkpoint.map { $0.addingTimeInterval(-overlap) }
        guard let cutoff = windowCutoff(windowDays: windowDays, now: now) else {
            // No window: pure checkpoint behaviour (nil on first run = all history).
            return checkpointBound
        }
        guard let checkpointBound else { return cutoff }
        // Both present: the more recent bound wins (never look back past the window,
        // and never re-list further than the checkpoint already covers).
        return max(checkpointBound, cutoff)
    }
}
