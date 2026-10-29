import Foundation

/// The two extraction passes. Real implementation: `FoundationModelsExtractor` (on-device model).
/// Tests use mocks, because the model can't run in CI.
public protocol RecipeExtracting: Sendable {
    /// Pass A — ingredients (+ title, servings) from one chunk of source text.
    func extractIngredients(from source: String) async throws -> RawRecipe
    /// Pass B — cooking steps from one chunk of source text, given the final ingredient names.
    func extractSteps(from source: String, ingredientNames: [String]) async throws -> RawMethod
}

/// The model's answer when asked to pick a database food.
public struct FoodPick: Sendable, Equatable {
    /// Index into the candidates, or nil for "none".
    public var index: Int?
    public var rawOutput: String

    public init(index: Int?, rawOutput: String) {
        self.index = index
        self.rawOutput = rawOutput
    }
}

/// Picks one food from database candidates found by Swift (the model never invents foods or numbers).
public protocol FoodMatching: Sendable {
    func pickFood(ingredient: String, detail: String, candidates: [FoodCandidate]) async throws -> FoodPick
}
