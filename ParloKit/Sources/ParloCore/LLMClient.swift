import Foundation

public protocol ChatCompleting: Sendable {
    func complete(system: String, user: String, timeout: TimeInterval) async throws -> String
}

public enum LLMError: Error, Equatable, LocalizedError {
    case invalidURL
    case http(Int, String)
    case emptyResponse
    case insecureURL

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid LLM base URL"
        case let .http(code, body): "LLM error \(code): \(body.prefix(200))"
        case .emptyResponse: "LLM returned an empty response"
        case .insecureURL: "The API key is only sent over https (or to this Mac)"
        }
    }
}

/// OpenAI-compatible `/chat/completions` client: Groq, OpenAI, OpenRouter, Ollama.
public struct LLMClient: ChatCompleting {
    let settings: LLMSettings
    let apiKey: String?
    let session: URLSession

    public init(settings: LLMSettings, apiKey: String?, session: URLSession = .shared) {
        self.settings = settings
        self.apiKey = apiKey
        self.session = session
    }

    struct Request: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let temperature: Double
    }

    struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    public func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        var base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions"), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { throw LLMError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            let local = ["localhost", "127.0.0.1", "::1"].contains(url.host()?.lowercased() ?? "")
            guard scheme == "https" || local else { throw LLMError.insecureURL }
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Request(
            model: settings.model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            temperature: 0
        ))

        // The request's own timeout only counts silence: a server that trickles bytes would never hit it.
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Deadline.run(seconds: timeout) { [session, request] in
                try await session.data(for: request)
            }
        } catch is DeadlineExceeded {
            throw URLError(.timedOut)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.http(status, String(decoding: data, as: UTF8.self))
        }
        let content = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content ?? ""
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return trimmed
    }
}
