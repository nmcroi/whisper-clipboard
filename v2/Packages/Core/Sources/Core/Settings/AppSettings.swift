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

    public var hotkeyMode: HotkeyMode
    public var language: String
    public var engine: Engine
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

    public init(
        hotkeyMode: HotkeyMode = .toggle,
        language: String = "nl",
        engine: Engine = .parakeet,
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
        hudLingerSeconds: Double = 3.0
    ) {
        self.hotkeyMode = hotkeyMode
        self.language = language
        self.engine = engine
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
    }

    // Tolerant decoding: any key missing from an older/newer on-disk settings.json
    // falls back to the default rather than failing the whole load. This lets new
    // fields (e.g. `insertionDeniedBundleIds`) be added without breaking existing files.
    private enum CodingKeys: String, CodingKey {
        case hotkeyMode, language, engine, cleanOutput, replacements
        case directInsertion, insertionDeniedBundleIds, saveRecordings, saveCaptions
        case translateCaptionsToDutch
        case diarizeImports
        case historyRetention, initialPrompt, hudLingerSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        self.hotkeyMode = try c.decodeIfPresent(HotkeyMode.self, forKey: .hotkeyMode) ?? d.hotkeyMode
        self.language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        self.engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? d.engine
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
    }
}
