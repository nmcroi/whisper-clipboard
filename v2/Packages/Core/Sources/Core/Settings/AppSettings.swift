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
    public var saveRecordings: Bool
    /// `nil` means unlimited history retention.
    public var historyRetention: Int?
    public var initialPrompt: String

    public init(
        hotkeyMode: HotkeyMode = .toggle,
        language: String = "nl",
        engine: Engine = .parakeet,
        cleanOutput: Bool = true,
        replacements: [Replacement] = [],
        directInsertion: Bool = false,
        saveRecordings: Bool = false,
        historyRetention: Int? = nil,
        initialPrompt: String = ""
    ) {
        self.hotkeyMode = hotkeyMode
        self.language = language
        self.engine = engine
        self.cleanOutput = cleanOutput
        self.replacements = replacements
        self.directInsertion = directInsertion
        self.saveRecordings = saveRecordings
        self.historyRetention = historyRetention
        self.initialPrompt = initialPrompt
    }
}
