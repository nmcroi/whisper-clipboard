import Foundation

/// Externe tekstaanbieders die WhisperClip met een eigen gebruikerssleutel kan
/// gebruiken. Audio is geen onderdeel van dit contract.
public enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openAI = "openai"
    case gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic Claude"
        case .openAI: "OpenAI"
        case .gemini: "Google Gemini"
        }
    }

    public var keychainAccount: String {
        switch self {
        case .anthropic: "anthropic-api-key"
        case .openAI: "openai-api-key"
        case .gemini: "gemini-api-key"
        }
    }

    public var defaultModel: String {
        switch self {
        case .anthropic: "claude-sonnet-5"
        case .openAI: "gpt-5.6-terra"
        case .gemini: "gemini-3.6-flash"
        }
    }

    /// Veilige ingebouwde keuze wanneer de modellenlijst niet kan worden
    /// opgehaald. Na een geldige sleutel vervangt de live lijst deze waar
    /// mogelijk.
    public var fallbackModels: [String] {
        switch self {
        case .anthropic:
            ["claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5"]
        case .openAI:
            ["gpt-5.6-terra", "gpt-5.6-sol", "gpt-5.6-luna"]
        case .gemini:
            ["gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite"]
        }
    }
}

public struct AIUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Eén foutmodel voor alle aanbieders. De UI kan hierdoor dezelfde herstelactie
/// tonen voor offline, ongeldige sleutel, limiet, tegoed en serverfouten.
public enum AIServiceError: Error, LocalizedError, Equatable, Sendable {
    case missingKey(AIProvider)
    case invalidKey(AIProvider)
    case rateLimited(AIProvider)
    case insufficientCredit(AIProvider)
    case network(AIProvider)
    case timeout(AIProvider)
    case invalidResponse(AIProvider)
    case server(AIProvider, String)

    public var provider: AIProvider {
        switch self {
        case .missingKey(let value), .invalidKey(let value), .rateLimited(let value),
             .insufficientCredit(let value), .network(let value), .timeout(let value),
             .invalidResponse(let value), .server(let value, _):
            value
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .network, .timeout: true
        default: false
        }
    }

    public var errorDescription: String? {
        let name = provider.displayName
        return switch self {
        case .missingKey:
            "Stel eerst je API-key voor \(name) in bij Instellingen."
        case .invalidKey:
            "De API-key voor \(name) is ongeldig of geweigerd. Controleer de sleutel in Instellingen."
        case .rateLimited:
            "\(name) heeft tijdelijk te veel aanvragen. Probeer het over een moment opnieuw."
        case .insufficientCredit:
            "\(name) meldt onvoldoende tegoed of een factureringsprobleem. Controleer je provideraccount."
        case .network:
            "Geen verbinding met \(name). Controleer je internetverbinding."
        case .timeout:
            "De aanvraag bij \(name) duurde te lang. Probeer het opnieuw."
        case .invalidResponse:
            "\(name) gaf een onleesbaar antwoord. Probeer het opnieuw."
        case .server(_, let message):
            message.isEmpty ? "Er ging iets mis bij \(name)." : "\(name) gaf een fout: \(message)"
        }
    }
}

#if canImport(Darwin)
/// Providerneutraal tekstcontract. Implementaties ontvangen uitsluitend de
/// systeeminstructie en transcripttekst, nooit audio of appgeheimen.
public protocol AITextClient: Sendable {
    var provider: AIProvider { get }

    func complete(
        system: String,
        user: String,
        model: String,
        onUsage: @escaping @Sendable (AIUsage) -> Void
    ) -> AsyncThrowingStream<String, Error>

    func listModels() async throws -> [String]
}

public extension AITextClient {
    func completeText(
        system: String,
        user: String,
        model: String,
        onUsage: @escaping @Sendable (AIUsage) -> Void = { _ in }
    ) async throws -> String {
        var text = ""
        for try await chunk in complete(system: system, user: user, model: model, onUsage: onUsage) {
            text += chunk
        }
        return text
    }
}
#endif

/// Deterministische, verliesvrije tekstsplitsing voor lange transcripties.
public enum AITranscriptChunker {
    public static let defaultMaximumCharacters = 32_000

    public static func chunks(
        _ text: String,
        maximumCharacters: Int = defaultMaximumCharacters
    ) -> [String] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        guard maximumCharacters > 0, normalized.count > maximumCharacters else { return [normalized] }

        var result: [String] = []
        var remaining = normalized[...]
        while remaining.count > maximumCharacters {
            let hardEnd = remaining.index(remaining.startIndex, offsetBy: maximumCharacters)
            let candidate = remaining[..<hardEnd]
            let split = candidate.lastIndex(of: "\n")
                ?? candidate.lastIndex(of: ".")
                ?? candidate.lastIndex(of: " ")
                ?? hardEnd
            let end = split == hardEnd ? split : remaining.index(after: split)
            let chunk = remaining[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { result.append(chunk) }
            remaining = remaining[end...].drop(while: { $0.isWhitespace })
        }
        let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}
