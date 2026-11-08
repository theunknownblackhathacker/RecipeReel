import Foundation
import SQLite3
import Testing
@testable import RecipeCore

/// A small database mixing European (Ciqual, CoFID) and USDA foods, with the schema fdc.yml builds.
enum MixedFixtureDatabase {
    static func make() throws -> FDCDatabase {
        let url = FileManager.default.temporaryDirectory.appending(path: "fdc-mixed-\(UUID().uuidString).sqlite")
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
        INSERT INTO food VALUES (173420, 'Cheese, feta', 'sr_legacy_food', '');
        INSERT INTO food VALUES (10012061, 'Feta or Feta-type cheese, 100% from ewe''s milk', 'ciqual', '');
        INSERT INTO food VALUES (170859, 'Cream, fluid, heavy whipping', 'sr_legacy_food', '');
        INSERT INTO food VALUES (20000500, 'Cream, fresh, whipping', 'cofid', '');
        INSERT INTO food VALUES (171477, 'Chicken, broiler or fryers, breast, skinless, boneless, meat only, raw', 'sr_legacy_food', '');
        INSERT INTO food VALUES (10036018, 'Chicken, breast, without skin, raw', 'ciqual', '');
        INSERT INTO food VALUES (10036019, 'Chicken, breast, meat and skin, roasted/baked', 'ciqual', '');
        INSERT INTO food VALUES (171386, 'Chicken, broiler or fryers, thigh, meat only, raw', 'sr_legacy_food', '');
        INSERT INTO food VALUES (20000600, 'Chicken, thighs, casseroled, meat and skin', 'cofid', '');
        INSERT INTO food VALUES (169761, 'Wheat flour, white, all-purpose, enriched, bleached', 'sr_legacy_food', '');
        INSERT INTO food VALUES (20000700, 'Flour, wheat, white, plain, soft', 'cofid', '');
        INSERT INTO food VALUES (10009410, 'Wheat flour, type 110', 'ciqual', '');
        INSERT INTO macro SELECT fdc_id, 100, 'fixture', 1, 1, 1, 0, 0 FROM food;
        INSERT INTO portion VALUES (10012061, 1, 'cup, crumbled', 150);
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

@Suite("European food tables first")
struct EuropeanFoodTests {

    @Test func europeanFoodsComeFirst() throws {
        let db = try MixedFixtureDatabase.make()
        let feta = db.search(ingredientName: "feta", limit: 10)
        #expect(feta.first?.dataType == "ciqual")
        #expect(feta.first?.sourceName == "Ciqual (France)")
        #expect(feta.contains { $0.description == "Cheese, feta" })            // USDA still offered

        #expect(db.search(ingredientName: "heavy cream", limit: 10).first?.description == "Cream, fresh, whipping")
        #expect(db.search(ingredientName: "chicken breast", limit: 10).first?.description == "Chicken, breast, without skin, raw")
        #expect(db.search(ingredientName: "all purpose flour", limit: 10).first?.description == "Flour, wheat, white, plain, soft")
    }

    @Test func cookedEuropeanFoodsDontJumpTheQueue() throws {
        let db = try MixedFixtureDatabase.make()
        // Only a casseroled thigh exists in the European tables: the raw USDA thigh comes first.
        let thighs = db.search(ingredientName: "chicken thighs", limit: 10)
        #expect(thighs.first?.description == "Chicken, broiler or fryers, thigh, meat only, raw")
        // Asking for cooked chicken may still pick it.
        #expect(FoodSearch.isGoodEuropeanMatch("Chicken, thighs, casseroled, meat and skin",
                                               terms: ["chicken", "thigh"], ingredientName: "cooked chicken thighs"))
    }

    @Test func europeanFoodsHaveBorrowedMeasures() throws {
        let db = try MixedFixtureDatabase.make()
        let feta = try #require(db.food(id: 10012061))
        let result = NutritionCalculator.evaluate(quantity: 1, unit: .cup, food: feta)
        #expect(result.conversion.grams == 150)
        #expect(FoodSources.isEuropean(feta.dataType))
    }

    @Test func pickerSearchListsEuropeanFirst() throws {
        let db = try MixedFixtureDatabase.make()
        #expect(db.search(text: "feta", limit: 10).first?.dataType == "ciqual")
    }

    @Test func creditsNameEveryLicence() {
        let text = FoodSources.credits.joined(separator: " ")
        #expect(text.contains("Licence Ouverte"))
        #expect(text.contains("Open Government Licence v3.0"))
        #expect(text.contains("ODbL"))
    }
}
