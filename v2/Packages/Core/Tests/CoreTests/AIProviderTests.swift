import Foundation
import Testing
@testable import Core

@Suite("Provider-neutrale AI-laag")
struct AIProviderTests {
    @Test func providerDefaultsAndKeychainAccountsAreDistinct() {
        #expect(AIProvider.anthropic.defaultModel == "claude-sonnet-5")
        #expect(AIProvider.openAI.defaultModel == "gpt-5.6-terra")
        #expect(AIProvider.gemini.defaultModel == "gemini-3.6-flash")
        #expect(Set(AIProvider.allCases.map(\.keychainAccount)).count == 3)
        #expect(AIProvider.allCases.allSatisfy { $0.fallbackModels.contains($0.defaultModel) })
    }

    @Test func longTranscriptChunksContainEveryWordExactlyOnce() {
        let words = (0..<250).map { "woord\($0)" }
        let chunks = AITranscriptChunker.chunks(words.joined(separator: " "), maximumCharacters: 90)
        #expect(chunks.count > 1)
        #expect(chunks.flatMap { $0.split(separator: " ").map(String.init) } == words)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 90 })
    }

    @Test func openAIStreamingTextAndUsageAreParsed() {
        #expect(OpenAIClient.parseSSELine("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hallo\"}") == .event(.text("Hallo")))
        #expect(OpenAIClient.parseSSELine("data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":12,\"output_tokens\":4}}}") == .event(.usage(AIUsage(inputTokens: 12, outputTokens: 4))))
    }

    @Test func geminiFinalChunkDoesNotLoseTextWhenItAlsoCarriesUsage() {
        let line = """
        data: {"candidates":[{"content":{"parts":[{"text":"Slotzin"}]}}],"usageMetadata":{"promptTokenCount":21,"candidatesTokenCount":7}}
        """
        #expect(GeminiClient.parseSSELine(line) == .textAndUsage("Slotzin", AIUsage(inputTokens: 21, outputTokens: 7)))
    }

    @Test func providerErrorsDistinguishKeyRateAndCredit() {
        #expect(OpenAIClient.mapHTTP(status: 401, body: Data()) == .invalidKey(.openAI))
        #expect(OpenAIClient.mapHTTP(status: 429, body: Data("{\"error\":{\"message\":\"quota exceeded\"}}".utf8)) == .insufficientCredit(.openAI))
        #expect(GeminiClient.mapHTTP(status: 429, body: Data("{\"error\":{\"message\":\"rate limit\"}}".utf8)) == .rateLimited(.gemini))
        #expect(AIServiceError.timeout(.anthropic).isRetryable)
        #expect(!AIServiceError.invalidKey(.anthropic).isRetryable)
    }

    @Test func openAIModelDiscoveryUsesMockedResponseAndFiltersNonTextModels() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIModelsStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let models = try await OpenAIClient(apiKey: "test-only", session: session).listModels()
        #expect(models == ["gpt-5.6-terra", "gpt-5.6-luna"])
    }

    @Test func geminiModelDiscoveryUsesMockedResponseAndFiltersUnsupportedModels() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiModelsStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let models = try await GeminiClient(apiKey: "test-only", session: session).listModels()
        #expect(models == ["gemini-3.6-flash", "gemini-3.5-flash"])
    }

    @Test func providerNetworkFailureIsMappedWithoutLeakingRawTransportError() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await OpenAIClient(apiKey: "test-only", session: session).listModels()
            Issue.record("Een offline modellenverzoek had moeten mislukken")
        } catch let error as AIServiceError {
            #expect(error == .network(.openAI))
        } catch {
            Issue.record("Onverwacht fouttype: \(error)")
        }
    }
}

private final class OpenAIModelsStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Data(#"{"data":[{"id":"gpt-5.6-luna"},{"id":"gpt-5.6-terra"},{"id":"gpt-audio-1"},{"id":"text-embedding-3-small"}]}"#.utf8)
        respond(status: 200, body: body)
    }
    override func stopLoading() {}
}

private final class GeminiModelsStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Data(#"{"models":[{"name":"models/gemini-3.5-flash","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-3.6-flash","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-embedding","supportedGenerationMethods":["embedContent"]}]}"#.utf8)
        respond(status: 200, body: body)
    }
    override func stopLoading() {}
}

private final class OfflineStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

private extension URLProtocol {
    func respond(status: Int, body: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
