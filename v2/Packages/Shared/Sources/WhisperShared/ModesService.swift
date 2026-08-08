import Core
import Foundation
import Observation

/// The live state of an AI mode running against a transcript, observed by the UI.
@MainActor
@Observable
public final class AIRun: Identifiable {
    public let id = UUID()
    public let transcriptId: String
    public let mode: AIMode
    /// Text accumulated so far (streams in).
    public private(set) var output: String = ""
    public private(set) var isRunning = true
    /// A Dutch error message when the run failed.
    public private(set) var errorMessage: String?

    public init(transcriptId: String, mode: AIMode) {
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
public final class ModesService {

    /// User-defined modes, loaded from and saved to `modes.json`.
    public private(set) var customModes: [AIMode] = []

    /// In-flight runs, keyed by their `AIRun.id`. The UI renders these live.
    public private(set) var activeRuns: [AIRun] = []
    public private(set) var totalInputTokens = 0
    public private(set) var totalOutputTokens = 0
    public private(set) var usageEvents: [UsageEvent] = []

    public struct UsageEvent: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let date: Date
        public let modeName: String
        public let inputTokens: Int
        public let outputTokens: Int
        /// Optioneel voor compatibiliteit met het bestaande Claude-ledger.
        public let provider: AIProvider?
        public let model: String?

        public var estimatedCostUSD: Double {
            let rates = Self.rates(provider: provider ?? .anthropic, model: model ?? "")
            return Double(inputTokens) * rates.input / 1_000_000
                + Double(outputTokens) * rates.output / 1_000_000
        }

        public init(
            id: UUID,
            date: Date,
            modeName: String,
            inputTokens: Int,
            outputTokens: Int,
            provider: AIProvider? = nil,
            model: String? = nil
        ) {
            self.id = id
            self.date = date
            self.modeName = modeName
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.provider = provider
            self.model = model
        }

        private static func rates(provider: AIProvider, model: String) -> (input: Double, output: Double) {
            let value = model.lowercased()
            switch provider {
            case .anthropic:
                if value.contains("opus-5") { return (5, 25) }
                if value.contains("haiku") { return (1, 5) }
                return (3, 15)
            case .openAI:
                if value.contains("luna") { return (1, 6) }
                if value.contains("terra") { return (2.5, 15) }
                if value.contains("sol") || value == "gpt-5.6" { return (5, 30) }
                return (2.5, 15)
            case .gemini:
                if value.contains("3.5-flash-lite") { return (0.30, 2.50) }
                if value.contains("3.5-flash") { return (1.50, 9.00) }
                return (1.50, 7.50)
            }
        }
    }

    private let history: HistoryStore
    private let modesURL: URL
    private let usageURL: URL
    private let providerProvider: () -> AIProvider
    private let modelProvider: (AIProvider) -> String
    /// Supplies the current provider's API key. Injectable for tests.
    private let apiKeyProvider: (AIProvider) -> String?
    /// Builds a provider client for a key. Injectable so tests can stub transport.
    private let clientFactory: (AIProvider, String) -> any AITextClient
    private var runTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        history: HistoryStore,
        modesURL: URL? = nil,
        providerProvider: @escaping () -> AIProvider = {
            let raw = UserDefaults.standard.string(forKey: "ai.defaultProvider") ?? ""
            return AIProvider(rawValue: raw) ?? .anthropic
        },
        modelProvider: @escaping (AIProvider) -> String = { provider in
            UserDefaults.standard.string(forKey: "ai.model.\(provider.rawValue)")
                ?? provider.defaultModel
        },
        apiKeyProvider: @escaping (AIProvider) -> String? = { try? KeychainStore.read(for: $0) },
        clientFactory: @escaping (AIProvider, String) -> any AITextClient = {
            AIClientFactory.make(provider: $0, apiKey: $1)
        }
    ) {
        self.history = history
        self.modesURL = modesURL ?? Self.defaultModesURL()
        self.usageURL = self.modesURL.deletingLastPathComponent().appendingPathComponent("ai-usage.json")
        self.providerProvider = providerProvider
        self.modelProvider = modelProvider
        self.apiKeyProvider = apiKeyProvider
        self.clientFactory = clientFactory
        loadCustomModes()
        loadUsage()
    }

    /// Broncompatibiliteit voor bestaande Claude-tests en oudere call-sites.
    public convenience init(
        history: HistoryStore,
        modesURL: URL?,
        apiKeyProvider: @escaping () -> String?,
        clientFactory: @escaping (String) -> ClaudeClient
    ) {
        self.init(
            history: history,
            modesURL: modesURL,
            providerProvider: { .anthropic },
            modelProvider: { _ in ClaudeClient.model },
            apiKeyProvider: { _ in apiKeyProvider() },
            clientFactory: { _, key in clientFactory(key) }
        )
    }

    // MARK: - Mode listing / CRUD

    /// All modes shown to the user: built-ins first, then custom.
    public var allModes: [AIMode] {
        AIMode.builtins + customModes
    }

    /// Whether an API key is configured.
    public var hasAPIKey: Bool {
        (apiKeyProvider(providerProvider())?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    public var currentProvider: AIProvider { providerProvider() }
    public var currentModel: String { modelProvider(providerProvider()) }

    /// Adds a new custom mode (forced non-builtin, fresh id) and persists.
    @discardableResult
    public func addMode(name: String, systemPrompt: String, icon: String) throws -> AIMode {
        let mode = AIMode(name: name, systemPrompt: systemPrompt, icon: icon, isBuiltin: false)
        customModes.append(mode)
        try saveCustomModes()
        return mode
    }

    /// Updates an existing custom mode in place. Built-in ids are ignored.
    public func updateMode(_ mode: AIMode) throws {
        guard !mode.isBuiltin, let index = customModes.firstIndex(where: { $0.id == mode.id }) else {
            return
        }
        customModes[index] = mode
        try saveCustomModes()
    }

    /// Deletes a custom mode by id. Built-in ids are ignored.
    public func deleteMode(id: String) throws {
        customModes.removeAll { $0.id == id && !$0.isBuiltin }
        try saveCustomModes()
    }

    /// Creates an editable copy of any mode (used to duplicate a built-in).
    @discardableResult
    public func duplicate(_ mode: AIMode) throws -> AIMode {
        try addMode(
            name: "\(mode.name) (kopie)",
            systemPrompt: mode.systemPrompt,
            icon: mode.icon
        )
    }

    // MARK: - Free-form one-off instruction

    /// The stable mode id used for free-form ("Eigen prompt") runs so they can
    /// be recognised in history and never collide with a saved mode.
    public static let freePromptModeId = "builtin.free_prompt"

    /// Builds the system prompt for a free-form instruction: a fixed framing that
    /// tells Claude to execute the user's instruction against the transcript, in
    /// Dutch, without preamble.
    public static func freeInstructionSystemPrompt(_ instruction: String) -> String {
        """
        Je bent een assistent die de volgende opdracht uitvoert op een \
        transcriptie. Antwoord in de taal van het transcript (meestal Nederlands), \
        zonder inleiding en zonder meta-opmerkingen — lever uitsluitend het \
        gevraagde resultaat.

        Opdracht: \(instruction.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// A short, single-line label derived from a free-form instruction, used as
    /// the result's `modeName` so history shows what was asked.
    public static func freePromptLabel(for instruction: String) -> String {
        let flattened = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let collapsed = flattened
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
        let prefix = "Eigen prompt: "
        let maxInstruction = 60
        if collapsed.count <= maxInstruction {
            return prefix + collapsed
        }
        let clipped = String(collapsed.prefix(maxInstruction)).trimmingCharacters(in: .whitespaces)
        return prefix + clipped + "…"
    }

    /// Builds a synthetic (non-builtin) ``AIMode`` that carries a free-form
    /// instruction as its system prompt, so the same streaming/persistence path
    /// as ``run(mode:on:)`` can drive it. The mode's `name` becomes the history
    /// label showing what was asked.
    public static func freeInstructionMode(_ instruction: String) -> AIMode {
        AIMode(
            id: freePromptModeId,
            name: freePromptLabel(for: instruction),
            systemPrompt: freeInstructionSystemPrompt(instruction),
            icon: "sparkles",
            category: .schrijven,
            isBuiltin: false
        )
    }

    /// Runs an arbitrary user instruction against `transcript` (not a saved
    /// mode), streaming into a returned ``AIRun`` and persisting the completed
    /// result exactly like ``run(mode:on:)``. The stored result's `modeName`
    /// reflects the instruction so history shows what was asked.
    @discardableResult
    public func run(instruction: String, on transcript: TranscriptEntry) -> AIRun {
        run(mode: Self.freeInstructionMode(instruction), on: transcript)
    }

    // MARK: - Running a mode

    /// Runs `mode` against `transcript`, streaming into a returned ``AIRun``. On
    /// success the result is persisted to `ai_results`. On failure the run
    /// carries a Dutch error message.
    @discardableResult
    public func run(mode: AIMode, on transcript: TranscriptEntry) -> AIRun {
        let run = AIRun(transcriptId: transcript.id, mode: mode)
        activeRuns.append(run)

        let provider = providerProvider()
        let model = modelProvider(provider)

        guard let key = apiKeyProvider(provider)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else {
            run.fail(AIServiceError.missingKey(provider).localizedDescription)
            return run
        }

        let client = clientFactory(provider, key)
        let task = Task { [weak self] in
            defer { self?.runTasks[run.id] = nil }
            do {
                let chunks = AITranscriptChunker.chunks(transcript.text)
                if chunks.count <= 1 {
                    try await self?.streamIntoRunWithRetry(
                        run,
                        client: client,
                        system: mode.systemPrompt,
                        user: transcript.text,
                        provider: provider,
                        model: model,
                        modeName: mode.name
                    )
                } else if let self {
                    let text = try await self.processLongTranscript(
                        chunks: chunks,
                        mode: mode,
                        provider: provider,
                        model: model,
                        client: client
                    )
                    run.append(text)
                }
                run.finish()
                self?.persist(run: run)
                // Only successful runs are removed from `activeRuns`. Failed runs
                // stay (with their errorMessage) so the UI can render the error
                // — mirroring the missing-key guard above, which also keeps the run.
                self?.removeActive(run)
            } catch is CancellationError {
                run.fail("Geannuleerd.")
            } catch {
                run.fail(Self.userMessage(for: error, provider: provider))
            }
        }
        runTasks[run.id] = task
        return run
    }

    /// Annuleert netwerk- en chunkwerk voor één actieve opdracht. Een gedeeltelijk
    /// antwoord wordt nooit als voltooid resultaat opgeslagen.
    public func cancel(_ run: AIRun) {
        runTasks[run.id]?.cancel()
    }

    /// Convenience for the menu bar: run a mode and return the full text (or throw).
    public func runToCompletion(mode: AIMode, on transcript: TranscriptEntry) async throws -> AIResult {
        let provider = providerProvider()
        let model = modelProvider(provider)
        guard let key = apiKeyProvider(provider)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else {
            throw AIServiceError.missingKey(provider)
        }
        let client = clientFactory(provider, key)
        let chunks = AITranscriptChunker.chunks(transcript.text)
        let text: String
        if chunks.count <= 1 {
            text = try await completeTextWithRetry(
                client: client,
                system: mode.systemPrompt,
                user: transcript.text,
                provider: provider,
                model: model,
                modeName: mode.name
            )
        } else {
            text = try await processLongTranscript(
                chunks: chunks,
                mode: mode,
                provider: provider,
                model: model,
                client: client
            )
        }
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
    public func results(for transcriptId: String) -> [AIResult] {
        (try? history.aiResults(forTranscript: transcriptId)) ?? []
    }

    /// Deletes a stored AI result.
    public func deleteResult(id: String) {
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

    /// Estimated standard Sonnet 5 cost ($3 input / $15 output per million
    /// tokens). Anthropic's invoice remains authoritative if pricing changes.
    public var estimatedCostUSD: Double {
        usageEvents.reduce(0) { $0 + $1.estimatedCostUSD }
    }

    private struct UsageLedger: Codable {
        var inputTokens: Int
        var outputTokens: Int
        var events: [UsageEvent]?
    }

    private func loadUsage() {
        guard let data = try? Data(contentsOf: usageURL),
              let ledger = try? JSONDecoder().decode(UsageLedger.self, from: data) else { return }
        totalInputTokens = ledger.inputTokens
        totalOutputTokens = ledger.outputTokens
        usageEvents = ledger.events ?? []
    }

    private func recordUsage(
        _ usage: AIUsage,
        modeName: String,
        provider: AIProvider,
        model: String
    ) {
        guard usage.inputTokens > 0 || usage.outputTokens > 0 else { return }
        totalInputTokens += usage.inputTokens
        totalOutputTokens += usage.outputTokens
        usageEvents.append(UsageEvent(
            id: UUID(),
            date: Date(),
            modeName: modeName,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            provider: provider,
            model: model
        ))
        let ledger = UsageLedger(
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens,
            events: usageEvents
        )
        if let data = try? JSONEncoder().encode(ledger) {
            try? data.write(to: usageURL, options: .atomic)
        }
    }

    private func completeTextWithRetry(
        client: any AITextClient,
        system: String,
        user: String,
        provider: AIProvider,
        model: String,
        modeName: String
    ) async throws -> String {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await client.completeText(
                    system: system,
                    user: user,
                    model: model,
                    onUsage: { [weak self] usage in
                        Task { @MainActor in
                            self?.recordUsage(
                                usage,
                                modeName: modeName,
                                provider: provider,
                                model: model
                            )
                        }
                    }
                )
            } catch {
                guard attempt < 3, Self.isRetryable(error) else { throw error }
                try await Task.sleep(for: .seconds(attempt == 1 ? 1 : 3))
            }
        }
    }

    /// Streamt een korte opdracht rechtstreeks naar de UI. Een tijdelijke fout
    /// vóór het eerste tekstdeel mag veilig opnieuw worden geprobeerd. Zodra er
    /// al tekst zichtbaar is, stoppen we bij een fout om dubbele of door elkaar
    /// geraakte output te voorkomen.
    private func streamIntoRunWithRetry(
        _ run: AIRun,
        client: any AITextClient,
        system: String,
        user: String,
        provider: AIProvider,
        model: String,
        modeName: String
    ) async throws {
        var attempt = 0
        while true {
            attempt += 1
            var emittedText = false
            do {
                for try await chunk in client.complete(
                    system: system,
                    user: user,
                    model: model,
                    onUsage: { [weak self] usage in
                        Task { @MainActor in
                            self?.recordUsage(
                                usage,
                                modeName: modeName,
                                provider: provider,
                                model: model
                            )
                        }
                    }
                ) {
                    if !chunk.isEmpty {
                        emittedText = true
                        run.append(chunk)
                    }
                }
                return
            } catch {
                guard !emittedText, attempt < 3, Self.isRetryable(error) else { throw error }
                try await Task.sleep(for: .seconds(attempt == 1 ? 1 : 3))
            }
        }
    }

    private func processLongTranscript(
        chunks: [String],
        mode: AIMode,
        provider: AIProvider,
        model: String,
        client: any AITextClient
    ) async throws -> String {
        var partials: [String] = []
        partials.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let instruction = """
            \(mode.systemPrompt)

            Dit is deel \(index + 1) van \(chunks.count) van één doorlopende transcriptie. \
            Verwerk uitsluitend dit deel. Behoud feiten, volgorde, besluiten, namen en \
            onzekerheden; verzin niets en herhaal geen inhoud uit andere delen.
            """
            let output = try await completeTextWithRetry(
                client: client,
                system: instruction,
                user: chunk,
                provider: provider,
                model: model,
                modeName: mode.name
            )
            partials.append(output)
        }

        let mergeInstruction = """
        Voeg de onderstaande deelresultaten samen tot één coherent eindresultaat volgens \
        deze oorspronkelijke opdracht:

        \(mode.systemPrompt)

        Verwijder alleen echte dubbelingen op deelgrenzen. Behoud alle unieke feiten, \
        besluiten, acties, onzekerheden en de oorspronkelijke volgorde. Verzin niets.
        """
        let joined = partials.enumerated().map { "--- Deel \($0.offset + 1) ---\n\($0.element)" }
            .joined(separator: "\n\n")
        return try await completeTextWithRetry(
            client: client,
            system: mergeInstruction,
            user: joined,
            provider: provider,
            model: model,
            modeName: "\(mode.name) — samenvoegen"
        )
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let service = error as? AIServiceError { return service.isRetryable }
        if let claude = error as? ClaudeError {
            switch claude {
            case .overloaded, .network: return true
            default: return false
            }
        }
        return false
    }

    private static func userMessage(for error: Error, provider: AIProvider) -> String {
        if let localized = error as? LocalizedError,
           let message = localized.errorDescription, !message.isEmpty { return message }
        return AIServiceError.server(provider, error.localizedDescription).localizedDescription
    }

    // MARK: - Persistence of custom modes

    static func defaultModesURL() -> URL {
        // Uses the shared Application Support base ("Whisper Clipboard v2"), which
        // resolves inside the app's own sandboxed container on iOS and under
        // ~/Library/Application Support on the Mac — no platform branching needed.
        AppSupport.baseDirectory.appendingPathComponent("modes.json", isDirectory: false)
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
