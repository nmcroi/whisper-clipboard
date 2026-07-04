import Core
import Foundation
import WhisperShared

/// Writes every newly completed transcript to a user-chosen folder on disk, in a
/// user-chosen format, when auto-export is enabled.
///
/// This is deliberately a thin, best-effort side-effect invoked from the single
/// history-write chokepoint (``HistoryStore/add(_:)`` callers). It reuses
/// ``Core/Exporter`` for both the filename (`suggestedExportName`) and the
/// rendering/writing (`exportEntry`), so the on-disk files match the manual
/// export exactly. A failure here NEVER propagates: transcription must not break
/// because a disk is full or a folder was deleted — we log and, at most, post a
/// one-time Dutch notification.
@MainActor
final class AutoExportService {

    private let settings: () -> AppSettings
    private let notify: (String) -> Void
    /// Resolves a stored security-scoped bookmark for the export directory to a
    /// live URL (starting access), or `nil` to fall back to the plain path. The
    /// app is non-sandboxed, so the plain path works; the bookmark path is only
    /// exercised when the user picked the folder via `NSOpenPanel`.
    private let resolveBookmark: (String) -> URL?

    /// We only nag about a broken destination once per app run to avoid spamming
    /// the user on a folder that stays unwritable across many transcripts.
    private var didNotifyFailure = false

    init(
        settings: @escaping () -> AppSettings,
        resolveBookmark: @escaping (String) -> URL? = { AutomationBookmarks.resolveDirectory(forKey: $0) },
        notify: @escaping (String) -> Void = { Notifications.post($0) }
    ) {
        self.settings = settings
        self.resolveBookmark = resolveBookmark
        self.notify = notify
    }

    /// Exports `entry` if auto-export is enabled and a destination is configured.
    /// No-op (silent) when disabled or unconfigured. Never throws.
    func exportIfEnabled(_ entry: TranscriptEntry) {
        let config = settings()
        guard config.autoExportEnabled else { return }
        let rawDirectory = config.autoExportDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawDirectory.isEmpty else { return }

        let format = ExportFormat(suffix: config.autoExportFormat) ?? .markdown
        let fileName = Exporter.suggestedExportName(for: entry, extension: format.fileExtension)

        // Prefer a security-scoped bookmark when one was stored; else plain path.
        let scoped = resolveBookmark(AutomationBookmarks.autoExportKey)
        let directoryURL = scoped ?? URL(fileURLWithPath: rawDirectory, isDirectory: true)
        defer { if let scoped { scoped.stopAccessingSecurityScopedResource() } }

        let destination = uniqueDestination(in: directoryURL, fileName: fileName)
        do {
            try Exporter.exportEntry(entry, to: destination)
            // A successful write clears the "already warned" latch so a later
            // failure can notify again.
            didNotifyFailure = false
        } catch {
            NSLog("AutoExportService: export failed for %@ → %@: %@",
                  fileName, destination.path, String(describing: error))
            if !didNotifyFailure {
                didNotifyFailure = true
                notify("Automatisch exporteren mislukte — controleer de exportmap in Instellingen")
            }
        }
    }

    /// Returns a destination URL that does not clobber an existing file: if
    /// `<dir>/<name>.<ext>` exists, appends "-2", "-3", … before the extension.
    /// Two transcripts named "Zonder titel" should not overwrite each other.
    private func uniqueDestination(in directory: URL, fileName: String) -> URL {
        let candidate = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let ns = fileName as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            index += 1
            // Defensive ceiling; effectively unreachable.
            if index > 10_000 { return url }
        }
    }
}
