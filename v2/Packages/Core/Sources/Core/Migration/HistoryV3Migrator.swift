import Foundation

/// Parses the v3 `history.json` schema written by the Python app
/// (`{"version": 3, "entries": [...]}`) into `[TranscriptEntry]`.
public enum HistoryV3Migrator {

    public struct Result: Sendable {
        public let entries: [TranscriptEntry]
        public let skippedCount: Int

        public init(entries: [TranscriptEntry], skippedCount: Int) {
            self.entries = entries
            self.skippedCount = skippedCount
        }
    }

    public enum MigrationError: Error, Sendable {
        case notAnObject
        case missingEntriesArray
    }

    /// Parses raw v3 `history.json` data. Malformed individual entries are
    /// skipped (not counted as a hard failure) so that one bad row does not
    /// take down the whole migration; only a fundamentally unparsable
    /// top-level document throws.
    public static func migrate(data: Data) throws -> Result {
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = jsonObject as? [String: Any] else {
            throw MigrationError.notAnObject
        }
        guard let rawEntries = root["entries"] as? [Any] else {
            throw MigrationError.missingEntriesArray
        }

        var entries: [TranscriptEntry] = []
        var skipped = 0
        let decoder = JSONDecoder()

        for rawEntry in rawEntries {
            guard JSONSerialization.isValidJSONObject(rawEntry) || rawEntry is [String: Any] else {
                skipped += 1
                continue
            }
            guard let dict = rawEntry as? [String: Any] else {
                skipped += 1
                continue
            }
            do {
                let entryData = try JSONSerialization.data(withJSONObject: dict, options: [])
                let entry = try decoder.decode(TranscriptEntry.self, from: entryData)
                entries.append(entry)
            } catch {
                skipped += 1
                continue
            }
        }

        return Result(entries: entries, skippedCount: skipped)
    }

    /// Convenience overload that reads and parses a history.json file at
    /// the given URL.
    public static func migrate(contentsOf url: URL) throws -> Result {
        let data = try Data(contentsOf: url)
        return try migrate(data: data)
    }
}
