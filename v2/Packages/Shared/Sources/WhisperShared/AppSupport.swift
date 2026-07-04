import Foundation

/// Small shared helpers for the app's on-disk state under Application Support.
///
/// Two things were previously copy-pasted across several stores:
///  1. The `.applicationSupportDirectory` lookup (with a `~/Library/Application
///     Support` fallback for the rare case it's unavailable).
///  2. A tiny "set of string identities persisted as a sorted JSON array" store,
///     duplicated near-verbatim by the watched-folder and PLAUD features.
///
/// Both are centralized here so there is exactly one implementation of each.
public enum AppSupport {

    /// The app's own folder under Application Support: `~/Library/Application
    /// Support/Whisper Clipboard v2/`. All v2 state lives here.
    ///
    /// On iOS this resolves inside the app's own sandboxed Application Support
    /// directory (a per-app container), so the iOS history DB is naturally
    /// isolated from the Mac's — no path munging needed. The folder name is kept
    /// identical on purpose so a future iCloud/CloudKit sync round has a stable,
    /// matching layout on both platforms.
    public static let folderName = "Whisper Clipboard v2"

    /// The raw `.applicationSupportDirectory` (or a `~/Library/Application
    /// Support` fallback when it can't be resolved).
    public static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// The app's base directory: `<Application Support>/Whisper Clipboard v2/`.
    public static var baseDirectory: URL {
        applicationSupportDirectory.appendingPathComponent(folderName, isDirectory: true)
    }
}

// MARK: - JSONIdentitySet

/// A tiny, best-effort persistence for a `Set<String>` of opaque identities,
/// stored as a **sorted JSON array** in one file under the app's base directory.
///
/// This is the shared implementation behind both the watched-folder processed
/// set (`watched-processed.json`) and the PLAUD processed set
/// (`plaud-processed.json`). The on-disk format is a plain `[String]` — exactly
/// what the two feature-specific stores wrote before — so existing files load
/// unchanged and no state is lost.
///
/// Saving is best-effort: failures are logged and swallowed so a read-only disk
/// can never break the feature that depends on it.
public struct JSONIdentitySet {

    private let fileURL: URL

    /// Points at `<base>/<filename>` under Application Support. Pass an explicit
    /// `fileURL` (tests) to redirect it elsewhere.
    public init(filename: String, fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? AppSupport.baseDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    /// Loads the persisted identities, or an empty set when absent/unreadable.
    public func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    /// Persists `ids` as a sorted JSON array (atomic write). Best-effort.
    public func save(_ ids: Set<String>) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Array(ids).sorted())
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("JSONIdentitySet(%@): failed to save (%@)", fileURL.lastPathComponent, String(describing: error))
        }
    }
}
