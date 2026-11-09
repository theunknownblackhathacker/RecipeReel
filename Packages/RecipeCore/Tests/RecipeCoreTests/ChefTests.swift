import Foundation
import Testing
@testable import RecipeCore

@Suite("Ask the chef")
struct ChefTests {

    static let recipe = ChefRecipe(
        title: "Garlic butter pasta",
        yield: 2,
        ingredients: [
            .init(key: 0, name: "spaghetti", quantity: 200, unit: .g, fdcID: 1, matchStatus: .matched),
            .init(key: 1, name: "butter", quantity: 40, unit: .g, group: "Sauce", fdcID: 2, matchStatus: .matched),
            .init(key: 2, name: "garlic", quantity: 2, unit: .clove, note: "minced", group: "Sauce"),
            .init(key: 3, name: "salt", quantity: nil, unit: .toTaste)
        ],
        steps: [
            .init(key: 0, text: "Boil the spaghetti until al dente.", minutes: 10, origin: .video),
            .init(key: 1, text: "Melt the butter and fry the garlic.", minutes: nil, origin: .video),
            .init(key: 2, text: "Toss the pasta in the sauce.", minutes: nil, origin: .video)
        ]
    )

    static let foods: [Int: FoodRecord] = [
        1: FoodRecord(fdcID: 1, description: "Pasta, dry", nutrients: FoodNutrients(kcal: 360, protein: 12, fat: 1.5, carbs: 72)),
        2: FoodRecord(fdcID: 2, description: "Butter", nutrients: FoodNutrients(kcal: 740, protein: 0.7, fat: 82, carbs: 0.6)),
        3: FoodRecord(fdcID: 3, description: "Parmesan", nutrients: FoodNutrients(kcal: 390, protein: 35, fat: 30, carbs: 0))
    ]

    @Test func promptListsIdsAndKeepsRecentTurns() {
        let history = (1...50).map { ChefTurn(role: $0.isMultiple(of: 2) ? .chef : .user, text: "turn \($0) " + String(repeating: "x", count: 100)) }
        let prompt = Chef.prompt(recipe: Self.recipe, macros: "500 kcal", history: history, message: "Make it richer", maxCharacters: 2_000)
        #expect(prompt.contains("i2. [Sauce] 40 g butter"))
        #expect(prompt.contains("i3. [Sauce] 2 clove garlic (minced)"))
        #expect(prompt.contains("i4. to taste: salt"))
        #expect(prompt.contains("s1. Boil the spaghetti until al dente. [10 min]"))
        #expect(prompt.contains("amounts for 2 servings"))
        #expect(prompt.hasSuffix("User: Make it richer"))
        #expect(prompt.contains("turn 50"))          // newest kept
        #expect(!prompt.contains("turn 1 "))         // oldest dropped
        #expect(prompt.count <= 2_000)
    }

    @Test func validateKeepsGoodEditsAndDropsBadOnes() {
        let raws = [
            RawChefChange(action: "add_ingredient", name: "parmesan", quantity: 30, unit: "g", note: "grated", group: "sauce"),
            RawChefChange(action: "change_ingredient", target: "i3", name: "garlic", quantity: 4, unit: "cloves", note: "minced", group: "Sauce"),
            RawChefChange(action: "remove_ingredient", target: "i9"),                 // no such ingredient
            RawChefChange(action: "change_ingredient", target: "i2", name: "butter", quantity: 40, unit: "g", group: "Sauce"),  // no-op
            RawChefChange(action: "add_step", text: "Stir in the parmesan off the heat.", position: 2),
            RawChefChange(action: "make_coffee"),
            RawChefChange(action: "set_servings", quantity: 3)
        ]
        let proposal = Chef.validate(raws, recipe: Self.recipe)
        #expect(proposal.changes.count == 4)
        #expect(proposal.lines == [
            "Add 30 g parmesan (grated) — Sauce",
            "Change 2 cloves garlic (minced) → 4 cloves (minced)",
            "New step after step 2: Stir in the parmesan off the heat.",
            "Recipe makes 3 servings (amounts as written)"
        ])
        #expect(proposal.dropped.count == 2)
        // The group the model wrote in lower case is matched to the recipe's own.
        if case .addIngredient(let edit) = proposal.changes[0] {
            #expect(edit.group == "Sauce")
            #expect(proposal.changes[0].needsFoodMatch)
        } else {
            Issue.record("expected an added ingredient")
        }
        #expect(!proposal.changes[1].needsFoodMatch)   // same name: keeps its food match
    }

    @Test func applyEditsIngredientsAndPlacesSteps() {
        let changes: [ChefChange] = [
            .addIngredient(IngredientEdit(name: "parmesan", quantity: 30, unit: .g, group: "Sauce", fdcID: 3,
                                          foodDescription: "Parmesan", matchStatus: .matched)),
            .changeIngredient(key: 2, oldName: "garlic", IngredientEdit(name: "garlic", quantity: 4, unit: .clove, note: "minced", group: "Sauce")),
            .removeIngredient(key: 3, oldName: "salt"),
            .addStep(after: 2, text: "Stir in the parmesan off the heat.", minutes: nil),
            .addStep(after: 0, text: "Bring a big pot of salted water to the boil.", minutes: nil),
            .changeStep(key: 0, oldText: "Boil the spaghetti until al dente.", text: "Boil the spaghetti 1 minute less than the pack says.", minutes: 9),
            .removeStep(key: 2, oldText: "Toss the pasta in the sauce.")
        ]
        let result = Chef.apply(changes, to: Self.recipe)
        #expect(result.ingredients.map(\.name) == ["spaghetti", "butter", "garlic", "parmesan"])
        let garlic = result.ingredients[2]
        #expect(garlic.quantity == 4 && garlic.key == 2 && garlic.changedByChef)
        #expect(result.ingredients[3].fdcID == 3)
        #expect(result.steps.map(\.text) == [
            "Bring a big pot of salted water to the boil.",
            "Boil the spaghetti 1 minute less than the pack says.",
            "Melt the butter and fry the garlic.",
            "Stir in the parmesan off the heat."
        ])
        #expect(result.steps[1].origin == .chef && result.steps[1].minutes == 9)
        #expect(result.steps[2].origin == .video)                 // untouched
        #expect(result.steps[3].ingredientNames == ["parmesan"])
    }

    @Test func applyFindsTargetsByNameWhenTheListChanged() {
        var changed = Self.recipe
        changed.ingredients.remove(at: 0)          // the user deleted the spaghetti after the proposal
        let result = Chef.apply([.changeIngredient(key: 2, oldName: "garlic",
                                                   IngredientEdit(name: "garlic", quantity: 3, unit: .clove, group: "Sauce"))],
                                to: changed)
        #expect(result.ingredients.first { $0.name == "garlic" }?.quantity == 3)
        #expect(result.ingredients.count == 3)
    }

    @Test func macrosComeFromTheAppNotTheModel() {
        let food: (Int?) -> FoodRecord? = { $0.flatMap { Self.foods[$0] } }
        let before = Chef.perServing(Self.recipe, food: food)
        #expect(abs(before.perServing.kcal - (720 + 296) / 2) < 0.5)      // 200 g pasta + 40 g butter, 2 servings
        let after = Chef.perServing(Chef.apply([.addIngredient(IngredientEdit(name: "parmesan", quantity: 40, unit: .g,
                                                                              fdcID: 3, matchStatus: .matched))],
                                               to: Self.recipe), food: food)
        let line = Chef.previewLine(before: before, after: after)
        #expect(line == "Per serving: 508 → 586 kcal · protein 12 → 19 g · carbs 72 g · fat 18 → 24 g")
    }

    @Test func cloudChefReplyIsDecoded() async throws {
        let json = #"{"reply":"Add parmesan for depth.","changes":[{"action":"add_ingredient","target":"","name":"parmesan","quantity":30,"unit":"g","note":"grated","group":"Sauce","text":"","minutes":0,"position":0}]}"#
        let body = #"{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":\#(Self.literal(json))}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5}}"#
        let transport = FakeTransport([(200, body)])
        let extractor = try CloudExtractor(config: CloudConfig(provider: .anthropic, model: "m", baseURL: "", apiKey: "k"),
                                           transport: transport)
        let reply = try await extractor.chef(instructions: Chef.instructions, prompt: "Make it tastier")
        #expect(reply.reply == "Add parmesan for depth.")
        #expect(reply.changes == [RawChefChange(action: "add_ingredient", name: "parmesan", quantity: 30, unit: "g",
                                                note: "grated", group: "Sauce")])
        let sent = try #require(transport.requests.first?.httpBody)
        #expect(String(decoding: sent, as: UTF8.self).contains("add_ingredient"))     // the action list is in the schema
    }

    @Test func proposalSurvivesStorage() throws {
        let proposal = Chef.validate([RawChefChange(action: "rename_recipe", text: "Silky garlic butter pasta")], recipe: Self.recipe)
        let decoded = try JSONDecoder().decode(ChefProposal.self, from: JSONEncoder().encode(proposal))
        #expect(decoded == proposal)
        #expect(decoded.changes == [.rename("Silky garlic butter pasta")])
    }

    private static func literal(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
    }
}
