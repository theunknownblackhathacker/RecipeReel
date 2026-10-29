import Foundation
import Testing
@testable import RecipeCore

// MARK: - Mocks (the real model can't run in CI)

struct MockExtractor: RecipeExtracting {
    var recipe: RawRecipe
    var method: RawMethod

    func extractIngredients(from source: String) async throws -> RawRecipe { recipe }
    func extractSteps(from source: String, ingredientNames: [String]) async throws -> RawMethod { method }
}

struct FailingExtractor: RecipeExtracting {
    struct Boom: Error {}
    func extractIngredients(from source: String) async throws -> RawRecipe { throw Boom() }
    func extractSteps(from source: String, ingredientNames: [String]) async throws -> RawMethod { throw Boom() }
}

/// Picks the first candidate whose description contains `keyword` for each ingredient.
struct MockMatcher: FoodMatching {
    var keywords: [String: String]

    func pickFood(ingredient: String, detail: String, candidates: [FoodCandidate]) async throws -> FoodPick {
        guard let keyword = keywords[ingredient],
              let index = candidates.firstIndex(where: { $0.description.localizedCaseInsensitiveContains(keyword) })
        else { return FoodPick(index: nil, rawOutput: "none") }
        return FoodPick(index: index, rawOutput: "\(index + 1). \(candidates[index].description)")
    }
}

struct NoMedia: TranscriptionService, FrameOCRService {
    func transcribe(videoURL: URL, status: @escaping @Sendable (String) -> Void) async throws -> [TranscriptSegment] { [] }
    func readText(videoURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [OCRLine] { [] }
}

private func coordinator(_ extractor: (any RecipeExtracting)?, matcher: (any FoodMatching)? = nil,
                         database: FDCDatabase? = nil) -> PipelineCoordinator {
    PipelineCoordinator(transcriber: NoMedia(), ocr: NoMedia(), extractor: extractor, matcher: matcher,
                        database: database, aiStatus: "mock")
}

private func runCase(_ index: Int, extractor: (any RecipeExtracting)?, matcher: (any FoodMatching)? = nil,
                     database: FDCDatabase? = nil) async -> AnalysisReport {
    let testCase = ExtractionSelfTest.cases[index]
    let start = AnalysisReport(itemID: nil, aiStatus: "mock", timeline: testCase.timeline)
    return await coordinator(extractor, matcher: matcher, database: database)
        .extract(into: start, rememberedMatches: [:], update: { _ in })
}

// MARK: - Post-processing

@Suite("ExtractionPostProcessor")
struct PostProcessorTests {

    @Test func ingredientsAreCleanedAndMergedNotSummed() {
        let raws = [
            RawRecipe(title: "Stir fry", servings: 0, ingredients: [
                RawIngredient(name: "chicken breast", quantity: 200, unit: "g"),
                RawIngredient(name: "Chicken breast", quantity: 200, unit: "g"),   // OCR repeat
                RawIngredient(name: "protein", quantity: 38, unit: "g"),          // nutrition claim
                RawIngredient(name: "salt", quantity: 0, unit: "g"),
                RawIngredient(name: "soy sauce", quantity: 1, unit: "tablespoons", confidence: "medium")
            ]),
            RawRecipe(title: "", servings: 1, ingredients: [RawIngredient(name: "chicken breasts", quantity: 200, unit: "g")])
        ]
        let merged = ExtractionPostProcessor.mergeIngredients(raws)
        #expect(merged.title == "Stir fry")
        #expect(merged.servings == 1)
        #expect(merged.ingredients.map(\.name) == ["chicken breast", "salt", "soy sauce"])
        #expect(merged.ingredients[0].quantity == 200)
        #expect(merged.ingredients[1].quantity == nil)
        #expect(merged.ingredients[1].unit == .toTaste)
        #expect(merged.ingredients[1].confidence == .low)
        #expect(merged.ingredients[2].unit == .tbsp)
        #expect(merged.ingredients[2].confidence == .medium)
    }

    @Test func numbersAreParsed() {
        #expect(ExtractionPostProcessor.numbers(in: "Bake at 180°C for 20-25 min, 1/2 cup") == [180, 20, 25, 0.5, 1, 2])
    }

    @Test func minutesMustBeStated() {
        #expect(ExtractionPostProcessor.minutesStated(1, in: "Baste for a minute"))
        #expect(ExtractionPostProcessor.minutesStated(20, in: "bake for 20 min"))
        #expect(ExtractionPostProcessor.minutesStated(10, in: "simmer for ten minutes"))
        #expect(ExtractionPostProcessor.minutesStated(60, in: "rest for an hour"))
        #expect(ExtractionPostProcessor.minutesStated(120, in: "marinate for 2 hours"))
        #expect(!ExtractionPostProcessor.minutesStated(4, in: "Sear them skin side down in a tablespoon of olive oil"))
    }

    @Test func methodVocabulary() {
        #expect(ExtractionPostProcessor.sourceDescribesMethod("stir it, fridge overnight"))
        #expect(!ExtractionPostProcessor.sourceDescribesMethod("125g cooked basmati\nSERVES 1\n#cooking"))
    }
}

// MARK: - Full extraction with mocks (the recipe-test-cases.md cases)

@Suite("Pipeline with mocks")
struct PipelineMockTests {

    @Test func case3InventedStepsAreAllDropped() async throws {
        // The model is tempted to write a stir-fry method for an ingredient-only video.
        let extractor = MockExtractor(
            recipe: RawRecipe(title: "", servings: 1, ingredients: [
                RawIngredient(name: "chicken breast", quantity: 200, unit: "g"),
                RawIngredient(name: "broccoli", quantity: 100, unit: "g")
            ]),
            method: RawMethod(hasInstructions: true, steps: [
                RawStep(sourceQuote: "200g chicken breast", text: "Cook the chicken breast in a hot pan for 6 minutes", minutes: 6),
                RawStep(sourceQuote: "Stir-fry everything for 5 minutes", text: "Stir-fry everything for 5 minutes", minutes: 5),
                RawStep(sourceQuote: "125g cooked basmati", text: "Serve with the cooked basmati")
            ])
        )
        let report = await runCase(2, extractor: extractor)
        let outcome = try #require(report.outcome)
        #expect(outcome.steps.isEmpty)
        #expect(outcome.hasInstructions == false)
        #expect(outcome.droppedSteps.count == 3)
    }

    @Test func case2InventedTimeIsRemovedButRealStepsKept() async throws {
        let extractor = MockExtractor(
            recipe: RawRecipe(title: "Garlic butter salmon", servings: 2, ingredients: [
                RawIngredient(name: "salmon fillet", quantity: 12, unit: "oz"),
                RawIngredient(name: "olive oil", quantity: 1, unit: "tbsp")
            ]),
            method: RawMethod(hasInstructions: true, steps: [
                RawStep(sourceQuote: "Season two salmon fillets, about six ounces each, with salt and pepper",
                        text: "Season the salmon fillets with salt and pepper.", ingredientsUsed: ["salmon", "salt"]),
                RawStep(sourceQuote: "Sear them skin side down in a tablespoon of olive oil",
                        text: "Sear the salmon skin-side down for 3–4 minutes.", ingredientsUsed: ["olive oil", "salmon"], minutes: 4),
                RawStep(sourceQuote: "Baste for a minute", text: "Baste for about 1 minute.", minutes: 1)
            ])
        )
        let report = await runCase(1, extractor: extractor)
        let outcome = try #require(report.outcome)
        #expect(outcome.steps.count == 3)
        #expect(outcome.steps[1].minutes == nil)          // "3–4 minutes" was never said
        #expect(outcome.steps[1].confidence == .low)      // and the step text has unsupported numbers
        #expect(outcome.steps[2].minutes == 1)
        #expect(outcome.steps[2].confidence == .high)      // "about 1 minute" is backed by "a minute"
        #expect(outcome.steps[0].ingredientNames == ["salmon fillet"])
        #expect(outcome.steps[1].ingredientNames == ["olive oil", "salmon fillet"])
    }

    @Test func noMethodFlagMeansNoSteps() async throws {
        let extractor = MockExtractor(
            recipe: RawRecipe(title: "", servings: 0, ingredients: [RawIngredient(name: "oats", quantity: 80, unit: "g")]),
            method: RawMethod(hasInstructions: false, steps: [])
        )
        let outcome = try #require(await runCase(0, extractor: extractor).outcome)
        #expect(outcome.steps.isEmpty)
        #expect(!outcome.hasInstructions)
        #expect(outcome.ingredients.count == 1)
    }

    @Test func failuresAreRecordedNotThrown() async {
        let report = await runCase(0, extractor: FailingExtractor())
        #expect(report.errors.contains { $0.hasPrefix("Ingredients:") })
        #expect(report.errors.contains { $0.hasPrefix("Steps:") })
        #expect(report.outcome?.ingredients.isEmpty == true)
    }

    @Test func aiUnavailableSkipsExtraction() async {
        let report = await runCase(0, extractor: nil as (any RecipeExtracting)?)
        #expect(report.outcome == nil)
        #expect(report.errors.contains { $0.contains("AI extraction skipped") })
    }

    @Test func perfectOutputPassesSelfTestCase1() async {
        let extractor = MockExtractor(
            recipe: RawRecipe(title: "High-protein overnight oats", servings: 2, ingredients: [
                RawIngredient(name: "rolled oats", quantity: 80, unit: "g"),
                RawIngredient(name: "milk", quantity: 250, unit: "ml"),
                RawIngredient(name: "Greek yogurt, 2% fat", quantity: 150, unit: "g"),
                RawIngredient(name: "whey protein powder, vanilla", quantity: 30, unit: "g", note: "1 scoop"),
                RawIngredient(name: "chia seeds", quantity: 1, unit: "tbsp"),
                RawIngredient(name: "honey", quantity: 1, unit: "tsp")
            ]),
            method: RawMethod(hasInstructions: true, steps: [
                RawStep(sourceQuote: "oats in the jar, milk, yogurt, protein powder, chia, little bit of honey",
                        text: "Add the oats, milk, yogurt, protein powder, chia seeds and honey to a jar."),
                RawStep(sourceQuote: "stir it", text: "Stir well."),
                RawStep(sourceQuote: "fridge overnight", text: "Refrigerate overnight.")
            ])
        )
        let testCase = ExtractionSelfTest.cases[0]
        let report = await runCase(0, extractor: extractor)
        let checks = ExtractionSelfTest.evaluate(testCase, outcome: report.outcome)
        #expect(checks.allSatisfy(\.passed), "\(checks.filter { !$0.passed }.map(\.message))")
    }

    @Test func choiceParsing() {
        #expect(FoundationModelsExtractor.parseChoice("3. Oil, olive, salad or cooking", count: 5) == 2)
        #expect(FoundationModelsExtractor.parseChoice("none", count: 5) == nil)
        #expect(FoundationModelsExtractor.parseChoice("9. Out of range", count: 5) == nil)
    }
}
