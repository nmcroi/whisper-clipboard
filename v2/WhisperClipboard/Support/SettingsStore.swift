import Core
import Foundation

/// Persists `AppSettings` as JSON under Application Support. The AI API key is
/// deliberately NOT part of this — it lives in the Keychain (`KeychainStore`).
///
/// Loading tolerates a missing or corrupt file by returning defaults; saving is
/// best-effort (failures are logged, never thrown) so a read-only disk can't
/// break dictation.
enum SettingsStore {

    private static let folderName = "Whisper Clipboard v2"
    private static let fileName = "settings.json"

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(fileName)
    }

    /// Loads persisted settings, or defaults when absent/unreadable.
    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return AppSettings() }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            NSLog("SettingsStore: failed to decode settings (%@); using defaults.", String(describing: error))
            return AppSettings()
        }
    }

    /// Persists `settings`. Best-effort: logs and swallows failures.
    static func save(_ settings: AppSettings) {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("SettingsStore: failed to save settings: %@", String(describing: error))
        }
    }
}
