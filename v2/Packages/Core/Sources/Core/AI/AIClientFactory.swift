#if canImport(Darwin)
import Foundation

public enum AIClientFactory {
    public static func make(
        provider: AIProvider,
        apiKey: String,
        session: URLSession = .shared
    ) -> any AITextClient {
        switch provider {
        case .anthropic: ClaudeClient(apiKey: apiKey, session: session)
        case .openAI: OpenAIClient(apiKey: apiKey, session: session)
        case .gemini: GeminiClient(apiKey: apiKey, session: session)
        }
    }
}
#endif
