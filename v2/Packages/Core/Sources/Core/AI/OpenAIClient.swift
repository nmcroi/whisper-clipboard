#if canImport(Darwin)
import Foundation

/// Minimale, SDK-vrije client voor OpenAI's Responses API. Alleen platte tekst
/// gaat naar `/v1/responses`; tools, bestanden, audio en opslag worden niet
/// aangezet.
public struct OpenAIClient: AITextClient, Sendable {
    public let provider = AIProvider.openAI

    private let apiKey: String
    private let session: URLSession
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func complete(
        system: String,
        user: String,
        model: String,
        onUsage: @escaping @Sendable (AIUsage) -> Void = { _ in }
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(
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

    public func listModels() async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await perform(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw AIServiceError.invalidResponse(.openAI)
        }
        return rows.compactMap { $0["id"] as? String }
            .filter(Self.isTextModel)
            .sorted(by: >)
    }

    private func run(
        system: String,
        user: String,
        model: String,
        into continuation: AsyncThrowingStream<String, Error>.Continuation,
        onUsage: @escaping @Sendable (AIUsage) -> Void
    ) async throws {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "instructions": system,
            "input": user,
            "stream": true,
            "store": false,
        ])

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            throw Self.mapURL(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse(.openAI)
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw Self.mapHTTP(status: http.statusCode, body: body)
        }

        var usage = AIUsage(inputTokens: 0, outputTokens: 0)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard case let .event(event) = Self.parseSSELine(line) else { continue }
            switch event {
            case .text(let value): continuation.yield(value)
            case .usage(let value): usage = value
            case .error(let message): throw AIServiceError.server(.openAI, message)
            case .completed:
                onUsage(usage)
                return
            }
        }
        onUsage(usage)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.mapURL(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse(.openAI)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapHTTP(status: http.statusCode, body: data)
        }
        return (data, response)
    }

    public enum StreamEvent: Equatable {
        case text(String)
        case usage(AIUsage)
        case error(String)
        case completed
    }

    public enum ParsedLine: Equatable {
        case event(StreamEvent)
        case ignore
    }

    public static func parseSSELine(_ line: String) -> ParsedLine {
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return .ignore }

        switch type {
        case "response.output_text.delta":
            return .event(.text(object["delta"] as? String ?? ""))
        case "response.completed":
            if let response = object["response"] as? [String: Any],
               let usage = response["usage"] as? [String: Any] {
                return .event(.usage(AIUsage(
                    inputTokens: usage["input_tokens"] as? Int ?? 0,
                    outputTokens: usage["output_tokens"] as? Int ?? 0
                )))
            }
            return .event(.completed)
        case "response.failed", "error":
            let error = (object["error"] as? [String: Any])?["message"] as? String
                ?? object["message"] as? String
                ?? ""
            return .event(.error(error))
        default:
            return .ignore
        }
    }

    public static func mapURL(_ error: URLError) -> AIServiceError {
        switch error.code {
        case .timedOut: .timeout(.openAI)
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dataNotAllowed: .network(.openAI)
        default: .server(.openAI, error.localizedDescription)
        }
    }

    public static func mapHTTP(status: Int, body: Data) -> AIServiceError {
        let message = Self.errorMessage(from: body)
        switch status {
        case 401, 403: return .invalidKey(.openAI)
        case 429 where message.localizedCaseInsensitiveContains("quota")
            || message.localizedCaseInsensitiveContains("billing"):
            return .insufficientCredit(.openAI)
        case 429: return .rateLimited(.openAI)
        case 402: return .insufficientCredit(.openAI)
        default:
            if message.localizedCaseInsensitiveContains("quota")
                || message.localizedCaseInsensitiveContains("billing") {
                return .insufficientCredit(.openAI)
            }
            return .server(.openAI, message.isEmpty ? "HTTP \(status)" : message)
        }
    }

    private static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return (object["error"] as? [String: Any])?["message"] as? String ?? ""
    }

    private static func isTextModel(_ id: String) -> Bool {
        let value = id.lowercased()
        let allowedPrefixes = ["gpt-", "o1", "o3", "o4"]
        let deniedParts = ["audio", "realtime", "transcribe", "tts", "image", "search", "embedding"]
        return allowedPrefixes.contains(where: value.hasPrefix)
            && !deniedParts.contains(where: value.contains)
            && !value.hasPrefix("ft:")
    }
}
#endif
