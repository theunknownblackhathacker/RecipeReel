import Foundation
import SQLite3
import Testing
@testable import RecipeCore

// MARK: - Fixtures

/// A tiny database with the same schema fdc.yml builds (values as in USDA SR Legacy).
enum FixtureDatabase {
    static func make() throws -> FDCDatabase {
        let url = FileManager.default.temporaryDirectory.appending(path: "fdc-fixture-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK, let db else {
            throw FDCDatabaseError.openFailed("fixture")
        }
        let sql = """
        CREATE TABLE food (fdc_id INTEGER PRIMARY KEY, description TEXT NOT NULL, data_type TEXT NOT NULL, category TEXT);
        CREATE TABLE macro (fdc_id INTEGER PRIMARY KEY, kcal REAL, kcal_source TEXT, protein REAL, fat REAL, carbs REAL, fiber REAL, sugar REAL);
        CREATE TABLE portion (fdc_id INTEGER NOT NULL, amount REAL NOT NULL, unit_text TEXT NOT NULL, grams REAL NOT NULL);
        CREATE VIRTUAL TABLE food_fts USING fts5(description, fdc_id UNINDEXED, tokenize = 'porter unicode61');
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO food VALUES (171413, 'Oil, olive, salad or cooking', 'sr_legacy_food', 'Fats and Oils');
        INSERT INTO food VALUES (171287, 'Egg, whole, raw, fresh', 'sr_legacy_food', 'Dairy and Egg Products');
        INSERT INTO food VALUES (171288, 'Egg, whole, cooked, fried', 'sr_legacy_food', 'Dairy and Egg Products');
        INSERT INTO food VALUES (173410, 'Butter, salted', 'sr_legacy_food', 'Dairy and Egg Products');
        INSERT INTO food VALUES (999001, 'Oil, sesame, salad or cooking', 'sr_legacy_food', 'Fats and Oils');
        INSERT INTO macro VALUES (171413, 884, '1008', 0, 100, 0, 0, 0);
        INSERT INTO macro VALUES (171287, 143, '1008', 12.56, 9.51, 0.72, 0, 0.37);
        INSERT INTO macro VALUES (171288, 196, '1008', 13.61, 14.84, 0.83, 0, 0.4);
        INSERT INTO macro VALUES (173410, 717, '1008', 0.85, 81.11, 0.06, 0, 0.06);
        INSERT INTO macro VALUES (999001, 884, '1008', 0, 100, 0, 0, 0);
        INSERT INTO portion VALUES (171413, 1, 'tbsp', 13.5);
        INSERT INTO portion VALUES (171413, 1, 'cup', 216);
        INSERT INTO portion VALUES (171287, 1, 'large', 50);
        INSERT INTO portion VALUES (171287, 1, 'extra large', 56);
        INSERT INTO portion VALUES (171287, 1, 'medium', 44);
        INSERT INTO portion VALUES (173410, 1, 'tbsp', 14.2);
        INSERT INTO portion VALUES (173410, 1, 'cup', 227);
        INSERT INTO food_fts (description, fdc_id) SELECT description, fdc_id FROM food;
        INSERT INTO meta VALUES ('source', 'fixture');
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw FDCDatabaseError.openFailed(message)
        }
        sqlite3_close(db)
        return try FDCDatabase(url: url)
    }
}

// MARK: - Unit conversion

@Suite("UnitConverter")
struct UnitConverterTests {
    let oliveOil = [FoodPortion(amount: 1, unitText: "tbsp", grams: 13.5), FoodPortion(amount: 1, unitText: "cup", grams: 216)]
    let egg = [FoodPortion(amount: 1, unitText: "extra large", grams: 56), FoodPortion(amount: 1, unitText: "large", grams: 50),
               FoodPortion(amount: 1, unitText: "medium", grams: 44)]

    @Test func massUnitsAreExact() {
        #expect(UnitConverter.grams(quantity: 2, unit: .kg, portions: []).grams == 2000)
        let oz = UnitConverter.grams(quantity: 12, unit: .oz, portions: [])
        #expect(abs((oz.grams ?? 0) - 340.194) < 0.01)
        #expect(oz.method == .exact)
        #expect(abs((UnitConverter.grams(quantity: 1, unit: .lb, portions: []).grams ?? 0) - 453.592) < 0.001)
    }

    @Test func matchingPortionIsUsed() {
        let tbsp = UnitConverter.grams(quantity: 2, unit: .tbsp, portions: oliveOil)
        #expect(tbsp.grams == 27)
        #expect(tbsp.method == .portion)
    }

    @Test func piecesPreferMediumThenLarge() {
        let eggs = UnitConverter.grams(quantity: 2, unit: .piece, portions: egg)
        #expect(eggs.grams == 88)
        let onlyLarge = UnitConverter.grams(quantity: 2, unit: .piece, portions: Array(egg.prefix(2)))
        #expect(onlyLarge.grams == 100)    // "extra large" must not be mistaken for "large"
    }

    @Test func volumeUsesDensityWhenNoMatchingPortion() {
        // tsp of olive oil: density from the cup measure (216 g / 236.588 ml).
        let tsp = UnitConverter.grams(quantity: 1, unit: .tsp, portions: oliveOil)
        #expect(tsp.method == .density)
        #expect(abs((tsp.grams ?? 0) - 4.92892 * 216 / 236.588) < 0.001)
        let ml = UnitConverter.grams(quantity: 100, unit: .ml, portions: oliveOil)
        #expect(abs((ml.grams ?? 0) - 91.298) < 0.01)
    }

    @Test func volumeWithoutAnyDataIsAssumedWater() {
        let result = UnitConverter.grams(quantity: 250, unit: .ml, portions: [])
        #expect(result.grams == 250)
        #expect(result.method == .assumed)
    }

    @Test func uncountableLines() {
        #expect(UnitConverter.grams(quantity: nil, unit: .g, portions: []).method == .notCounted)
        #expect(UnitConverter.grams(quantity: 1, unit: .toTaste, portions: []).method == .notCounted)
        #expect(UnitConverter.grams(quantity: 3, unit: .clove, portions: []).method == .notCounted)
    }

    @Test func portionTextClassification() {
        #expect(UnitConverter.classify("cup, chopped")?.unit == .cup)
        #expect(UnitConverter.classify("1 tbsp")?.unit == .tbsp)
        #expect(UnitConverter.classify("fl oz")?.millilitres == 29.5735)
        #expect(UnitConverter.classify("large")?.kind == .piece)
        #expect(UnitConverter.classify("clove")?.unit == .clove)
        #expect(UnitConverter.classify("NLEA serving") == nil)
    }
}

// MARK: - Macro math

@Suite("NutritionCalculator")
struct NutritionCalculatorTests {
    let olive = FoodRecord(fdcID: 171413, description: "Oil, olive, salad or cooking",
                           nutrients: FoodNutrients(kcal: 884, protein: 0, fat: 100, carbs: 0),
                           portions: [FoodPortion(amount: 1, unitText: "tbsp", grams: 13.5)])
    let egg = FoodRecord(fdcID: 171287, description: "Egg, whole, raw, fresh",
                         nutrients: FoodNutrients(kcal: 143, protein: 12.56, fat: 9.51, carbs: 0.72),
                         portions: [FoodPortion(amount: 1, unitText: "large", grams: 50)])

    @Test func perIngredientMacros() throws {
        let line = NutritionCalculator.evaluate(quantity: 1, unit: .tbsp, food: olive)
        let macros = try #require(line.macros)
        #expect(abs(macros.kcal - 119.34) < 0.001)
        #expect(abs(macros.fat - 13.5) < 0.001)
    }

    @Test func recipeTotalsAndPerServing() {
        let lines = [
            NutritionCalculator.evaluate(quantity: 1, unit: .tbsp, food: olive),
            NutritionCalculator.evaluate(quantity: 2, unit: .piece, food: egg),
            NutritionCalculator.evaluate(quantity: nil, unit: .toTaste, food: nil)
        ]
        let summary = NutritionCalculator.summarize(lines, servings: 2)
        #expect(abs(summary.total.kcal - (119.34 + 143)) < 0.001)
        #expect(abs(summary.total.protein - 12.56) < 0.001)
        #expect(abs(summary.perServing.kcal - (119.34 + 143) / 2) < 0.001)
        #expect(summary.countedLines == 2)
        #expect(summary.notCountedLines == 1)
    }

    @Test func missingEnergyIsEstimatedFromMacros() {
        let food = FoodRecord(fdcID: 1, description: "x", nutrients: FoodNutrients(kcal: nil, kcalSource: "missing", protein: 10, fat: 10, carbs: 10))
        let macros = NutritionCalculator.macros(grams: 100, nutrients: food.nutrients)
        #expect(macros.kcal == 170)
    }

    @Test func servingsBelowOneAreTreatedAsOne() {
        let summary = NutritionCalculator.summarize([NutritionCalculator.evaluate(quantity: 100, unit: .g, food: egg)], servings: 0)
        #expect(summary.servings == 1)
        #expect(summary.perServing == summary.total)
    }
}

// MARK: - Database + search

@Suite("FDCDatabase")
struct FDCDatabaseTests {

    @Test func searchTermsUseSynonymsAndDropPrepWords() {
        #expect(FoodSearch.terms(for: "Extra virgin olive oil") == ["oil", "olive"])
        #expect(FoodSearch.terms(for: "2 large eggs, beaten") == ["egg", "whole", "raw", "beaten"])
        #expect(FoodSearch.terms(for: "finely chopped scallions") == ["onions", "spring"])
        #expect(FoodSearch.ftsQuery(terms: ["oil", "olive"], all: true) == "\"oil\"* AND \"olive\"*")
    }

    @Test func searchFindsAndRanksFixtureFoods() throws {
        let db = try FixtureDatabase.make()
        let oil = db.search(ingredientName: "olive oil")
        #expect(oil.first?.fdcID == 171413)
        let eggs = db.search(ingredientName: "eggs")
        #expect(eggs.first?.fdcID == 171287)          // raw preferred over fried
        let fried = db.search(ingredientName: "fried egg")
        #expect(fried.first?.fdcID == 171288)
        #expect(db.search(ingredientName: "dragonfruit").isEmpty)
    }

    @Test func foodRecordIncludesNutrientsAndPortions() throws {
        let db = try FixtureDatabase.make()
        let egg = try #require(db.food(id: 171287))
        #expect(egg.nutrients.kcal == 143)
        #expect(egg.nutrients.protein == 12.56)
        #expect(egg.portions.count == 3)
        #expect(db.food(id: 42) == nil)
        #expect(db.metadata()["food_count"] == "5")
    }

    @Test func matchingInsidePipelineUsesDatabaseCandidates() async throws {
        let db = try FixtureDatabase.make()
        let extractor = MockExtractor(
            recipe: RawRecipe(title: "", servings: 0, ingredients: [
                RawIngredient(name: "olive oil", quantity: 1, unit: "tbsp"),
                RawIngredient(name: "eggs", quantity: 2, unit: "piece"),
                RawIngredient(name: "dragonfruit", quantity: 1, unit: "piece")
            ]),
            method: RawMethod(hasInstructions: false, steps: [])
        )
        let matcher = MockMatcher(keywords: ["olive oil": "olive", "eggs": "raw"])
        let timeline = SourceTimeline(caption: "olive oil, eggs, dragonfruit", spoken: [], onScreen: [])
        let pipeline = PipelineCoordinator(transcriber: NoMedia(), ocr: NoMedia(), extractor: extractor, matcher: matcher,
                                           database: db, aiStatus: "mock")
        let report = await pipeline.extract(into: AnalysisReport(itemID: nil, aiStatus: "mock", timeline: timeline),
                                            rememberedMatches: ["eggs": 171288], update: { _ in })
        let ingredients = try #require(report.outcome?.ingredients)
        #expect(ingredients[0].fdcID == 171413)
        #expect(ingredients[0].matchStatus == .matched)
        #expect(ingredients[1].fdcID == 171288)        // the user's remembered choice wins
        #expect(ingredients[1].matchStatus == .remembered)
        #expect(ingredients[2].fdcID == nil)
        #expect(ingredients[2].matchStatus == .unmatched)
    }
}

// MARK: - Real USDA database (runs once fdc.yml has committed App/Resources/fdc.sqlite)

enum RealDatabase {
    static let url: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()   // RecipeCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // RecipeCore
        .deletingLastPathComponent()   // Packages
        .deletingLastPathComponent()   // repo root
        .appending(path: "App/Resources/fdc.sqlite")

    static var exists: Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
}

@Suite("USDA values", .enabled(if: RealDatabase.exists, "fdc.sqlite not built yet"))
struct USDAValueTests {

    @Test func oliveOil() throws {
        let db = try FDCDatabase(url: RealDatabase.url)
        let food = try #require(db.food(description: "Oil, olive, salad or cooking"))
        #expect(food.nutrients.kcal == 884)
        #expect(food.nutrients.fat == 100)
        let tbsp = UnitConverter.grams(quantity: 1, unit: .tbsp, portions: food.portions)
        #expect(tbsp.grams == 13.5)
    }

    @Test func wholeRawEgg() throws {
        let db = try FDCDatabase(url: RealDatabase.url)
        let food = try #require(db.food(description: "Egg, whole, raw, fresh"))
        #expect(food.nutrients.kcal == 143)
        #expect(food.nutrients.protein == 12.56)
        #expect(food.nutrients.fat == 9.51)
        #expect(food.nutrients.carbs == 0.72)
        let large = UnitConverter.grams(quantity: 1, unit: .piece, portions: food.portions.filter { $0.unitText.contains("large") && !$0.unitText.contains("extra") })
        #expect(large.grams == 50)
    }

    @Test func searchReturnsSensibleFirstHits() throws {
        let db = try FDCDatabase(url: RealDatabase.url)
        let hits = db.search(ingredientName: "olive oil").map(\.description)
        #expect(hits.contains("Oil, olive, salad or cooking"), "\(hits)")
        #expect(!db.search(ingredientName: "rolled oats").isEmpty)
        #expect(!db.search(ingredientName: "chicken breast").isEmpty)
    }
}
