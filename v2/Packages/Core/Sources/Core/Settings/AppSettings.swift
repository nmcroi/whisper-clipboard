import Foundation

/// v2 application settings. Carries over the fields from the Python
/// `AppConfig` dataclass that remain relevant to the native rebuild
/// (dropping process-launch/model-path plumbing that v2's engine
/// abstraction replaces). No file I/O lives here by design — loading and
/// persisting settings is the caller's responsibility.
public struct AppSettings: Codable, Equatable, Sendable {

    public enum HotkeyMode: String, Codable, Sendable {
        case toggle
        case pushToTalk
    }

    public enum Engine: String, Codable, Sendable {
        case appleSpeech
        case parakeet
    }

    /// UI colour scheme preference. `system` follows macOS; `dark` and `light`
    /// pin the app to a fixed appearance. Dark is the default — it is the
    /// signature look of the app; light is opt-in.
    public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
        case system
        case dark
        case light
    }

    public var hotkeyMode: HotkeyMode
    public var language: String
    public var engine: Engine
    /// UI colour scheme (Systeem / Donker / Licht). Defaults to `.dark`.
    public var appearance: AppearanceMode
    public var cleanOutput: Bool
    public var replacements: [Replacement]
    public var directInsertion: Bool
    /// Bundle identifiers of apps into which direct insertion is suppressed
    /// (clipboard-only for that run). Case-insensitive matching at use site.
    public var insertionDeniedBundleIds: [String]
    public var saveRecordings: Bool
    /// Save the full transcript of a live-captions session to history on stop.
    public var saveCaptions: Bool
    /// Translate live-caption FINAL lines to Dutch via Apple's Translation
    /// framework. Volatile (in-progress) lines are never translated.
    public var translateCaptionsToDutch: Bool
    /// Detect speakers ("Spreker 1/2/…") when importing audio/video files.
    /// Default on; runs an extra on-device diarization pass after transcription.
    public var diarizeImports: Bool
    /// `nil` means unlimited history retention.
    public var historyRetention: Int?
    public var initialPrompt: String
    /// How long (seconds) the HUD lingers on its "finished" confirmation state
    /// after a successful dictation before auto-hiding. Clamped to 1...10 at
    /// the call site; error linger stays a fixed, shorter duration.
    public var hudLingerSeconds: Double

    // MARK: - Automation (M7)

    /// Remove conservative filler words/sounds ("eh", "uh", "ehm"…) from every
    /// transcript (dictation, import, captions). Off by default. See
    /// ``TextProcessor/removeFillers(_:language:)`` for the exact list.
    public var removeFillers: Bool
    /// Automatically write every newly completed transcript to a folder on disk.
    public var autoExportEnabled: Bool
    /// Destination directory for auto-export (a plain filesystem path; the app is
    /// non-sandboxed). Empty disables the export even when the toggle is on.
    public var autoExportDirectory: String
    /// Export format for auto-export: one of `txt`, `md`, `srt`, `vtt`, `json`.
    /// Stored as the ``ExportFormat`` raw value; falls back to `md` when unknown.
    public var autoExportFormat: String
    /// Filesystem paths of folders watched for new audio/video files to
    /// auto-transcribe. Empty = watching disabled.
    public var watchedFolders: [String]

    // MARK: - PLAUD cloud sync

    /// Automatically pull recordings from PLAUD's cloud and run them through the
    /// transcription pipeline. Off by default (opt-in; needs credentials).
    public var plaudSyncEnabled: Bool
    /// Poll interval (minutes) when PLAUD sync is enabled. Clamped to a sane range
    /// at the call site. Default 15.
    public var plaudSyncIntervalMinutes: Int
    /// The PLAUD account email. Shown in Settings; the password/token live **only**
    /// in the Keychain (never here). Empty = not configured.
    public var plaudEmail: String

    public init(
        hotkeyMode: HotkeyMode = .toggle,
        language: String = "nl",
        engine: Engine = .parakeet,
        appearance: AppearanceMode = .dark,
        cleanOutput: Bool = true,
        replacements: [Replacement] = [],
        directInsertion: Bool = false,
        insertionDeniedBundleIds: [String] = [],
        saveRecordings: Bool = false,
        saveCaptions: Bool = false,
        translateCaptionsToDutch: Bool = false,
        diarizeImports: Bool = true,
        historyRetention: Int? = nil,
        initialPrompt: String = "",
        hudLingerSeconds: Double = 3.0,
        removeFillers: Bool = false,
        autoExportEnabled: Bool = false,
        autoExportDirectory: String = "",
        autoExportFormat: String = "md",
        watchedFolders: [String] = [],
        plaudSyncEnabled: Bool = false,
        plaudSyncIntervalMinutes: Int = 15,
        plaudEmail: String = ""
    ) {
        self.hotkeyMode = hotkeyMode
        self.language = language
        self.engine = engine
        self.appearance = appearance
        self.cleanOutput = cleanOutput
        self.replacements = replacements
        self.directInsertion = directInsertion
        self.insertionDeniedBundleIds = insertionDeniedBundleIds
        self.saveRecordings = saveRecordings
        self.saveCaptions = saveCaptions
        self.translateCaptionsToDutch = translateCaptionsToDutch
        self.diarizeImports = diarizeImports
        self.historyRetention = historyRetention
        self.initialPrompt = initialPrompt
        self.hudLingerSeconds = hudLingerSeconds
        self.removeFillers = removeFillers
        self.autoExportEnabled = autoExportEnabled
        self.autoExportDirectory = autoExportDirectory
        self.autoExportFormat = autoExportFormat
        self.watchedFolders = watchedFolders
        self.plaudSyncEnabled = plaudSyncEnabled
        self.plaudSyncIntervalMinutes = plaudSyncIntervalMinutes
        self.plaudEmail = plaudEmail
    }

    // Tolerant decoding: any key missing from an older/newer on-disk settings.json
    // falls back to the default rather than failing the whole load. This lets new
    // fields (e.g. `insertionDeniedBundleIds`) be added without breaking existing files.
    private enum CodingKeys: String, CodingKey {
        case hotkeyMode, language, engine, appearance, cleanOutput, replacements
        case directInsertion, insertionDeniedBundleIds, saveRecordings, saveCaptions
        case translateCaptionsToDutch
        case diarizeImports
        case historyRetention, initialPrompt, hudLingerSeconds
        case removeFillers, autoExportEnabled, autoExportDirectory, autoExportFormat, watchedFolders
        case plaudSyncEnabled, plaudSyncIntervalMinutes, plaudEmail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        self.hotkeyMode = try c.decodeIfPresent(HotkeyMode.self, forKey: .hotkeyMode) ?? d.hotkeyMode
        self.language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        self.engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? d.engine
        self.appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? d.appearance
        self.cleanOutput = try c.decodeIfPresent(Bool.self, forKey: .cleanOutput) ?? d.cleanOutput
        self.replacements = try c.decodeIfPresent([Replacement].self, forKey: .replacements) ?? d.replacements
        self.directInsertion = try c.decodeIfPresent(Bool.self, forKey: .directInsertion) ?? d.directInsertion
        self.insertionDeniedBundleIds = try c.decodeIfPresent([String].self, forKey: .insertionDeniedBundleIds) ?? d.insertionDeniedBundleIds
        self.saveRecordings = try c.decodeIfPresent(Bool.self, forKey: .saveRecordings) ?? d.saveRecordings
        self.saveCaptions = try c.decodeIfPresent(Bool.self, forKey: .saveCaptions) ?? d.saveCaptions
        self.translateCaptionsToDutch = try c.decodeIfPresent(Bool.self, forKey: .translateCaptionsToDutch) ?? d.translateCaptionsToDutch
        self.diarizeImports = try c.decodeIfPresent(Bool.self, forKey: .diarizeImports) ?? d.diarizeImports
        self.historyRetention = try c.decodeIfPresent(Int.self, forKey: .historyRetention) ?? d.historyRetention
        self.initialPrompt = try c.decodeIfPresent(String.self, forKey: .initialPrompt) ?? d.initialPrompt
        self.hudLingerSeconds = try c.decodeIfPresent(Double.self, forKey: .hudLingerSeconds) ?? d.hudLingerSeconds
        self.removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? d.removeFillers
        self.autoExportEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoExportEnabled) ?? d.autoExportEnabled
        self.autoExportDirectory = try c.decodeIfPresent(String.self, forKey: .autoExportDirectory) ?? d.autoExportDirectory
        self.autoExportFormat = try c.decodeIfPresent(String.self, forKey: .autoExportFormat) ?? d.autoExportFormat
        self.watchedFolders = try c.decodeIfPresent([String].self, forKey: .watchedFolders) ?? d.watchedFolders
        self.plaudSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .plaudSyncEnabled) ?? d.plaudSyncEnabled
        self.plaudSyncIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .plaudSyncIntervalMinutes) ?? d.plaudSyncIntervalMinutes
        self.plaudEmail = try c.decodeIfPresent(String.self, forKey: .plaudEmail) ?? d.plaudEmail
    }
}
