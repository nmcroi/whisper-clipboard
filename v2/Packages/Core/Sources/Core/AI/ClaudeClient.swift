// URLSession.AsyncBytes ontbreekt in swift-corelibs-foundation. De guard laat
// de rest van Core op Linux compileren zodat CI de CoreTests daar kan draaien.
#if canImport(Darwin)
import Foundation

/// Typed errors from the Claude client, each with a Dutch, user-facing message.
public enum ClaudeError: Error, LocalizedError, Equatable {
    /// No API key configured.
    case missingKey
    /// 401 — the key is invalid / rejected.
    case invalidKey
    /// 429 / 529 — rate limited or overloaded.
    case overloaded
    /// Network offline / could not reach the API.
    case network
    /// Any other HTTP or decoding failure, with the server message when present.
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Stel eerst je Claude API-key in bij Instellingen."
        case .invalidKey:
            return "Je Claude API-key is ongeldig of geweigerd. Controleer de sleutel in Instellingen."
        case .overloaded:
            return "Claude is momenteel overbelast. Probeer het over een moment opnieuw."
        case .network:
            return "Geen verbinding met Claude. Controleer je internetverbinding."
        case .server(let message):
            return message.isEmpty
                ? "Er ging iets mis bij het aanroepen van Claude."
                : "Claude gaf een fout: \(message)"
        }
    }
}

/// URLSession-based streaming client for the Anthropic Messages API.
///
/// No SDK dependency: it POSTs to `/v1/messages` with `stream: true` and parses
/// the Server-Sent Events stream by hand, yielding `text_delta` chunks. The API
/// key is supplied per call (read from the Keychain by the caller) so this type
/// holds no secrets.
public struct ClaudeClient: AITextClient, Sendable {

    public typealias Usage = AIUsage

    public let provider = AIProvider.anthropic

    /// The model used for all AI-mode completions.
    public static let model = "claude-sonnet-5"
    public static let anthropicVersion = "2023-06-01"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let maxTokens = 16_384

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Streams the assistant response as incremental text deltas.
    ///
    /// - Parameters:
    ///   - system: the system prompt (mode instructions).
    ///   - user: the user content (the transcript).
    /// - Returns: an async stream yielding text chunks; it finishes on
    ///   `message_stop` and throws a typed ``ClaudeError`` on failure.
    public func complete(
        system: String,
        user: String,
        onUsage: @escaping @Sendable (Usage) -> Void = { _ in }
    ) -> AsyncThrowingStream<String, Error> {
        complete(system: system, user: user, model: Self.model, onUsage: onUsage)
    }

    /// Providerneutrale variant met een expliciete modelkeuze.
    public func complete(
        system: String,
        user: String,
        model: String,
        onUsage: @escaping @Sendable (Usage) -> Void = { _ in }
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(
                        system: system,
                        user: user,
                        model: model,
                        into: continuation,
                        onUsage: onUsage
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming convenience: accumulates the stream into a single string.
    public func completeText(
        system: String,
        user: String,
        onUsage: @escaping @Sendable (Usage) -> Void = { _ in }
    ) async throws -> String {
        try await completeText(system: system, user: user, model: Self.model, onUsage: onUsage)
    }

    // MARK: - Internals

    private func makeRequest(system: String, user: String, model: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "stream": true,
            "system": system,
            "messages": [
                ["role": "user", "content": user]
            ],
        ]
        // Generation 5 models enable adaptive thinking by default. These
        // transcript transformations need deterministic text, not hidden
        // reasoning that consumes the output budget.
        if model.contains("-5") {
            body["thinking"] = ["type": "disabled"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func run(
        system: String,
        user: String,
        model: String,
        into continuation: AsyncThrowingStream<String, Error>.Continuation,
        onUsage: @escaping @Sendable (Usage) -> Void
    ) async throws {
        let request = try makeRequest(system: system, user: user, model: model)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let urlError as URLError {
            throw Self.mapURLError(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.server("")
        }

        // On a non-2xx status, drain the body to extract the server message and
        // map to a typed error.
        guard (200..<300).contains(http.statusCode) else {
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            throw Self.mapHTTPError(status: http.statusCode, body: raw)
        }

        // Parse the SSE stream line by line.
        var inputTokens = 0
        var outputTokens = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch Self.parseSSELine(line) {
            case .text(let text):
                continuation.yield(text)
            case .error(let message):
                throw ClaudeError.server(message)
            case .usage(let input, let output):
                if let input { inputTokens = input }
                if let output { outputTokens = output }
            case .stop:
                onUsage(Usage(inputTokens: inputTokens, outputTokens: outputTokens))
                return
            case .ignore:
                break
            }
        }
    }

    /// Haalt na sleutelvalidatie de beschikbare Claude-modellen op. Bij een
    /// tijdelijke serverfout kan de UI de ingebouwde fallbacklijst blijven tonen.
    public func listModels() async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.mapURLError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.server("") }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapHTTPError(status: http.statusCode, body: data)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw ClaudeError.server("Onleesbare modellenlijst")
        }
        return rows.compactMap { $0["id"] as? String }
            .filter { $0.hasPrefix("claude-") }
            .sorted()
    }

    /// The meaning of a single parsed SSE line.
    public enum SSEEvent: Equatable {
        case text(String)
        case error(String)
        case usage(input: Int?, output: Int?)
        case stop
        case ignore
    }

    /// Parses one line of the SSE stream. Pure and synchronous so it can be unit
    /// tested against canned event streams (including multi-line data and
    /// error events). Non-`data:` lines (e.g. `event:` headers, blank lines)
    /// and unrecognized event types are `.ignore`.
    public static func parseSSELine(_ line: String) -> SSEEvent {
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty,
              let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return .ignore }

        switch type {
        case "message_start":
            let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any]
            guard let input = usage?["input_tokens"] as? Int else { return .ignore }
            return .usage(input: input, output: nil)
        case "message_delta":
            let usage = event["usage"] as? [String: Any]
            guard let output = usage?["output_tokens"] as? Int else { return .ignore }
            return .usage(input: nil, output: output)
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                return .text(text)
            }
            return .ignore
        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String ?? ""
            return .error(message)
        case "message_stop":
            return .stop
        default:
            return .ignore
        }
    }

    // MARK: - Error mapping

    public static func mapURLError(_ error: URLError) -> ClaudeError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .timedOut, .dataNotAllowed:
            return .network
        default:
            return .server(error.localizedDescription)
        }
    }

    public static func mapHTTPError(status: Int, body: Data) -> ClaudeError {
        switch status {
        case 401, 403:
            return .invalidKey
        case 429, 529:
            return .overloaded
        default:
            // Try to extract the Anthropic error message: {"error": {"message": ...}}
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return .server(message)
            }
            return .server("HTTP \(status)")
        }
    }
}

#endif
