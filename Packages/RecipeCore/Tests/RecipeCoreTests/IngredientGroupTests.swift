import Foundation
import Testing
@testable import RecipeCore

@Suite("Ingredient groups (parts of a recipe)")
struct IngredientGroupTests {

    /// Roughly what the model returns for the Crispy Chicken Alfredo Burritos caption.
    static let burrito = RawRecipe(title: "Crispy Chicken Alfredo Burritos", servings: 0, ingredients: [
        RawIngredient(group: "Chicken", name: "chicken breast", quantity: 500, unit: "g", note: "chopped into small pieces"),
        RawIngredient(group: "Chicken", name: "avocado oil", quantity: 1, unit: "tbsp"),
        RawIngredient(group: "Chicken", name: "cajun seasoning", quantity: 1, unit: "tsp"),
        RawIngredient(group: "Chicken", name: "salt", quantity: 0, unit: "to_taste"),
        RawIngredient(group: "For the Alfredo Sauce:", name: "butter", quantity: 2, unit: "tbsp"),
        RawIngredient(group: "Alfredo sauce", name: "heavy cream", quantity: 355, unit: "ml"),
        RawIngredient(group: "Alfredo sauce", name: "parmesan", quantity: 50, unit: "g"),
        RawIngredient(group: "Alfredo sauce", name: "salt", quantity: 0, unit: "to_taste"),
        RawIngredient(group: "The filling", name: "cooked chicken", quantity: 0, unit: "piece"),
        RawIngredient(group: "The filling", name: "All of the Alfredo sauce", quantity: 0, unit: "piece"),
        RawIngredient(group: "The filling", name: "mozzarella", quantity: 100, unit: "g"),
        RawIngredient(group: "The filling", name: "curly parsley", quantity: 1, unit: "tbsp", note: "a handful, chopped", confidence: "low"),
        RawIngredient(group: "Time to make it crispy", name: "flour tortillas", quantity: 4, unit: "piece"),
        RawIngredient(group: "Time to make it crispy", name: "eggs", quantity: 2, unit: "piece"),
        RawIngredient(group: "Time to make it crispy", name: "panko", quantity: 100, unit: "g"),
        RawIngredient(group: "Time to make it crispy", name: "oil", quantity: 0, unit: "ml", note: "for frying"),
        // The voice repeats an ingredient without a heading.
        RawIngredient(group: "", name: "mozzarella", quantity: 100, unit: "g")
    ])

    @Test func keepsPartsAndDropsReferences() {
        let merged = ExtractionPostProcessor.mergeIngredients([Self.burrito])
        let names = merged.ingredients.map(\.name)
        #expect(!names.contains("cooked chicken"))
        #expect(!names.contains("All of the Alfredo sauce"))
        #expect(names.filter { $0 == "salt" }.count == 2)          // once for the chicken, once for the sauce
        #expect(names.filter { $0 == "mozzarella" }.count == 1)    // ungrouped repeat removed
        #expect(merged.ingredients.count == 14)

        let groups = IngredientGroup.make(merged.ingredients) { $0.group ?? "" }
        #expect(groups.map(\.title) == ["Chicken", "Alfredo Sauce", "The filling", "Time to make it crispy"])
        #expect(groups.map(\.items.count) == [4, 4, 2, 4])
    }

    @Test func groupNamesAreCleaned() {
        #expect(IngredientGroups.clean("For the Alfredo Sauce:") == "Alfredo Sauce")
        #expect(IngredientGroups.clean(" sauce - ") == "Sauce")
        #expect(IngredientGroups.key("Alfredo sauce") == IngredientGroups.key("For the ALFREDO SAUCE"))
        #expect(IngredientGroups.isNoGroup("Ingredients:"))
        #expect(IngredientGroups.isNoGroup("You'll need"))
        #expect(!IngredientGroups.isNoGroup("Marinade"))
    }

    @Test func singleHeadingOverEverythingIsDropped() {
        let raw = RawRecipe(title: "", servings: 0, ingredients: [
            RawIngredient(group: "Teriyaki chicken", name: "chicken thighs", quantity: 500, unit: "g"),
            RawIngredient(group: "Teriyaki chicken", name: "soy sauce", quantity: 75, unit: "g")
        ])
        let merged = ExtractionPostProcessor.mergeIngredients([raw])
        #expect(merged.ingredients.allSatisfy { $0.group == nil })
    }

    @Test func oneHeadingPerLineIsDropped() {
        let raw = RawRecipe(title: "", servings: 0, ingredients: [
            RawIngredient(group: "Rice", name: "rice", quantity: 200, unit: "g"),
            RawIngredient(group: "Egg", name: "egg", quantity: 2, unit: "piece"),
            RawIngredient(group: "Soy sauce", name: "soy sauce", quantity: 1, unit: "tbsp")
        ])
        let merged = ExtractionPostProcessor.mergeIngredients([raw])
        #expect(merged.ingredients.allSatisfy { $0.group == nil })
    }

    @Test func recipesWithoutHeadingsAreUnchanged() {
        let raw = RawRecipe(title: "", servings: 0, ingredients: [
            RawIngredient(name: "cooked rice", quantity: 200, unit: "g"),
            RawIngredient(name: "egg", quantity: 2, unit: "piece"),
            RawIngredient(name: "egg", quantity: 2, unit: "piece")
        ])
        let merged = ExtractionPostProcessor.mergeIngredients([raw])
        #expect(merged.ingredients.map(\.name) == ["cooked rice", "egg"])
        #expect(IngredientGroup.make(merged.ingredients) { $0.group ?? "" }.map(\.title) == [""])
    }

    @Test func selfTestChecksParts() throws {
        let testCase = try #require(ExtractionSelfTest.cases.first { !$0.groups.isEmpty })
        let merged = ExtractionPostProcessor.mergeIngredients([Self.burrito])
        let outcome = ExtractionOutcome(title: "", servings: 4, ingredients: merged.ingredients, steps: [], hasInstructions: false)
        let parts = ExtractionSelfTest.evaluate(testCase, outcome: outcome).filter { $0.message.hasPrefix("parts") }
        #expect(parts.count == 1)
        #expect(parts.first?.passed == true)
    }

    @Test func uniqueNamesKeepOrder() {
        #expect(IngredientGroups.uniqueNames(["salt", "butter", "Salt", "cream"]) == ["salt", "butter", "cream"])
    }

    @Test func cloudSchemaAsksForGroup() throws {
        let items = try #require((CloudSchemas.recipe["properties"] as? [String: Any])?["ingredients"] as? [String: Any])
        let item = try #require(items["items"] as? [String: Any])
        let required = try #require(item["required"] as? [String])
        #expect(required.contains("group"))
    }
}
