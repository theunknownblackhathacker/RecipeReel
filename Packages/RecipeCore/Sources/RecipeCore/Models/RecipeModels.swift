import Foundation
import SwiftData

// Saved recipes (SwiftData). Macros are NOT stored: they're computed from ingredients + the FDC
// database every time, so edits recalculate instantly.

@Model
public final class Recipe {
    public var id: UUID
    public var title: String
    /// How many servings the recipe makes (≥ 1).
    public var servings: Int
    /// True when the video stated the servings.
    public var servingsStated: Bool
    public var createdAt: Date
    /// The imported item (video/caption) this recipe came from.
    public var sourceItemID: UUID?
    public var caption: String?
    /// False when the video gave no method ("No instructions in this video").
    public var hasInstructions: Bool

    @Relationship(deleteRule: .cascade, inverse: \Ingredient.recipe)
    public var ingredients: [Ingredient]

    @Relationship(deleteRule: .cascade, inverse: \Step.recipe)
    public var steps: [Step]

    public init(title: String, servings: Int, servingsStated: Bool, sourceItemID: UUID?, caption: String?,
                hasInstructions: Bool) {
        self.id = UUID()
        self.title = title
        self.servings = max(1, servings)
        self.servingsStated = servingsStated
        self.createdAt = Date()
        self.sourceItemID = sourceItemID
        self.caption = caption
        self.hasInstructions = hasInstructions
        self.ingredients = []
        self.steps = []
    }

    public var sortedIngredients: [Ingredient] { ingredients.sorted { $0.order < $1.order } }
    public var sortedSteps: [Step] { steps.sorted { $0.order < $1.order } }

    /// Items needing attention on the review screen.
    public var flaggedCount: Int {
        ingredients.filter(\.needsReview).count + steps.filter(\.needsReview).count
    }
}

@Model
public final class Ingredient {
    public var order: Int
    public var name: String
    public var quantity: Double?
    public var unitRaw: String
    public var note: String
    public var confidenceRaw: String
    public var sourceQuote: String
    public var fdcID: Int?
    public var foodDescription: String?
    public var matchStatusRaw: String
    /// Set when the user has checked or edited this line.
    public var reviewed: Bool
    public var userEdited: Bool
    public var recipe: Recipe?

    public init(order: Int, name: String, quantity: Double?, unit: CanonicalUnit, note: String = "",
                confidence: Confidence = .high, sourceQuote: String = "", fdcID: Int? = nil,
                foodDescription: String? = nil, matchStatus: MatchStatus = .unmatched) {
        self.order = order
        self.name = name
        self.quantity = quantity
        self.unitRaw = unit.rawValue
        self.note = note
        self.confidenceRaw = confidence.rawValue
        self.sourceQuote = sourceQuote
        self.fdcID = fdcID
        self.foodDescription = foodDescription
        self.matchStatusRaw = matchStatus.rawValue
        self.reviewed = false
        self.userEdited = false
    }

    public var unit: CanonicalUnit {
        get { CanonicalUnit(rawValue: unitRaw) ?? .piece }
        set { unitRaw = newValue.rawValue }
    }

    public var confidence: Confidence {
        get { Confidence(rawValue: confidenceRaw) ?? .medium }
        set { confidenceRaw = newValue.rawValue }
    }

    public var matchStatus: MatchStatus {
        get { MatchStatus(rawValue: matchStatusRaw) ?? .unmatched }
        set { matchStatusRaw = newValue.rawValue }
    }

    public var needsReview: Bool {
        !reviewed && (confidence == .low || fdcID == nil && unit != .toTaste)
    }
}

@Model
public final class Step {
    public var order: Int
    public var text: String
    public var minutes: Int?
    public var ingredientNames: [String]
    public var confidenceRaw: String
    public var sourceQuote: String
    public var userEdited: Bool
    public var reviewed: Bool
    public var isDone: Bool
    public var recipe: Recipe?

    public init(order: Int, text: String, minutes: Int?, ingredientNames: [String] = [],
                confidence: Confidence = .high, sourceQuote: String = "") {
        self.order = order
        self.text = text
        self.minutes = minutes
        self.ingredientNames = ingredientNames
        self.confidenceRaw = confidence.rawValue
        self.sourceQuote = sourceQuote
        self.userEdited = false
        self.reviewed = false
        self.isDone = false
    }

    public var confidence: Confidence {
        get { Confidence(rawValue: confidenceRaw) ?? .medium }
        set { confidenceRaw = newValue.rawValue }
    }

    public var needsReview: Bool { !reviewed && !userEdited && confidence == .low }
}

public enum RecipeFactory {
    /// Builds a Recipe (with ingredients and steps) from an extraction. Insert it into a ModelContext.
    public static func makeRecipe(from outcome: ExtractionOutcome, sourceItemID: UUID?, caption: String?,
                                  fallbackTitle: String) -> Recipe {
        let title = outcome.title.isEmpty ? fallbackTitle : outcome.title
        let recipe = Recipe(
            title: title,
            servings: outcome.servings ?? 1,
            servingsStated: outcome.servings != nil,
            sourceItemID: sourceItemID,
            caption: caption,
            hasInstructions: outcome.hasInstructions && !outcome.steps.isEmpty
        )
        recipe.ingredients = outcome.ingredients.enumerated().map { index, draft in
            Ingredient(order: index, name: draft.name, quantity: draft.quantity, unit: draft.unit, note: draft.note,
                       confidence: draft.confidence, sourceQuote: draft.sourceQuote, fdcID: draft.fdcID,
                       foodDescription: draft.foodDescription, matchStatus: draft.matchStatus)
        }
        recipe.steps = outcome.steps.enumerated().map { index, draft in
            Step(order: index, text: draft.text, minutes: draft.minutes, ingredientNames: draft.ingredientNames,
                 confidence: draft.confidence, sourceQuote: draft.sourceQuote)
        }
        return recipe
    }
}
