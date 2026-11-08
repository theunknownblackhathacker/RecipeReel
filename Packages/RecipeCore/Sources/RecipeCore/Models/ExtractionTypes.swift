import Foundation

// Plain, Sendable mirrors of what the model produces. The Foundation Models implementation maps its
// @Generable types into these, so the rest of the pipeline (and the CI tests with mocks) never
// depends on the model framework.

/// Pass A output for one ingredient, as the model wrote it.
public struct RawIngredient: Codable, Sendable, Equatable {
    public var sourceQuote: String
    /// The heading the ingredient is listed under ("Alfredo sauce"), empty if none.
    public var group: String?
    public var name: String
    public var quantity: Double
    public var unit: String
    public var note: String
    public var confidence: String

    public init(sourceQuote: String = "", group: String = "", name: String, quantity: Double, unit: String,
                note: String = "", confidence: String = "high") {
        self.sourceQuote = sourceQuote
        self.group = group
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.note = note
        self.confidence = confidence
    }
}

/// Pass A output for one chunk of source text.
public struct RawRecipe: Codable, Sendable, Equatable {
    public var title: String
    public var servings: Int
    public var ingredients: [RawIngredient]
    /// The model's output as text, for the Diagnostics screen.
    public var rawOutput: String

    public init(title: String, servings: Int, ingredients: [RawIngredient], rawOutput: String = "") {
        self.title = title
        self.servings = servings
        self.ingredients = ingredients
        self.rawOutput = rawOutput
    }
}

/// Pass B output for one step, as the model wrote it.
public struct RawStep: Codable, Sendable, Equatable {
    public var sourceQuote: String
    public var text: String
    public var ingredientsUsed: [String]
    public var minutes: Int
    public var confidence: String

    public init(sourceQuote: String, text: String, ingredientsUsed: [String] = [],
                minutes: Int = 0, confidence: String = "high") {
        self.sourceQuote = sourceQuote
        self.text = text
        self.ingredientsUsed = ingredientsUsed
        self.minutes = minutes
        self.confidence = confidence
    }
}

/// Pass B output for one chunk of source text.
public struct RawMethod: Codable, Sendable, Equatable {
    public var hasInstructions: Bool
    public var steps: [RawStep]
    public var rawOutput: String

    public init(hasInstructions: Bool, steps: [RawStep], rawOutput: String = "") {
        self.hasInstructions = hasInstructions
        self.steps = steps
        self.rawOutput = rawOutput
    }
}

/// A candidate food from the nutrition database, offered to the model to pick from.
public struct FoodCandidate: Codable, Sendable, Equatable, Identifiable {
    public var fdcID: Int
    public var description: String
    /// Database table: "ciqual", "cofid", or a USDA data type. Nil for older saved results.
    public var dataType: String?
    public var id: Int { fdcID }

    public init(fdcID: Int, description: String, dataType: String? = nil) {
        self.fdcID = fdcID
        self.description = description
        self.dataType = dataType
    }

    /// "Ciqual (France)", "CoFID (UK)" or "USDA".
    public var sourceName: String { FoodSources.name(forDataType: dataType) }
}

// MARK: - Cleaned results (after Swift post-processing)

public enum MatchStatus: String, Codable, Sendable {
    /// The model picked a database food.
    case matched
    /// Re-used the user's earlier manual choice for this ingredient name.
    case remembered
    /// The user picked it by hand.
    case manual
    /// One of the user's own foods (from a label).
    case custom
    /// Found online on Open Food Facts.
    case openFoodFacts
    /// No suitable food found.
    case unmatched
}

public struct IngredientDraft: Codable, Sendable, Equatable {
    public var name: String
    /// Nil when no amount was stated anywhere.
    public var quantity: Double?
    public var unit: CanonicalUnit
    public var note: String
    public var confidence: Confidence
    public var sourceQuote: String
    public var fdcID: Int?
    public var foodDescription: String?
    public var matchStatus: MatchStatus
    /// Part of the recipe the ingredient belongs to ("Chicken", "Alfredo sauce"); nil or empty if none.
    public var group: String?

    public init(name: String, quantity: Double?, unit: CanonicalUnit, note: String = "",
                confidence: Confidence, sourceQuote: String = "", fdcID: Int? = nil,
                foodDescription: String? = nil, matchStatus: MatchStatus = .unmatched, group: String? = nil) {
        self.group = group
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.note = note
        self.confidence = confidence
        self.sourceQuote = sourceQuote
        self.fdcID = fdcID
        self.foodDescription = foodDescription
        self.matchStatus = matchStatus
    }
}

public struct StepDraft: Codable, Sendable, Equatable {
    public var text: String
    public var minutes: Int?
    public var ingredientNames: [String]
    public var confidence: Confidence
    public var sourceQuote: String
    /// True when the step was written from the video's pictures (no text described it).
    public var fromPictures: Bool?

    public init(text: String, minutes: Int?, ingredientNames: [String], confidence: Confidence, sourceQuote: String,
                fromPictures: Bool? = nil) {
        self.text = text
        self.minutes = minutes
        self.ingredientNames = ingredientNames
        self.confidence = confidence
        self.sourceQuote = sourceQuote
        self.fromPictures = fromPictures
    }
}

/// Everything extracted for one video, ready to become a saved Recipe.
public struct ExtractionOutcome: Codable, Sendable, Equatable {
    public var title: String
    /// Nil when not stated.
    public var servings: Int?
    public var ingredients: [IngredientDraft]
    public var steps: [StepDraft]
    /// False when the source gives no method ("No instructions in this video").
    public var hasInstructions: Bool
    /// Steps removed by the anti-invention checks, with the reason (for Diagnostics).
    public var droppedSteps: [String]

    public init(title: String, servings: Int?, ingredients: [IngredientDraft], steps: [StepDraft],
                hasInstructions: Bool, droppedSteps: [String] = []) {
        self.title = title
        self.servings = servings
        self.ingredients = ingredients
        self.steps = steps
        self.hasInstructions = hasInstructions
        self.droppedSteps = droppedSteps
    }
}
