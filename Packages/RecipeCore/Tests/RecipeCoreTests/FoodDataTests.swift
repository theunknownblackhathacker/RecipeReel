import Foundation
import Testing
@testable import RecipeCore

private func tempStore() -> CustomFoodStore {
    CustomFoodStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "foods-\(UUID().uuidString).json"))
}

private let lightMayo = CustomFood(name: "Light mayonnaise", brand: "Hellmann's", source: .openFoodFacts, barcode: "8712100325953",
                                   kcal: 262, protein: 0.8, carbs: 7.1, fat: 25.6)

@Suite("My foods")
struct CustomFoodStoreTests {

    @Test func addsWithNegativeIDsAndPersists() {
        let store = tempStore()
        let first = store.add(lightMayo)
        let second = store.add(CustomFood(name: "Mirin", brand: "Kikkoman", source: .label, kcal: 241, protein: 0.2, carbs: 43, fat: 0))
        #expect(first.id == -1)
        #expect(second.id == -2)
        #expect(store.add(lightMayo).id == -1)                   // same barcode isn't saved twice

        let reloaded = CustomFoodStore(fileURL: store.fileURL)
        #expect(reloaded.all.count == 2)
        #expect(reloaded.food(id: -2)?.name == "Mirin")
        reloaded.delete(id: -1)
        #expect(CustomFoodStore(fileURL: store.fileURL).all.map(\.name) == ["Mirin"])
    }

    @Test func recordWorksWithTheCalculator() {
        let mirin = CustomFood(id: -5, name: "Mirin", source: .label, kcal: 241, protein: 0.2, carbs: 43, fat: 0, gramsPerPiece: nil)
        let line = NutritionCalculator.evaluate(quantity: 60, unit: .g, food: mirin.record)
        #expect(abs((line.macros?.kcal ?? 0) - 144.6) < 0.001)
        #expect(mirin.record.description == "Mirin (my food)")
        let tortilla = CustomFood(id: -6, name: "Wrap", source: .label, kcal: 300, protein: 8, carbs: 50, fat: 7, gramsPerPiece: 62)
        #expect(NutritionCalculator.evaluate(quantity: 2, unit: .piece, food: tortilla.record).conversion.grams == 124)
    }

    @Test func matchingByName() {
        let store = tempStore()
        store.add(lightMayo)
        store.add(CustomFood(name: "Mirin", source: .label, kcal: 241, protein: 0.2, carbs: 43, fat: 0))
        #expect(store.matching(ingredientName: "mirin").map(\.name) == ["Mirin"])
        #expect(store.matching(ingredientName: "mayonnaise").map(\.name) == ["Light mayonnaise"])
        #expect(store.matching(ingredientName: "soy sauce").isEmpty)
    }
}

@Suite("Open Food Facts")
struct OpenFoodFactsTests {

    @Test func parsesProductWithStringsAndKilojoules() {
        let product: [String: Any] = [
            "code": "5000157024671", "product_name": "Mirin rice seasoning", "brands": "Clearspring, Organic",
            "nutriments": ["energy_100g": 1008.0, "proteins_100g": "0,3", "carbohydrates_100g": 54, "fat_100g": 0, "sugars_100g": 38]
        ]
        let food = OpenFoodFactsClient.food(from: product)
        #expect(food?.name == "Mirin rice seasoning")
        #expect(food?.brand == "Clearspring")
        #expect(food?.protein == 0.3)
        #expect(abs((food?.kcal ?? 0) - 240.9) < 0.1)        // 1008 kJ ÷ 4.184
        #expect(food?.sugar == 38)
    }

    @Test func productsWithoutFullMacrosAreSkipped() {
        #expect(OpenFoodFactsClient.food(from: ["product_name": "x", "nutriments": ["energy-kcal_100g": 100]]) == nil)
        #expect(OpenFoodFactsClient.food(from: ["nutriments": ["energy-kcal_100g": 1, "proteins_100g": 1, "carbohydrates_100g": 1, "fat_100g": 1]]) == nil)
    }

    @Test func searchAndBarcodeRequests() async throws {
        let search = #"{"count":2,"products":[{"code":"1","product_name":"Light Mayonnaise","brands":"Hellmann's","nutriments":{"energy-kcal_100g":262,"proteins_100g":0.8,"carbohydrates_100g":7.1,"fat_100g":25.6}},{"code":"2","product_name":"No values","nutriments":{}}]}"#
        let found = #"{"status":1,"product":{"code":"8712100325953","product_name":"Light Mayonnaise","brands":"Hellmann's","nutriments":{"energy-kcal_100g":262,"proteins_100g":0.8,"carbohydrates_100g":7.1,"fat_100g":25.6}}}"#
        let missing = #"{"status":0,"status_verbose":"product not found"}"#
        // Products sold in Greece come first; the same product in both answers is listed once.
        let greek = #"{"count":2,"products":[{"code":"3","product_name":"Μαγιονέζα Light","brands":"Hellmann's","nutriments":{"energy-kcal_100g":290,"proteins_100g":0.7,"carbohydrates_100g":6,"fat_100g":29}},{"code":"1","product_name":"Light Mayonnaise","brands":"Hellmann's","nutriments":{"energy-kcal_100g":262,"proteins_100g":0.8,"carbohydrates_100g":7.1,"fat_100g":25.6}}]}"#
        let transport = FakeTransport([(200, greek), (200, search), (200, found), (200, missing)])
        let client = OpenFoodFactsClient(transport: transport)

        let results = try await client.search(name: "light mayonnaise", limit: 10)
        #expect(results.map(\.name) == ["Μαγιονέζα Light", "Light Mayonnaise"])
        let product = try await client.product(barcode: "8712100325953")
        #expect(product?.barcode == "8712100325953")
        #expect(try await client.product(barcode: "0000") == nil)

        let first = try #require(transport.requests.first)
        #expect(first.url?.host() == "world.openfoodfacts.org")
        #expect(first.url?.query()?.contains("search_terms=light%20mayonnaise") == true)
        #expect(first.url?.query()?.contains("tag_0=greece") == true)
        #expect(transport.requests[1].url?.query()?.contains("tag_0") == false)
        #expect(first.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("RecipeReel") == true)
        #expect(transport.requests[2].url?.path() == "/api/v2/product/8712100325953.json")
    }
}

struct FakeOnline: OnlineFoodSearching {
    var results: [CustomFood]
    func search(name: String, limit: Int) async throws -> [CustomFood] { results }
    func product(barcode: String) async throws -> CustomFood? { nil }
}

@Suite("Matching with own and online foods")
struct MatchingSourcesTests {

    private func run(_ ingredients: [RawIngredient], store: CustomFoodStore, online: (any OnlineFoodSearching)?,
                     matcher: any FoodMatching, remembered: [String: Int] = [:]) async throws -> [IngredientDraft] {
        let extractor = MockExtractor(recipe: RawRecipe(title: "", servings: 1, ingredients: ingredients),
                                      method: RawMethod(hasInstructions: false, steps: []))
        let pipeline = PipelineCoordinator(transcriber: NoMedia(), ocr: NoMedia(), extractor: extractor, matcher: matcher,
                                           database: try FixtureDatabase.make(), aiStatus: "mock",
                                           customFoods: store, onlineFoods: online)
        let report = await pipeline.extract(into: AnalysisReport(itemID: nil, aiStatus: "mock",
                                                                 timeline: SourceTimeline(caption: "x", spoken: [], onScreen: [])),
                                            rememberedMatches: remembered, update: { _ in })
        return try #require(report.outcome?.ingredients)
    }

    @Test func missingFoodIsFoundOnlineAndSaved() async throws {
        let store = tempStore()
        let mirin = CustomFood(name: "Mirin", brand: "Kikkoman", source: .openFoodFacts, barcode: "123", kcal: 241, protein: 0.2, carbs: 43, fat: 0)
        let ingredients = try await run([RawIngredient(name: "mirin", quantity: 60, unit: "g")], store: store,
                                        online: FakeOnline(results: [mirin]), matcher: MockMatcher(keywords: ["mirin": "Mirin"]))
        #expect(ingredients[0].matchStatus == .openFoodFacts)
        #expect(ingredients[0].fdcID == -1)
        #expect(store.food(id: -1)?.brand == "Kikkoman")
    }

    @Test func ownFoodsAreOfferedFirst() async throws {
        let store = tempStore()
        let saved = store.add(lightMayo)
        let ingredients = try await run([RawIngredient(name: "mayonnaise", quantity: 100, unit: "g")], store: store,
                                        online: nil, matcher: MockMatcher(keywords: ["mayonnaise": "Hellmann"]))
        #expect(ingredients[0].fdcID == saved.id)
        #expect(ingredients[0].matchStatus == .custom)
    }

    @Test func rememberedOwnFoodIsReused() async throws {
        let store = tempStore()
        let saved = store.add(lightMayo)
        let ingredients = try await run([RawIngredient(name: "low-fat mayonnaise", quantity: 100, unit: "g")], store: store,
                                        online: nil, matcher: MockMatcher(keywords: [:]),
                                        remembered: [TextMatching.normalize("low-fat mayonnaise"): saved.id])
        #expect(ingredients[0].fdcID == saved.id)
        #expect(ingredients[0].matchStatus == .remembered)
    }

    @Test func noteFindsRiceInPipeline() async throws {
        let ingredients = try await run([RawIngredient(name: "rice", quantity: 480, unit: "g", note: "short-grain or sushi rice, dry weight")],
                                        store: tempStore(), online: nil, matcher: MockMatcher(keywords: ["rice": "uncooked"]))
        #expect(ingredients[0].fdcID == 168881)
    }
}
