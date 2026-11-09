import Foundation

/// Recipe extraction with a cloud model the user connected (their own API key).
/// Same prompts and same Swift checks as Apple Intelligence: steps must still be grounded in the
/// video's text, and macros still come only from the USDA database. Only text is sent — caption,
/// transcript and on-screen text; the video itself never leaves the phone.
public struct CloudExtractor: RecipeExtracting, FoodMatching, StepSuggesting, VisualStepExtracting, RecipeChefing {
    let backend: any JSONChatBackend
    let onUsage: @Sendable (TokenUsage) -> Void

    public init(backend: any JSONChatBackend, onUsage: @escaping @Sendable (TokenUsage) -> Void = { _ in }) {
        self.backend = backend
        self.onUsage = onUsage
    }

    /// Builds the right backend for a configuration (validates key, model and address first).
    public init(config: CloudConfig, transport: any HTTPTransport = URLSessionTransport(),
                onUsage: @escaping @Sendable (TokenUsage) -> Void = { _ in }) throws {
        guard !config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { throw CloudAPIError.missingKey }
        let model = config.model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw CloudAPIError.missingModel }
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch config.provider {
        case .anthropic:
            backend = AnthropicBackend(apiKey: key, model: model, transport: transport)
        case .openAICompatible:
            let openAI = OpenAICompatibleBackend(apiKey: key, model: model, baseURL: config.baseURL, transport: transport)
            guard openAI.endpoint != nil else { throw CloudAPIError.badBaseURL(config.baseURL) }
            backend = openAI
        }
        self.onUsage = onUsage
    }

    public func extractIngredients(from source: String) async throws -> RawRecipe {
        let json = try await call(Prompts.ingredientInstructions, Prompts.ingredientPrompt(source: source),
                                  name: "recipe_ingredients", schema: CloudSchemas.recipe, maxTokens: 16_000)
        let decoded = try decode(DecodedRecipe.self, json)
        return RawRecipe(
            title: decoded.title,
            servings: decoded.servings,
            ingredients: decoded.ingredients.map {
                RawIngredient(sourceQuote: $0.sourceQuote, group: $0.group ?? "", name: $0.name, quantity: $0.quantity,
                              unit: $0.unit, note: $0.note, confidence: $0.confidence)
            },
            rawOutput: json
        )
    }

    public func extractSteps(from source: String, ingredientNames: [String]) async throws -> RawMethod {
        let json = try await call(Prompts.stepInstructions, Prompts.stepPrompt(source: source, ingredientNames: ingredientNames),
                                  name: "recipe_steps", schema: CloudSchemas.method, maxTokens: 12_000)
        let decoded = try decode(DecodedMethod.self, json)
        return RawMethod(
            hasInstructions: decoded.hasInstructions,
            steps: decoded.steps.map {
                RawStep(sourceQuote: $0.sourceQuote, text: $0.text, ingredientsUsed: $0.ingredientsUsed,
                        minutes: $0.minutes, confidence: $0.confidence)
            },
            rawOutput: json
        )
    }

    public func suggestSteps(title: String, ingredients: [String]) async throws -> [RawStep] {
        let json = try await call(Prompts.suggestInstructions, Prompts.suggestPrompt(title: title, ingredients: ingredients),
                                  name: "suggested_steps", schema: CloudSchemas.suggested, maxTokens: 2_048)
        return try decode(DecodedSuggested.self, json).steps.map {
            RawStep(sourceQuote: "", text: $0.text, ingredientsUsed: $0.ingredientsUsed, minutes: $0.minutes, confidence: "low")
        }
    }

    public func pickFood(ingredient: String, detail: String, candidates: [FoodCandidate]) async throws -> FoodPick {
        guard !candidates.isEmpty else { return FoodPick(index: nil, rawOutput: "no candidates") }
        let choices = candidates.enumerated().map { "\($0.offset + 1). \($0.element.description)" } + ["none"]
        let json = try await call(Prompts.matchInstructions, Prompts.matchPrompt(ingredient: ingredient, detail: detail),
                                  name: "food_choice", schema: CloudSchemas.choice(choices), maxTokens: 300)
        let choice = try decode(DecodedChoice.self, json).choice
        return FoodPick(index: FoundationModelsExtractor.parseChoice(choice, count: candidates.count), rawOutput: choice)
    }

    public func extractStepsFromFrames(_ frames: [KeyFrame], sourceText: String, ingredientNames: [String]) async throws -> RawVisualMethod {
        var content: [ChatContent] = [.text(Prompts.visualStepPrompt(sourceText: sourceText, ingredientNames: ingredientNames))]
        for frame in frames {
            content.append(.text("Frame at \(String(format: "%.1f", frame.time)) s:"))
            content.append(.jpeg(frame.jpeg))
        }
        let result = try await backend.completeJSON(system: Prompts.visualStepInstructions, content: content,
                                                    schemaName: "visual_steps", schema: CloudSchemas.visual, maxTokens: 3_000)
        onUsage(result.usage)
        let decoded = try decode(DecodedVisual.self, result.json)
        return RawVisualMethod(
            hasInstructions: decoded.hasInstructions,
            steps: decoded.steps.map {
                RawVisualStep(text: $0.text, ingredientsUsed: $0.ingredientsUsed, frameTimes: $0.frameTimes,
                              minutes: $0.minutes, confidence: $0.confidence)
            },
            rawOutput: result.json
        )
    }

    /// "Ask the chef": one reply with optional edits.
    public func chef(instructions: String, prompt: String) async throws -> RawChefReply {
        let json = try await call(instructions, prompt, name: "chef_reply", schema: CloudSchemas.chef, maxTokens: 6_000)
        let decoded = try decode(DecodedChef.self, json)
        return RawChefReply(
            reply: decoded.reply,
            changes: (decoded.changes ?? []).map {
                RawChefChange(action: $0.action, target: $0.target ?? "", name: $0.name ?? "", quantity: $0.quantity ?? 0,
                              unit: $0.unit ?? "", note: $0.note ?? "", group: $0.group ?? "", text: $0.text ?? "",
                              minutes: $0.minutes ?? 0, position: $0.position ?? 0)
            },
            rawOutput: json
        )
    }

    /// Small request to check the key, model and address (Settings → Test connection).
    public func testConnection() async throws {
        let json = try await call("Reply with the word ok.", "ping", name: "ping",
                                  schema: CloudSchemas.choice(["ok"]), maxTokens: 50)
        _ = try decode(DecodedChoice.self, json)
    }

    // MARK: - Internals

    /// One call, retried once on rate limits, overload and server errors.
    private func call(_ system: String, _ user: String, name: String, schema: [String: Any], maxTokens: Int) async throws -> String {
        do {
            return try await callOnce(system, user, name: name, schema: schema, maxTokens: maxTokens)
        } catch let error as CloudAPIError where error.isRetryable {
            try await Task.sleep(for: .seconds(3))
            return try await callOnce(system, user, name: name, schema: schema, maxTokens: maxTokens)
        }
    }

    private func callOnce(_ system: String, _ user: String, name: String, schema: [String: Any], maxTokens: Int) async throws -> String {
        let result = try await backend.completeJSON(system: system, user: user, schemaName: name, schema: schema, maxTokens: maxTokens)
        onUsage(result.usage)
        return result.json
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw CloudAPIError.badResponse("the JSON didn't match: \(json.prefix(200))")
        }
    }

    struct DecodedRecipe: Decodable {
        struct Item: Decodable {
            let sourceQuote: String
            /// Optional when decoding so a provider without strict schemas can leave it out.
            let group: String?
            let name: String
            let quantity: Double
            let unit: String
            let note: String
            let confidence: String
        }
        let title: String
        let servings: Int
        let ingredients: [Item]
    }

    struct DecodedMethod: Decodable {
        struct Item: Decodable {
            let sourceQuote: String
            let text: String
            let ingredientsUsed: [String]
            let minutes: Int
            let confidence: String
        }
        let hasInstructions: Bool
        let steps: [Item]
    }

    struct DecodedChef: Decodable {
        struct Change: Decodable {
            let action: String
            let target: String?
            let name: String?
            let quantity: Double?
            let unit: String?
            let note: String?
            let group: String?
            let text: String?
            let minutes: Int?
            let position: Int?
        }
        let reply: String
        let changes: [Change]?
    }

    struct DecodedSuggested: Decodable {
        struct Item: Decodable {
            let text: String
            let ingredientsUsed: [String]
            let minutes: Int
        }
        let steps: [Item]
    }

    struct DecodedVisual: Decodable {
        struct Item: Decodable {
            let text: String
            let ingredientsUsed: [String]
            let frameTimes: [Double]
            let minutes: Int
            let confidence: String
        }
        let hasInstructions: Bool
        let steps: [Item]
    }

    struct DecodedChoice: Decodable {
        let choice: String
    }
}

/// JSON schemas (strict: every object lists all properties as required and forbids extra ones,
/// which both Anthropic and OpenAI-style structured outputs require).
enum CloudSchemas {
    static var units: [String] { CanonicalUnit.allCases.map(\.rawValue) }
    static var confidence: [String] { ["high", "medium", "low"] }

    static func object(_ properties: [String: Any], order: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": order, "additionalProperties": false]
    }

    static var recipe: [String: Any] {
        object([
            "title": ["type": "string", "description": "Short dish name, empty if none"],
            "servings": ["type": "integer", "description": "Servings stated in the text, 0 if not stated"],
            "ingredients": ["type": "array", "items": object([
                "sourceQuote": ["type": "string", "description": "Exact words from the text that mention this ingredient"],
                "group": ["type": "string", "description": "Heading this ingredient is listed under (part of the dish), empty if none"],
                "name": ["type": "string", "description": "Ingredient name, singular, no brand"],
                "quantity": ["type": "number", "description": "Total amount as a number, 0 if not stated"],
                "unit": ["type": "string", "enum": units],
                "note": ["type": "string", "description": "Preparation or original vague wording, empty if none"],
                "confidence": ["type": "string", "enum": confidence]
            ], order: ["sourceQuote", "group", "name", "quantity", "unit", "note", "confidence"])]
        ], order: ["title", "servings", "ingredients"])
    }

    static var method: [String: Any] {
        object([
            "hasInstructions": ["type": "boolean", "description": "False if the text gives no method at all"],
            "steps": ["type": "array", "items": object([
                "sourceQuote": ["type": "string", "description": "Exact words from the text this step is based on"],
                "text": ["type": "string", "description": "Short imperative instruction; keep any stated time or temperature exactly"],
                "ingredientsUsed": ["type": "array", "items": ["type": "string"]],
                "minutes": ["type": "integer", "description": "Duration in minutes if stated, 0 if not"],
                "confidence": ["type": "string", "enum": confidence]
            ], order: ["sourceQuote", "text", "ingredientsUsed", "minutes", "confidence"])]
        ], order: ["hasInstructions", "steps"])
    }

    static var chef: [String: Any] {
        object([
            "reply": ["type": "string", "description": "Your answer to the user, 2 to 5 sentences"],
            "changes": ["type": "array", "description": "Edits to apply, empty if none", "items": object([
                "action": ["type": "string", "enum": Chef.actions],
                "target": ["type": "string", "description": "Ingredient id (i1…) or step id (s1…), empty for additions"],
                "name": ["type": "string", "description": "Ingredient name"],
                "quantity": ["type": "number", "description": "Amount, or servings for set_servings; 0 if none"],
                "unit": ["type": "string", "enum": CanonicalUnit.allCases.map(\.rawValue) + [""]],
                "note": ["type": "string", "description": "Preparation note, e.g. finely chopped"],
                "group": ["type": "string", "description": "Part of the recipe, empty if none"],
                "text": ["type": "string", "description": "Step text, or the new title for rename_recipe"],
                "minutes": ["type": "integer", "description": "Step time in minutes, 0 if none"],
                "position": ["type": "integer", "description": "For add_step: the step number it comes after, 0 for first"]
            ], order: ["action", "target", "name", "quantity", "unit", "note", "group", "text", "minutes", "position"])]
        ], order: ["reply", "changes"])
    }

    static var suggested: [String: Any] {
        object([
            "steps": ["type": "array", "items": object([
                "text": ["type": "string"],
                "ingredientsUsed": ["type": "array", "items": ["type": "string"]],
                "minutes": ["type": "integer", "description": "Duration in minutes, 0 if none"]
            ], order: ["text", "ingredientsUsed", "minutes"])]
        ], order: ["steps"])
    }

    static var visual: [String: Any] {
        object([
            "hasInstructions": ["type": "boolean", "description": "False if the frames show no preparation or cooking"],
            "steps": ["type": "array", "items": object([
                "text": ["type": "string", "description": "Short imperative instruction"],
                "ingredientsUsed": ["type": "array", "items": ["type": "string"]],
                "frameTimes": ["type": "array", "items": ["type": "number"], "description": "Times in seconds of the frames showing this step"],
                "minutes": ["type": "integer", "description": "Duration in minutes only if the text states one, else 0"],
                "confidence": ["type": "string", "enum": confidence]
            ], order: ["text", "ingredientsUsed", "frameTimes", "minutes", "confidence"])]
        ], order: ["hasInstructions", "steps"])
    }

    static func choice(_ choices: [String]) -> [String: Any] {
        object(["choice": ["type": "string", "enum": choices]], order: ["choice"])
    }
}
