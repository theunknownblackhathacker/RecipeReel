import Foundation
import Testing
@testable import RecipeCore

/// Returns canned responses and records requests. No network in CI.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, String)]
    private var recorded: [URLRequest] = []

    init(_ responses: [(Int, String)]) {
        self.responses = responses
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        let (status, body) = responses.isEmpty ? (500, "{}") : responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

final class UsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = TokenUsage(inputTokens: 0, outputTokens: 0)
    func add(_ usage: TokenUsage) {
        lock.lock(); defer { lock.unlock() }
        value.inputTokens += usage.inputTokens
        value.outputTokens += usage.outputTokens
    }
    var total: TokenUsage {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// JSON-escapes `text` as a string literal (with quotes).
private func literal(_ text: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [text])
    return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
}

private func anthropicBody(_ json: String, stop: String = "end_turn") -> String {
    #"{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":\#(literal(json))}],"stop_reason":"\#(stop)","usage":{"input_tokens":120,"output_tokens":45}}"#
}

private func openAIBody(_ content: String, finish: String = "stop") -> String {
    #"{"id":"c1","choices":[{"index":0,"message":{"role":"assistant","content":\#(literal(content))},"finish_reason":"\#(finish)"}],"usage":{"prompt_tokens":100,"completion_tokens":30}}"#
}

private func body(of request: URLRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any])
}

@Suite("Cloud AI — Anthropic")
struct AnthropicTests {
    let recipeJSON = #"{"title":"Oats","servings":2,"ingredients":[{"sourceQuote":"80g rolled oats","name":"rolled oats","quantity":80,"unit":"g","note":"","confidence":"high"}]}"#

    @Test func requestShapeAndParsing() async throws {
        let transport = FakeTransport([(200, anthropicBody(recipeJSON))])
        let usage = UsageBox()
        let extractor = try CloudExtractor(
            config: CloudConfig(provider: .anthropic, model: "claude-haiku-5-5", baseURL: "", apiKey: " sk-ant-test\n"),
            transport: transport, onUsage: { usage.add($0) }
        )
        let recipe = try await extractor.extractIngredients(from: "CAPTION: 80g rolled oats")
        #expect(recipe.title == "Oats")
        #expect(recipe.servings == 2)
        #expect(recipe.ingredients.first?.quantity == 80)
        #expect(usage.total == TokenUsage(inputTokens: 120, outputTokens: 45))

        let request = try #require(transport.requests.first)
        #expect(request.url == AnthropicBackend.endpoint)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let json = try body(of: request)
        #expect(json["model"] as? String == "claude-haiku-5-5")
        let format = (json["output_config"] as? [String: Any])?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
        #expect((format?["schema"] as? [String: Any])?["additionalProperties"] as? Bool == false)
        // Untrusted video text goes in the user message, never the system prompt.
        #expect((json["system"] as? String)?.contains("80g rolled oats") == false)
    }

    @Test func authErrorIsNotRetried() async throws {
        let transport = FakeTransport([(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)])
        let extractor = try CloudExtractor(config: CloudConfig(provider: .anthropic, model: "m", baseURL: "", apiKey: "bad"), transport: transport)
        await #expect(throws: CloudAPIError.http(status: 401, message: "invalid x-api-key")) {
            try await extractor.testConnection()
        }
        #expect(transport.requests.count == 1)
    }

    @Test func overloadIsRetriedOnce() async throws {
        let transport = FakeTransport([
            (529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
            (200, anthropicBody(#"{"choice":"ok"}"#))
        ])
        let extractor = try CloudExtractor(config: CloudConfig(provider: .anthropic, model: "m", baseURL: "", apiKey: "k"), transport: transport)
        try await extractor.testConnection()
        #expect(transport.requests.count == 2)
    }

    @Test func cutOffAnswerIsAnError() async throws {
        let transport = FakeTransport([(200, anthropicBody(#"{"choi"#, stop: "max_tokens"))])
        let extractor = try CloudExtractor(config: CloudConfig(provider: .anthropic, model: "m", baseURL: "", apiKey: "k"), transport: transport)
        await #expect(throws: CloudAPIError.self) { try await extractor.testConnection() }
    }
}

@Suite("Cloud AI — OpenAI-compatible")
struct OpenAICompatibleTests {

    @Test func requestShapeStepsAndFoodChoice() async throws {
        let transport = FakeTransport([
            (200, openAIBody(#"{"hasInstructions":true,"steps":[{"sourceQuote":"stir it","text":"Stir well.","ingredientsUsed":["oats"],"minutes":0,"confidence":"high"}]}"#)),
            (200, openAIBody("```json\n{\"choice\":\"2. Oil, olive, salad or cooking\"}\n```"))
        ])
        let extractor = try CloudExtractor(
            config: CloudConfig(provider: .openAICompatible, model: "some-model", baseURL: "https://api.example.com/v1/", apiKey: "sk-x"),
            transport: transport
        )
        let method = try await extractor.extractSteps(from: "VOICE: stir it", ingredientNames: ["oats"])
        #expect(method.steps.map(\.text) == ["Stir well."])
        let pick = try await extractor.pickFood(ingredient: "olive oil", detail: "", candidates: [
            FoodCandidate(fdcID: 1, description: "Oil, corn"),
            FoodCandidate(fdcID: 171413, description: "Oil, olive, salad or cooking")
        ])
        #expect(pick.index == 1)

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
        let json = try body(of: request)
        let format = json["response_format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
        #expect(((format?["json_schema"] as? [String: Any])?["strict"] as? Bool) == true)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
    }

    @Test func fallsBackToJSONModeWhenSchemaUnsupported() async throws {
        let transport = FakeTransport([
            (400, #"{"error":{"message":"response_format json_schema is not supported for this model"}}"#),
            (200, openAIBody(#"{"choice":"ok"}"#))
        ])
        let extractor = try CloudExtractor(
            config: CloudConfig(provider: .openAICompatible, model: "m", baseURL: "https://api.example.com/v1", apiKey: "k"),
            transport: transport
        )
        try await extractor.testConnection()
        #expect(transport.requests.count == 2)
        let second = try body(of: transport.requests[1])
        #expect((second["response_format"] as? [String: Any])?["type"] as? String == "json_object")
    }

    @Test func configValidation() {
        #expect(throws: CloudAPIError.missingKey) {
            _ = try CloudExtractor(config: CloudConfig(provider: .anthropic, model: "m", baseURL: "", apiKey: "  "))
        }
        #expect(throws: CloudAPIError.missingModel) {
            _ = try CloudExtractor(config: CloudConfig(provider: .anthropic, model: "", baseURL: "", apiKey: "k"))
        }
        #expect(throws: CloudAPIError.badBaseURL("http://insecure.example.com")) {
            _ = try CloudExtractor(config: CloudConfig(provider: .openAICompatible, model: "m", baseURL: "http://insecure.example.com", apiKey: "k"))
        }
    }

    @Test func labelNeverContainsKey() {
        let config = CloudConfig(provider: .openAICompatible, model: "m1", baseURL: "https://openrouter.ai/api/v1", apiKey: "sk-secret")
        #expect(config.label == "m1 @ openrouter.ai")
        #expect(!config.label.contains("sk-secret"))
    }
}

@Suite("Cloud AI — full pipeline")
struct CloudPipelineTests {
    @Test func inventedStepsAreStillDroppedWithCloudModel() async throws {
        // A cloud model that invents a method for the ingredient-only Case 3 is filtered exactly like
        // the on-device model: the Swift checks don't depend on which model answered.
        let transport = FakeTransport([
            (200, anthropicBody(#"{"title":"","servings":1,"ingredients":[{"sourceQuote":"200g chicken breast","name":"chicken breast","quantity":200,"unit":"g","note":"","confidence":"high"}]}"#)),
            (200, anthropicBody(#"{"hasInstructions":true,"steps":[{"sourceQuote":"200g chicken breast","text":"Cook the chicken for 6 minutes","ingredientsUsed":["chicken breast"],"minutes":6,"confidence":"high"}]}"#))
        ])
        let extractor = try CloudExtractor(config: CloudConfig(provider: .anthropic, model: "m", baseURL: "", apiKey: "k"), transport: transport)
        let testCase = ExtractionSelfTest.cases[2]
        let pipeline = PipelineCoordinator(transcriber: NoMedia(), ocr: NoMedia(), extractor: extractor, matcher: nil,
                                           database: nil, aiStatus: "cloud", maxChunkCharacters: 60_000)
        let report = await pipeline.extract(into: AnalysisReport(itemID: nil, aiStatus: "cloud", timeline: testCase.timeline),
                                            rememberedMatches: [:], update: { _ in })
        let outcome = try #require(report.outcome)
        #expect(outcome.ingredients.count == 1)
        #expect(outcome.steps.isEmpty)
        #expect(!outcome.hasInstructions)
    }
}
