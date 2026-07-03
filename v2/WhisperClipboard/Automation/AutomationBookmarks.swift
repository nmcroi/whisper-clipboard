import AppKit
import Foundation

/// Security-scoped bookmark storage for automation folders (auto-export
/// destination + watched folders).
///
/// The app is **non-sandboxed**, so a plain filesystem path is sufficient for
/// reading/writing today. We still persist security-scoped bookmarks so the
/// feature keeps working if the app is ever sandboxed and so folder access
/// survives the folder being moved/renamed. Callers treat a resolved bookmark as
/// a best-effort upgrade over the plain path — everything degrades gracefully to
/// the path when no bookmark exists.
///
/// Bookmarks are keyed in `UserDefaults`:
/// - the auto-export destination under a single fixed key, and
/// - each watched folder under a per-path key (hashed), so multiple folders can
///   coexist.
enum AutomationBookmarks {

    /// `UserDefaults` key for the auto-export destination bookmark.
    static let autoExportKey = "automation.autoExport.bookmark"

    private static let watchedPrefix = "automation.watched.bookmark."

    // MARK: - Storing

    /// Creates and stores a security-scoped bookmark for `url` under `key`.
    /// Best-effort: logs and returns `false` on failure (the plain path still
    /// works for a non-sandboxed build).
    @discardableResult
    static func store(_ url: URL, forKey key: String, defaults: UserDefaults = .standard) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: key)
            return true
        } catch {
            NSLog("AutomationBookmarks: failed to create bookmark for %@: %@", url.path, String(describing: error))
            return false
        }
    }

    /// Removes any stored bookmark under `key`.
    static func remove(forKey key: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    // MARK: - Resolving

    /// Resolves a stored bookmark to a live URL and **starts** security-scoped
    /// access on it. The caller MUST balance a non-nil result with
    /// `url.stopAccessingSecurityScopedResource()`. Returns `nil` when no
    /// bookmark is stored or it can no longer be resolved.
    static func resolveDirectory(forKey key: String, defaults: UserDefaults = .standard) -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else { return nil }
            if isStale {
                // Refresh the stored bookmark so it keeps resolving next time.
                _ = store(url, forKey: key, defaults: defaults)
            }
            return url
        } catch {
            NSLog("AutomationBookmarks: failed to resolve bookmark for key %@: %@", key, String(describing: error))
            return nil
        }
    }

    // MARK: - Watched-folder helpers

    /// A stable per-path `UserDefaults` key for a watched folder's bookmark.
    static func watchedKey(forPath path: String) -> String {
        // A non-cryptographic stable hash is fine; we only need a unique,
        // deterministic key per path. `hashValue` is not stable across runs, so
        // derive one from the UTF-8 bytes (FNV-1a).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return watchedPrefix + String(hash, radix: 16)
    }

    /// Stores a bookmark for a watched folder (keyed by its path).
    @discardableResult
    static func storeWatched(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        store(url, forKey: watchedKey(forPath: url.path), defaults: defaults)
    }

    /// Resolves + starts access on a watched folder's bookmark (by path).
    static func resolveWatched(path: String, defaults: UserDefaults = .standard) -> URL? {
        resolveDirectory(forKey: watchedKey(forPath: path), defaults: defaults)
    }

    /// Removes a watched folder's stored bookmark (by path).
    static func removeWatched(path: String, defaults: UserDefaults = .standard) {
        remove(forKey: watchedKey(forPath: path), defaults: defaults)
    }
}
