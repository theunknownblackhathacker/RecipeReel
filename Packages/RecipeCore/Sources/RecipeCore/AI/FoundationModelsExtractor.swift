import Foundation
import FoundationModels

// MARK: - Guided generation types (properties are generated in declaration order)

@Generable
enum GenUnit {
    case g, kg, ml, l, tsp, tbsp, cup, oz, lb, piece, clove, slice, pinch, to_taste
}

@Generable
enum GenConfidence {
    case high, medium, low
}

@Generable(description: "One ingredient from a recipe")
struct GenIngredient {
    @Guide(description: "Exact words from the text that mention this ingredient")
    var sourceQuote: String
    @Guide(description: "Ingredient name, singular, no brand")
    var name: String
    @Guide(description: "Total amount as a number, 0 if not stated")
    var quantity: Double
    var unit: GenUnit
    @Guide(description: "Preparation or original vague wording, empty if none")
    var note: String
    var confidence: GenConfidence
}

@Generable(description: "Ingredients of a recipe video")
struct GenRecipe {
    @Guide(description: "Short dish name, empty if none")
    var title: String
    @Guide(description: "Servings stated in the text, 0 if not stated")
    var servings: Int
    var ingredients: [GenIngredient]
}

@Generable(description: "One cooking step from the recipe")
struct GenStep {
    @Guide(description: "Exact words from the text this step is based on")
    var sourceQuote: String
    @Guide(description: "Short imperative instruction; keep any stated time or temperature exactly")
    var text: String
    @Guide(description: "Names from the given ingredient list used in this step")
    var ingredientsUsed: [String]
    @Guide(description: "Duration in minutes if stated, 0 if not")
    var minutes: Int
    var confidence: GenConfidence
}

@Generable(description: "Cooking method of a recipe video")
struct GenMethod {
    @Guide(description: "False if the text gives no method at all")
    var hasInstructions: Bool
    var steps: [GenStep]
}

// MARK: - Implementation

/// On-device extraction with Apple's Foundation Models framework.
/// Every call uses a fresh single-turn session (sessions handle one request at a time).
public struct FoundationModelsExtractor: RecipeExtracting, FoodMatching {

    public init() {}

    private var options: GenerationOptions { GenerationOptions(sampling: .greedy) }

    public func extractIngredients(from source: String) async throws -> RawRecipe {
        let session = LanguageModelSession(instructions: Prompts.ingredientInstructions)
        let response = try await session.respond(
            to: Prompts.ingredientPrompt(source: source),
            generating: GenRecipe.self,
            options: options
        )
        let recipe = response.content
        return RawRecipe(
            title: recipe.title,
            servings: recipe.servings,
            ingredients: recipe.ingredients.map {
                RawIngredient(
                    sourceQuote: $0.sourceQuote,
                    name: $0.name,
                    quantity: $0.quantity,
                    unit: String(describing: $0.unit),
                    note: $0.note,
                    confidence: String(describing: $0.confidence)
                )
            },
            rawOutput: String(describing: recipe)
        )
    }

    public func extractSteps(from source: String, ingredientNames: [String]) async throws -> RawMethod {
        let session = LanguageModelSession(instructions: Prompts.stepInstructions)
        let response = try await session.respond(
            to: Prompts.stepPrompt(source: source, ingredientNames: ingredientNames),
            generating: GenMethod.self,
            options: options
        )
        let method = response.content
        return RawMethod(
            hasInstructions: method.hasInstructions,
            steps: method.steps.map {
                RawStep(
                    sourceQuote: $0.sourceQuote,
                    text: $0.text,
                    ingredientsUsed: $0.ingredientsUsed,
                    minutes: $0.minutes,
                    confidence: String(describing: $0.confidence)
                )
            },
            rawOutput: String(describing: method)
        )
    }

    /// Builds a schema at runtime whose only allowed answers are the numbered candidates or "none",
    /// so the model can't name a food that isn't in the database.
    public func pickFood(ingredient: String, detail: String, candidates: [FoodCandidate]) async throws -> FoodPick {
        guard !candidates.isEmpty else { return FoodPick(index: nil, rawOutput: "no candidates") }
        let choices = candidates.enumerated().map { "\($0.offset + 1). \($0.element.description)" } + ["none"]
        let choiceSchema = DynamicGenerationSchema(
            name: "FoodChoice",
            description: "A food from the list, or none",
            anyOf: choices
        )
        let root = DynamicGenerationSchema(
            name: "FoodMatch",
            description: "The database food that matches the ingredient",
            properties: [
                DynamicGenerationSchema.Property(name: "choice", description: "Best matching food, or none", schema: choiceSchema)
            ]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])
        let session = LanguageModelSession(instructions: Prompts.matchInstructions)
        let response = try await session.respond(
            to: Prompts.matchPrompt(ingredient: ingredient, detail: detail),
            schema: schema,
            options: options
        )
        let choice = try response.content.value(String.self, forProperty: "choice")
        return FoodPick(index: Self.parseChoice(choice, count: candidates.count), rawOutput: choice)
    }

    /// "3. Oil, olive, salad or cooking" → 2 (zero-based). "none" → nil.
    static func parseChoice(_ choice: String, count: Int) -> Int? {
        guard let dot = choice.firstIndex(of: "."), let number = Int(choice[..<dot]) else { return nil }
        let index = number - 1
        return (0..<count).contains(index) ? index : nil
    }
}
