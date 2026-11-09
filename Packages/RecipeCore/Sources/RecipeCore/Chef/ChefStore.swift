import Foundation
import SwiftData

/// One message in a recipe's chef conversation. Each recipe has its own conversation (by `recipeID`);
/// messages are deleted with the recipe.
@Model
public final class ChefMessage {
    public enum Role: String, Sendable { case user, chef, error }
    public enum Status: String, Sendable { case pending = "", applied, undone }

    public var recipeID: UUID
    public var createdAt: Date
    public var roleRaw: String
    public var text: String
    /// JSON of `ChefProposal` (the chef's edits), nil when the reply has none.
    public var proposalData: Data?
    /// JSON of the recipe (`ChefRecipe`) before the edits were applied, for Undo.
    public var undoData: Data?
    public var statusRaw: String
    /// "Per serving: 571 → 498 kcal …" worked out by the app when the reply arrived.
    public var preview: String

    public init(recipeID: UUID, role: Role, text: String, proposal: ChefProposal? = nil, preview: String = "") {
        self.recipeID = recipeID
        self.createdAt = Date()
        self.roleRaw = role.rawValue
        self.text = text
        self.proposalData = proposal.flatMap { $0.isEmpty ? nil : try? JSONEncoder().encode($0) }
        self.undoData = nil
        self.statusRaw = Status.pending.rawValue
        self.preview = preview
    }

    public var role: Role { Role(rawValue: roleRaw) ?? .chef }

    public var status: Status {
        get { Status(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    /// Deletes a recipe's whole conversation (when the recipe is deleted).
    public static func deleteConversation(of recipeID: UUID, in context: ModelContext) {
        let descriptor = FetchDescriptor<ChefMessage>(predicate: #Predicate { $0.recipeID == recipeID })
        for message in (try? context.fetch(descriptor)) ?? [] {
            context.delete(message)
        }
    }

    public var proposal: ChefProposal? {
        proposalData.flatMap { try? JSONDecoder().decode(ChefProposal.self, from: $0) }
    }

    public var undoSnapshot: ChefRecipe? {
        get { undoData.flatMap { try? JSONDecoder().decode(ChefRecipe.self, from: $0) } }
        set { undoData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}

extension Chef {

    /// Per-serving macros of a recipe copy, worked out by the app (never by the model).
    public static func perServing(_ recipe: ChefRecipe, food: (Int?) -> FoodRecord?) -> RecipeNutrition {
        let lines = recipe.ingredients.map {
            NutritionCalculator.evaluate(quantity: $0.quantity, unit: $0.unit, food: food($0.fdcID))
        }
        return NutritionCalculator.summarize(lines, servings: recipe.yield)
    }

    /// Short macro line for the prompt: "571 kcal, protein 45 g, carbs 30 g, fat 28 g".
    public static func macroLine(_ nutrition: RecipeNutrition) -> String {
        let m = nutrition.perServing
        return String(format: "%.0f kcal, protein %.0f g, carbs %.0f g, fat %.0f g", m.kcal, m.protein, m.carbs, m.fat)
    }

    /// "Per serving: 571 → 498 kcal · protein 45 → 47 g · carbs 30 → 22 g · fat 28 → 21 g".
    public static func previewLine(before: RecipeNutrition, after: RecipeNutrition) -> String {
        let b = before.perServing, a = after.perServing
        func part(_ label: String, _ x: Double, _ y: Double, _ unit: String) -> String {
            let from = String(format: "%.0f", x), to = String(format: "%.0f", y)
            return from == to ? "\(label) \(from)\(unit)" : "\(label) \(from) → \(to)\(unit)"
        }
        return "Per serving: " + [part("", b.kcal, a.kcal, " kcal").trimmingCharacters(in: .whitespaces),
                                  part("protein", b.protein, a.protein, " g"),
                                  part("carbs", b.carbs, a.carbs, " g"),
                                  part("fat", b.fat, a.fat, " g")].joined(separator: " · ")
    }
}

extension RecipeFactory {

    /// Makes a saved recipe match `target`. Items with a `key` update the saved ingredient/step at that
    /// position (keeping done marks and identity); the rest are created; saved ones not in `target` are
    /// deleted. With `replaceAll` (Undo) every ingredient and step is recreated from `target`.
    public static func update(_ recipe: Recipe, to target: ChefRecipe, context: ModelContext, replaceAll: Bool = false) {
        let oldIngredients = recipe.sortedIngredients
        let oldSteps = recipe.sortedSteps

        recipe.title = target.title
        if target.yield != recipe.yield {
            let wasCookingYield = recipe.servings == recipe.yield
            recipe.yieldServings = target.yield
            if wasCookingYield { recipe.servings = target.yield }
        }

        var keptIngredients = Set<Int>()
        var ingredients: [Ingredient] = []
        for (order, item) in target.ingredients.enumerated() {
            let ingredient: Ingredient
            if !replaceAll, let key = item.key, key < oldIngredients.count, keptIngredients.insert(key).inserted {
                ingredient = oldIngredients[key]
            } else {
                ingredient = Ingredient(order: order, name: item.name, quantity: item.quantity, unit: item.unit)
            }
            ingredient.order = order
            ingredient.name = item.name
            ingredient.quantity = item.quantity
            ingredient.unit = item.unit
            ingredient.note = item.note
            ingredient.group = item.group
            ingredient.fdcID = item.fdcID
            ingredient.foodDescription = item.foodDescription
            ingredient.matchStatus = item.matchStatus
            ingredient.confidence = item.confidence
            ingredient.sourceQuote = item.sourceQuote
            ingredient.reviewed = item.reviewed
            if item.changedByChef { ingredient.userEdited = true }
            ingredients.append(ingredient)
        }
        for (index, old) in oldIngredients.enumerated() where !keptIngredients.contains(index) {
            context.delete(old)
        }
        recipe.ingredients = ingredients

        var keptSteps = Set<Int>()
        var steps: [Step] = []
        for (order, item) in target.steps.enumerated() {
            let step: Step
            if !replaceAll, let key = item.key, key < oldSteps.count, keptSteps.insert(key).inserted {
                step = oldSteps[key]
            } else {
                step = Step(order: order, text: item.text, minutes: item.minutes, origin: item.origin)
            }
            if step.text != item.text { step.userEdited = true }
            step.order = order
            step.text = item.text
            step.minutes = item.minutes
            step.ingredientNames = item.ingredientNames
            step.origin = item.origin
            step.confidence = item.confidence
            step.sourceQuote = item.sourceQuote
            steps.append(step)
        }
        for (index, old) in oldSteps.enumerated() where !keptSteps.contains(index) {
            context.delete(old)
        }
        recipe.steps = steps
        recipe.hasInstructions = !steps.isEmpty
    }
}
