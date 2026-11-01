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

/// One step written from the video's pictures, citing the frames it's based on.
public struct RawVisualStep: Sendable, Equatable {
    public var text: String
    public var ingredientsUsed: [String]
    public var frameTimes: [Double]
    public var minutes: Int
    public var confidence: String

    public init(text: String, ingredientsUsed: [String] = [], frameTimes: [Double], minutes: Int = 0, confidence: String = "medium") {
        self.text = text
        self.ingredientsUsed = ingredientsUsed
        self.frameTimes = frameTimes
        self.minutes = minutes
        self.confidence = confidence
    }
}

public struct RawVisualMethod: Sendable, Equatable {
    public var hasInstructions: Bool
    public var steps: [RawVisualStep]
    public var rawOutput: String

    public init(hasInstructions: Bool, steps: [RawVisualStep], rawOutput: String = "") {
        self.hasInstructions = hasInstructions
        self.steps = steps
        self.rawOutput = rawOutput
    }
}

/// Writes steps from the video's key frames when no text describes the method (vision-capable cloud models).
public protocol VisualStepExtracting: Sendable {
    func extractStepsFromFrames(_ frames: [KeyFrame], sourceText: String, ingredientNames: [String]) async throws -> RawVisualMethod
}

/// Writes a suggested method when the video has none (only when the user asks for it).
/// The result is always labelled "Suggested — not from the video" in the app.
public protocol StepSuggesting: Sendable {
    func suggestSteps(title: String, ingredients: [String]) async throws -> [RawStep]
}
