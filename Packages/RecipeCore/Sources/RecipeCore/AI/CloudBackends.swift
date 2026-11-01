import Foundation

// Optional cloud AI: the user picks a provider and pastes their own API key in Settings.
// Nothing is hardcoded; keys live in the iPhone's Keychain (app side) and are passed in here.

public enum CloudProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Anthropic Messages API (Claude).
    case anthropic
    /// Any API that speaks the OpenAI Chat Completions format (OpenAI, Gemini's OpenAI endpoint, OpenRouter, …).
    case openAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: "Claude (Anthropic)"
        case .openAICompatible: "OpenAI-compatible"
        }
    }
}

/// Endpoint presets for OpenAI-compatible providers. The user can edit the address.
public struct EndpointPreset: Sendable, Identifiable, Hashable {
    public var name: String
    public var baseURL: String
    public var id: String { name }

    public static let all: [EndpointPreset] = [
        EndpointPreset(name: "OpenAI", baseURL: "https://api.openai.com/v1"),
        EndpointPreset(name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"),
        EndpointPreset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1")
    ]
}

/// Claude model presets (IDs from the Claude docs). Any other model ID can be typed in Settings.
public enum ClaudeModelPreset: String, CaseIterable, Sendable, Identifiable {
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .haiku: "Haiku 5.5 — cheapest"
        case .sonnet: "Sonnet 5.5 — balanced"
        case .opus: "Opus 5.5 — most capable"
        }
    }
}

public struct CloudConfig: Sendable, Equatable {
    public var provider: CloudProvider
    public var model: String
    /// Only used for OpenAI-compatible providers, e.g. "https://api.openai.com/v1".
    public var baseURL: String
    public var apiKey: String

    public init(provider: CloudProvider, model: String, baseURL: String, apiKey: String) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// Short label for logs and Diagnostics (never includes the key).
    public var label: String {
        switch provider {
        case .anthropic: "Claude \(model)"
        case .openAICompatible: "\(model) @ \(URL(string: baseURL)?.host() ?? baseURL)"
        }
    }
}

public enum CloudAPIError: LocalizedError, Sendable, Equatable {
    case missingKey
    case missingModel
    case badBaseURL(String)
    case http(status: Int, message: String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "No API key. Add one in Settings → AI."
        case .missingModel: return "No model chosen. Pick one in Settings → AI."
        case .badBaseURL(let url): return "The API address “\(url)” isn't valid."
        case .http(let status, let message):
            switch status {
            case 401: return "The API key was rejected (\(message)). Check it in Settings → AI."
            case 402: return "Your API account is out of credit: \(message)"
            case 403: return "The API refused the request: \(message)"
            case 404: return "Model or address not found: \(message). Check the model name in Settings → AI."
            case 429: return "API rate limit or quota reached: \(message)"
            case 529: return "The API is overloaded. Try again shortly."
            default:
                if message.localizedCaseInsensitiveContains("credit") || message.localizedCaseInsensitiveContains("billing") {
                    return "Your API account needs credit: \(message)"
                }
                return "API error \(status): \(message)"
            }
        case .badResponse(let detail): return "Unexpected API response: \(detail)"
        }
    }

    var isRetryable: Bool {
        if case .http(let status, _) = self { return status == 429 || status == 529 || status >= 500 }
        return false
    }
}

/// Token usage for one call.
public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Sends HTTP requests. Swappable in tests (no network in CI).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudAPIError.badResponse("not an HTTP response") }
        return (data, http)
    }
}

/// One piece of the user message: text or a JPEG image.
public enum ChatContent: Sendable {
    case text(String)
    case jpeg(Data)
}

/// One provider's "system + user message → JSON matching this schema" call.
public protocol JSONChatBackend: Sendable {
    func completeJSON(system: String, content: [ChatContent], schemaName: String, schema: [String: Any],
                      maxTokens: Int) async throws -> (json: String, usage: TokenUsage)
}

extension JSONChatBackend {
    public func completeJSON(system: String, user: String, schemaName: String, schema: [String: Any],
                             maxTokens: Int) async throws -> (json: String, usage: TokenUsage) {
        try await completeJSON(system: system, content: [.text(user)], schemaName: schemaName, schema: schema, maxTokens: maxTokens)
    }
}

// MARK: - Anthropic (Claude Messages API, JSON schema outputs via output_config.format)

public struct AnthropicBackend: JSONChatBackend {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"

    let apiKey: String
    let model: String
    let transport: any HTTPTransport

    public init(apiKey: String, model: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    public func completeJSON(system: String, content: [ChatContent], schemaName: String, schema: [String: Any],
                             maxTokens: Int) async throws -> (json: String, usage: TokenUsage) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": Self.blocks(content)]],
            "output_config": ["format": ["type": "json_schema", "schema": schema]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.send(request)
        return try Self.parse(data: data, status: response.statusCode)
    }

    static func blocks(_ content: [ChatContent]) -> [[String: Any]] {
        content.map { part -> [String: Any] in
            switch part {
            case .text(let text):
                return ["type": "text", "text": text]
            case .jpeg(let data):
                return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
            }
        }
    }

    static func parse(data: Data, status: Int) throws -> (json: String, usage: TokenUsage) {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = object?["error"] as? [String: Any]
            throw CloudAPIError.http(status: status, message: error?["message"] as? String ?? CloudHTTP.snippet(data))
        }
        guard let object, let content = object["content"] as? [[String: Any]] else {
            throw CloudAPIError.badResponse("no content")
        }
        switch object["stop_reason"] as? String {
        case "max_tokens": throw CloudAPIError.badResponse("the answer was cut off (max_tokens)")
        case "refusal": throw CloudAPIError.badResponse("the model declined this request")
        default: break
        }
        guard let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String else {
            throw CloudAPIError.badResponse("no text in the answer")
        }
        let usage = object["usage"] as? [String: Any]
        return (text, TokenUsage(inputTokens: usage?["input_tokens"] as? Int ?? 0,
                                 outputTokens: usage?["output_tokens"] as? Int ?? 0))
    }
}

// MARK: - OpenAI-compatible (Chat Completions with response_format json_schema)

public struct OpenAICompatibleBackend: JSONChatBackend {
    let apiKey: String
    let model: String
    let baseURL: String
    let transport: any HTTPTransport

    public init(apiKey: String, model: String, baseURL: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.transport = transport
    }

    var endpoint: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") { return URL(string: base) }
        guard base.hasPrefix("https://") else { return nil }
        return URL(string: base + "/chat/completions")
    }

    public func completeJSON(system: String, content: [ChatContent], schemaName: String, schema: [String: Any],
                             maxTokens: Int) async throws -> (json: String, usage: TokenUsage) {
        do {
            return try await send(system: system, content: content, responseFormat: [
                "type": "json_schema",
                "json_schema": ["name": schemaName, "strict": true, "schema": schema]
            ], maxTokens: maxTokens)
        } catch CloudAPIError.http(let status, let message) where status == 400 && Self.isFormatError(message) {
            // Some compatible providers don't support json_schema: fall back to plain JSON mode with the
            // schema written into the instructions (still parsed and checked in Swift).
            let schemaText = String(data: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), encoding: .utf8) ?? ""
            return try await send(system: system + "\n\nReply with only a JSON object matching this JSON schema:\n" + schemaText,
                                  content: content, responseFormat: ["type": "json_object"], maxTokens: maxTokens)
        }
    }

    static func isFormatError(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("response_format") || m.contains("json_schema") || m.contains("schema")
    }

    static func userContent(_ content: [ChatContent]) -> Any {
        // Plain string when there are no images (widest compatibility), parts otherwise.
        if content.count == 1, case .text(let text) = content[0] { return text }
        return content.map { part -> [String: Any] in
            switch part {
            case .text(let text):
                return ["type": "text", "text": text]
            case .jpeg(let data):
                return ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + data.base64EncodedString()]]
            }
        }
    }

    private func send(system: String, content: [ChatContent], responseFormat: [String: Any],
                      maxTokens: Int) async throws -> (json: String, usage: TokenUsage) {
        guard let endpoint else { throw CloudAPIError.badBaseURL(baseURL) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_completion_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": Self.userContent(content)]
            ],
            "response_format": responseFormat
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.send(request)
        return try Self.parse(data: data, status: response.statusCode)
    }

    static func parse(data: Data, status: Int) throws -> (json: String, usage: TokenUsage) {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = object?["error"] as? [String: Any]
            let message = error?["message"] as? String
                ?? (object?["error"] as? String)
                ?? CloudHTTP.snippet(data)
            throw CloudAPIError.http(status: status, message: message)
        }
        guard let choice = (object?["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw CloudAPIError.badResponse("no choices")
        }
        if (choice["finish_reason"] as? String) == "length" {
            throw CloudAPIError.badResponse("the answer was cut off (length)")
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            throw CloudAPIError.badResponse("the model declined: \(refusal)")
        }
        guard let content = message["content"] as? String, !content.isEmpty else {
            throw CloudAPIError.badResponse("empty answer")
        }
        let usage = object?["usage"] as? [String: Any]
        return (CloudHTTP.stripCodeFence(content),
                TokenUsage(inputTokens: usage?["prompt_tokens"] as? Int ?? 0,
                           outputTokens: usage?["completion_tokens"] as? Int ?? 0))
    }
}

enum CloudHTTP {
    static func snippet(_ data: Data) -> String {
        String(data: data.prefix(300), encoding: .utf8) ?? "(no details)"
    }

    /// Some providers wrap JSON in ```json fences in JSON mode.
    static func stripCodeFence(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        if let newline = t.firstIndex(of: "\n") { t = String(t[t.index(after: newline)...]) }
        if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
