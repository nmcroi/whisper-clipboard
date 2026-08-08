#if canImport(Darwin)
import Foundation

/// Tekst-only REST/SSE-client voor Google Gemini. De sleutel staat in een
/// header; het request bevat uitsluitend instructie en transcripttekst.
public struct GeminiClient: AITextClient, Sendable {
    public let provider = AIProvider.gemini

    private let apiKey: String
    private let session: URLSession

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
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.mapURL(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse(.gemini)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapHTTP(status: http.statusCode, body: data)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["models"] as? [[String: Any]] else {
            throw AIServiceError.invalidResponse(.gemini)
        }
        return rows.compactMap { row -> String? in
            let methods = row["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent"),
                  let name = row["name"] as? String else { return nil }
            return name.replacingOccurrences(of: "models/", with: "")
        }
        .filter { $0.hasPrefix("gemini-") }
        .sorted(by: >)
    }

    private func run(
        system: String,
        user: String,
        model: String,
        into continuation: AsyncThrowingStream<String, Error>.Continuation,
        onUsage: @escaping @Sendable (AIUsage) -> Void
    ) async throws {
        let cleanModel = model.replacingOccurrences(of: "models/", with: "")
        guard let encoded = cleanModel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encoded):streamGenerateContent?alt=sse")
        else { throw AIServiceError.invalidResponse(.gemini) }

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["maxOutputTokens": 16_384],
        ])

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            throw Self.mapURL(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse(.gemini)
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw Self.mapHTTP(status: http.statusCode, body: body)
        }

        var latestUsage = AIUsage(inputTokens: 0, outputTokens: 0)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch Self.parseSSELine(line) {
            case .text(let value): continuation.yield(value)
            case .usage(let value): latestUsage = value
            case .textAndUsage(let value, let usage):
                continuation.yield(value)
                latestUsage = usage
            case .error(let message): throw AIServiceError.server(.gemini, message)
            case .ignore: break
            }
        }
        onUsage(latestUsage)
    }

    public enum SSEEvent: Equatable {
        case text(String)
        case usage(AIUsage)
        case textAndUsage(String, AIUsage)
        case error(String)
        case ignore
    }

    public static func parseSSELine(_ line: String) -> SSEEvent {
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignore
        }
        if let error = object["error"] as? [String: Any] {
            return .error(error["message"] as? String ?? "")
        }
        let usage: AIUsage? = (object["usageMetadata"] as? [String: Any]).map {
            AIUsage(
                inputTokens: $0["promptTokenCount"] as? Int ?? 0,
                outputTokens: $0["candidatesTokenCount"] as? Int ?? 0
            )
        }
        guard let candidates = object["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return usage.map(SSEEvent.usage) ?? .ignore
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        if !text.isEmpty, let usage { return .textAndUsage(text, usage) }
        if !text.isEmpty { return .text(text) }
        return usage.map(SSEEvent.usage) ?? .ignore
    }

    public static func mapURL(_ error: URLError) -> AIServiceError {
        switch error.code {
        case .timedOut: .timeout(.gemini)
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dataNotAllowed: .network(.gemini)
        default: .server(.gemini, error.localizedDescription)
        }
    }

    public static func mapHTTP(status: Int, body: Data) -> AIServiceError {
        let message: String = {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
            return (object["error"] as? [String: Any])?["message"] as? String ?? ""
        }()
        switch status {
        case 400 where message.localizedCaseInsensitiveContains("key"):
            return .invalidKey(.gemini)
        case 401, 403: return .invalidKey(.gemini)
        case 429 where message.localizedCaseInsensitiveContains("quota")
            || message.localizedCaseInsensitiveContains("billing"):
            return .insufficientCredit(.gemini)
        case 429: return .rateLimited(.gemini)
        case 402: return .insufficientCredit(.gemini)
        default: return .server(.gemini, message.isEmpty ? "HTTP \(status)" : message)
        }
    }
}
#endif
