import Core
import Foundation
import Observation

/// The live state of an AI mode running against a transcript, observed by the UI.
@MainActor
@Observable
final class AIRun: Identifiable {
    let id = UUID()
    let transcriptId: String
    let mode: AIMode
    /// Text accumulated so far (streams in).
    private(set) var output: String = ""
    private(set) var isRunning = true
    /// A Dutch error message when the run failed.
    private(set) var errorMessage: String?

    init(transcriptId: String, mode: AIMode) {
        self.transcriptId = transcriptId
        self.mode = mode
    }

    func append(_ chunk: String) { output += chunk }
    func fail(_ message: String) {
        errorMessage = message
        isRunning = false
    }
    func finish() { isRunning = false }
}

/// @MainActor observable service owning AI modes (built-in + custom) and running
/// them against transcripts. Completed runs are persisted into the `ai_results`
/// table via ``HistoryStore``; multiple results per transcript are allowed
/// (rerun appends a new one). Errors surface on the ``AIRun`` for the UI to show
/// — never as notifications.
@MainActor
@Observable
final class ModesService {

    /// User-defined modes, loaded from and saved to `modes.json`.
    private(set) var customModes: [AIMode] = []

    /// In-flight runs, keyed by their `AIRun.id`. The UI renders these live.
    private(set) var activeRuns: [AIRun] = []

    private let history: HistoryStore
    private let modesURL: URL
    /// Supplies the current API key (read from the Keychain). Injectable for tests.
    private let apiKeyProvider: () -> String?
    /// Builds a client for a key. Injectable so tests can stub the network.
    private let clientFactory: (String) -> ClaudeClient

    init(
        history: HistoryStore,
        modesURL: URL? = nil,
        apiKeyProvider: @escaping () -> String? = { try? KeychainStore.read() },
        clientFactory: @escaping (String) -> ClaudeClient = { ClaudeClient(apiKey: $0) }
    ) {
        self.history = history
        self.modesURL = modesURL ?? Self.defaultModesURL()
        self.apiKeyProvider = apiKeyProvider
        self.clientFactory = clientFactory
        loadCustomModes()
    }

    // MARK: - Mode listing / CRUD

    /// All modes shown to the user: built-ins first, then custom.
    var allModes: [AIMode] {
        AIMode.builtins + customModes
    }

    /// Whether an API key is configured.
    var hasAPIKey: Bool {
        (apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    /// Adds a new custom mode (forced non-builtin, fresh id) and persists.
    @discardableResult
    func addMode(name: String, systemPrompt: String, icon: String) throws -> AIMode {
        let mode = AIMode(name: name, systemPrompt: systemPrompt, icon: icon, isBuiltin: false)
        customModes.append(mode)
        try saveCustomModes()
        return mode
    }

    /// Updates an existing custom mode in place. Built-in ids are ignored.
    func updateMode(_ mode: AIMode) throws {
        guard !mode.isBuiltin, let index = customModes.firstIndex(where: { $0.id == mode.id }) else {
            return
        }
        customModes[index] = mode
        try saveCustomModes()
    }

    /// Deletes a custom mode by id. Built-in ids are ignored.
    func deleteMode(id: String) throws {
        customModes.removeAll { $0.id == id && !$0.isBuiltin }
        try saveCustomModes()
    }

    /// Creates an editable copy of any mode (used to duplicate a built-in).
    @discardableResult
    func duplicate(_ mode: AIMode) throws -> AIMode {
        try addMode(
            name: "\(mode.name) (kopie)",
            systemPrompt: mode.systemPrompt,
            icon: mode.icon
        )
    }

    // MARK: - Running a mode

    /// Runs `mode` against `transcript`, streaming into a returned ``AIRun``. On
    /// success the result is persisted to `ai_results`. On failure the run
    /// carries a Dutch error message.
    @discardableResult
    func run(mode: AIMode, on transcript: TranscriptEntry) -> AIRun {
        let run = AIRun(transcriptId: transcript.id, mode: mode)
        activeRuns.append(run)

        guard let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else {
            run.fail(ClaudeError.missingKey.localizedDescription)
            return run
        }

        let client = clientFactory(key)
        Task { [weak self] in
            do {
                for try await chunk in client.complete(system: mode.systemPrompt, user: transcript.text) {
                    run.append(chunk)
                }
                run.finish()
                self?.persist(run: run)
            } catch let error as ClaudeError {
                run.fail(error.localizedDescription)
            } catch {
                run.fail(ClaudeError.server(error.localizedDescription).localizedDescription)
            }
            self?.removeActive(run)
        }
        return run
    }

    /// Convenience for the menu bar: run a mode and return the full text (or throw).
    func runToCompletion(mode: AIMode, on transcript: TranscriptEntry) async throws -> AIResult {
        guard let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else {
            throw ClaudeError.missingKey
        }
        let client = clientFactory(key)
        let text = try await client.completeText(system: mode.systemPrompt, user: transcript.text)
        let result = AIResult(
            id: UUID().uuidString,
            transcriptId: transcript.id,
            modeId: mode.id,
            modeName: mode.name,
            output: text,
            createdAt: Date()
        )
        try? history.addAIResult(result)
        return result
    }

    /// Persisted results for a transcript, newest first.
    func results(for transcriptId: String) -> [AIResult] {
        (try? history.aiResults(forTranscript: transcriptId)) ?? []
    }

    /// Deletes a stored AI result.
    func deleteResult(id: String) {
        try? history.deleteAIResult(id: id)
    }

    // MARK: - Internals

    private func persist(run: AIRun) {
        let trimmed = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let result = AIResult(
            id: UUID().uuidString,
            transcriptId: run.transcriptId,
            modeId: run.mode.id,
            modeName: run.mode.name,
            output: run.output,
            createdAt: Date()
        )
        try? history.addAIResult(result)
    }

    private func removeActive(_ run: AIRun) {
        activeRuns.removeAll { $0.id == run.id }
    }

    // MARK: - Persistence of custom modes

    static func defaultModesURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Whisper Clipboard v2", isDirectory: true)
            .appendingPathComponent("modes.json", isDirectory: false)
    }

    private func loadCustomModes() {
        guard let data = try? Data(contentsOf: modesURL) else {
            customModes = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([AIMode].self, from: data)
            // Defensively drop any builtins that may have been written in.
            customModes = decoded.filter { !$0.isBuiltin }
        } catch {
            NSLog("ModesService: could not decode modes.json: %@", String(describing: error))
            customModes = []
        }
    }

    private func saveCustomModes() throws {
        try FileManager.default.createDirectory(
            at: modesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(customModes)
        try data.write(to: modesURL, options: .atomic)
    }
}
