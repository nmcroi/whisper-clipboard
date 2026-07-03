import Foundation

/// Pure decision logic for the watched-folder auto-transcribe feature.
///
/// The live ``WatchedFolderService`` (app target) periodically scans its watched
/// directories and feeds the results here to decide which files are ready to be
/// enqueued for transcription. Keeping the decision pure — a function over
/// (currentScan, previousScan, processedSet) → filesToEnqueue — makes the tricky
/// "is this file new, stable, and not-yet-processed?" rule fully unit-testable
/// without touching the real filesystem.
public enum WatchedFolderLogic {

    /// A single file observed during a directory scan: its path and the size +
    /// modification time used to (a) detect a still-being-copied file (size
    /// changes between scans) and (b) build a stable identity for the
    /// processed-set so a restart never reprocesses the same file.
    public struct ScannedFile: Equatable, Hashable, Sendable {
        public let path: String
        public let size: Int64
        /// Modification time as a Unix timestamp (seconds). Whole seconds are
        /// enough for identity and avoid float-equality fuzz.
        public let modifiedAt: Int64

        public init(path: String, size: Int64, modifiedAt: Int64) {
            self.path = path
            self.size = size
            self.modifiedAt = modifiedAt
        }

        /// The stable identity persisted in the processed-set: path + mtime +
        /// size. If any of these change (a file is replaced with new content),
        /// it is treated as a new file worth transcribing again.
        public var identity: String {
            "\(path)|\(modifiedAt)|\(size)"
        }
    }

    /// Decides which files from `currentScan` should be enqueued for
    /// transcription this tick.
    ///
    /// A file is enqueued only when ALL hold:
    /// 1. **Stable** — it appeared in `previousScan` with the *same size*, so a
    ///    partial copy still growing on disk is skipped until it settles. (A
    ///    brand-new file seen for the first time is deliberately held back one
    ///    tick to let it stabilize.)
    /// 2. **Not already processed** — its ``ScannedFile/identity`` is not in
    ///    `processed`, so restarts and re-scans never reprocess the same file.
    ///
    /// The result preserves `currentScan`'s order and never contains duplicates.
    ///
    /// - Parameters:
    ///   - currentScan: files present in the watched folders this tick.
    ///   - previousScan: files present on the previous tick (empty on first run).
    ///   - processed: identities of files already handed to the importer.
    /// - Returns: the subset of `currentScan` to enqueue now.
    public static func filesToEnqueue(
        currentScan: [ScannedFile],
        previousScan: [ScannedFile],
        processed: Set<String>
    ) -> [ScannedFile] {
        // Index the previous scan by path for O(1) size-stability lookups.
        var previousByPath: [String: ScannedFile] = [:]
        previousByPath.reserveCapacity(previousScan.count)
        for file in previousScan {
            previousByPath[file.path] = file
        }

        var result: [ScannedFile] = []
        var emitted = Set<String>()
        for file in currentScan {
            // Skip anything we've already processed (by full identity).
            guard !processed.contains(file.identity) else { continue }
            // Require a stable size across the two most-recent scans.
            guard let previous = previousByPath[file.path], previous.size == file.size else { continue }
            // Guard against a (pathological) duplicate path within one scan.
            guard emitted.insert(file.identity).inserted else { continue }
            result.append(file)
        }
        return result
    }
}
