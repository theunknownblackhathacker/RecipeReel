import Foundation
import Testing
@testable import RecipeCore

@Suite("WebRecipeParser")
struct WebRecipeParserTests {

    @Test func howToStepsInsideGraph() throws {
        let json = """
        {"@context":"https://schema.org","@graph":[
          {"@type":"WebPage","name":"Page"},
          {"@type":["Recipe","NewsArticle"],"name":"Garlic Butter Salmon",
           "recipeIngredient":["2 salmon fillets","1 tbsp olive oil"],
           "recipeInstructions":[
             {"@type":"HowToStep","text":"Season the salmon with salt &amp; pepper."},
             {"@type":"HowToStep","text":"Sear skin-side down for 4&ndash;5 minutes."}
           ]}
        ]}
        """
        let recipe = try #require(WebRecipeParser.parse(jsonLD: ["not json", json]))
        #expect(recipe.name == "Garlic Butter Salmon")
        #expect(recipe.ingredients == ["2 salmon fillets", "1 tbsp olive oil"])
        #expect(recipe.steps == ["Season the salmon with salt & pepper.", "Sear skin-side down for 4–5 minutes."])
    }

    @Test func sectionsAndPlainStrings() throws {
        let json = """
        [{"@type":"Recipe","name":"Oats","recipeInstructions":[
          {"@type":"HowToSection","name":"Prep","itemListElement":[{"@type":"HowToStep","text":"<p>Add oats to a jar.</p>"}]},
          "Stir in the milk.",
          {"@type":"HowToStep","name":"Chill overnight."}
        ]}]
        """
        let recipe = try #require(WebRecipeParser.parse(jsonLD: [json]))
        #expect(recipe.steps == ["Add oats to a jar.", "Stir in the milk.", "Chill overnight."])
    }

    @Test func singleStringWithBreaksAndNumbers() throws {
        let json = #"{"@type":"Recipe","name":"X","recipeInstructions":"1. Preheat the oven to 180&#176;C.<br>2) Bake for 20 minutes.\nStep 3: Cool."}"#
        let recipe = try #require(WebRecipeParser.parse(jsonLD: [json]))
        #expect(recipe.steps == ["Preheat the oven to 180°C.", "Bake for 20 minutes.", "Cool."])
    }

    @Test func noRecipeMeansNil() {
        #expect(WebRecipeParser.parse(jsonLD: [#"{"@type":"Article","name":"News"}"#]) == nil)
        #expect(WebRecipeParser.parse(jsonLD: []) == nil)
    }

    @Test func microdataFallback() throws {
        let recipe = try #require(WebRecipeParser.parse(jsonLD: [], microdataInstructions: ["Chop the onion.\nFry until golden."]))
        #expect(recipe.steps == ["Chop the onion.", "Fry until golden."])
    }

    @Test func selectedTextBecomesSteps() {
        #expect(WebRecipeParser.steps(fromSelection: "Step 1\n1. Mix the flour and water.\n\n2. Knead for 10 minutes.\n•") ==
                ["Mix the flour and water.", "Knead for 10 minutes."])
    }
}

@Suite("DurationParser")
struct DurationParserTests {
    @Test func findsDurations() {
        #expect(DurationParser.minutes(in: "Bake for 20 minutes") == 20)
        #expect(DurationParser.minutes(in: "Simmer 20–25 mins until thick") == 25)
        #expect(DurationParser.minutes(in: "Rest for 1 hour") == 60)
        #expect(DurationParser.minutes(in: "Chill 1.5 hrs") == 90)
        #expect(DurationParser.minutes(in: "Preheat the oven to 200°C") == nil)
        #expect(DurationParser.minutes(in: "Cut into 2 cm pieces") == nil)
    }
}

@Suite("Suggested and web steps")
struct SuggestedStepTests {
    @Test func suggestionsAreLowConfidenceAndCleaned() {
        let raws = [
            RawStep(sourceQuote: "", text: "Heat the olive oil in a pan.", ingredientsUsed: ["olive oil"], minutes: 0),
            RawStep(sourceQuote: "", text: "Heat the olive oil in a pan", ingredientsUsed: []),        // near-duplicate
            RawStep(sourceQuote: "", text: "Cook the chicken for 6 minutes.", ingredientsUsed: ["chicken"], minutes: 6),
            RawStep(sourceQuote: "", text: "  ", ingredientsUsed: []),
            RawStep(sourceQuote: "", text: "Rest overnight.", minutes: 5000)
        ]
        let steps = ExtractionPostProcessor.cleanSuggestedSteps(raws, ingredientNames: ["olive oil", "chicken breast"])
        #expect(steps.map(\.text) == ["Heat the olive oil in a pan.", "Cook the chicken for 6 minutes.", "Rest overnight."])
        #expect(steps.allSatisfy { $0.confidence == .low })
        #expect(steps[0].ingredientNames == ["olive oil"])
        #expect(steps[1].ingredientNames == ["chicken breast"])
        #expect(steps[1].minutes == 6)
        #expect(steps[2].minutes == nil)
    }

    @Test func webStepsGetTimersAndIngredientLinks() {
        let steps = ExtractionPostProcessor.webSteps(
            ["Season the salmon fillets.", "Bake for 12–15 minutes."],
            ingredientNames: ["salmon fillet, raw", "olive oil"]
        )
        #expect(steps[0].ingredientNames == ["salmon fillet, raw"])
        #expect(steps[0].minutes == nil)
        #expect(steps[1].minutes == 15)
    }
}
