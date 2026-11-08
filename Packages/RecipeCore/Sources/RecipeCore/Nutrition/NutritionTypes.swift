import Foundation

/// Nutrients per 100 g of a food. Carbohydrate is *available* carbohydrate (fibre not included), as on EU
/// labels and in Ciqual/CoFID; USDA values are converted when the database is built. Nil = not reported.
public struct FoodNutrients: Codable, Sendable, Equatable {
    public var kcal: Double?
    /// "ciqual", "cofid", USDA "1008", "2048", "2047", "estimated" (from macros) or "missing".
    public var kcalSource: String
    public var protein: Double?
    public var fat: Double?
    public var carbs: Double?
    public var fiber: Double?
    public var sugar: Double?

    public init(kcal: Double?, kcalSource: String = "1008", protein: Double?, fat: Double?, carbs: Double?,
                fiber: Double? = nil, sugar: Double? = nil) {
        self.kcal = kcal
        self.kcalSource = kcalSource
        self.protein = protein
        self.fat = fat
        self.carbs = carbs
        self.fiber = fiber
        self.sugar = sugar
    }
}

/// Names of the food tables for the app, and their credits (both European licences require attribution).
public enum FoodSources {
    public static func name(forDataType dataType: String?) -> String {
        switch dataType {
        case "ciqual": "Ciqual (France)"
        case "cofid": "CoFID (UK)"
        case "openFoodFacts": "Open Food Facts"
        case "label", "manual", "custom": "My foods"
        default: "USDA"
        }
    }

    public static func isEuropean(_ dataType: String?) -> Bool { dataType == "ciqual" || dataType == "cofid" }

    public static let credits: [String] = [
        "Ciqual 2025 — French food composition table, © ANSES. Licence Ouverte / Open Licence 2.0 (Etalab). doi:10.57745/RDMHWY",
        "McCance and Widdowson's Composition of Foods Integrated Dataset 2021 (CoFID, UK). Contains public sector information licensed under the Open Government Licence v3.0.",
        "USDA FoodData Central (Foundation Foods, SR Legacy, FNDDS) — public domain (CC0).",
        "Open Food Facts (online lookups and barcodes) — Open Database License (ODbL)."
    ]
}

/// A household measure for a food, e.g. "1 cup, chopped" = 160 g.
public struct FoodPortion: Codable, Sendable, Equatable {
    public var amount: Double
    public var unitText: String
    public var grams: Double

    public init(amount: Double, unitText: String, grams: Double) {
        self.amount = amount
        self.unitText = unitText
        self.grams = grams
    }

    public var gramsPerUnit: Double { grams / max(amount, 0.0001) }
}

public struct FoodRecord: Codable, Sendable, Equatable, Identifiable {
    public var fdcID: Int
    public var description: String
    public var dataType: String
    public var category: String
    public var nutrients: FoodNutrients
    public var portions: [FoodPortion]

    public var id: Int { fdcID }

    public init(fdcID: Int, description: String, dataType: String = "sr_legacy_food", category: String = "",
                nutrients: FoodNutrients, portions: [FoodPortion] = []) {
        self.fdcID = fdcID
        self.description = description
        self.dataType = dataType
        self.category = category
        self.nutrients = nutrients
        self.portions = portions
    }
}

/// Calories and macros (grams) for some amount of food.
public struct Macros: Codable, Sendable, Equatable {
    public var kcal: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double
    public var fiber: Double
    public var sugar: Double

    public init(kcal: Double = 0, protein: Double = 0, carbs: Double = 0, fat: Double = 0, fiber: Double = 0, sugar: Double = 0) {
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.sugar = sugar
    }

    public static let zero = Macros()

    public static func + (lhs: Macros, rhs: Macros) -> Macros {
        Macros(kcal: lhs.kcal + rhs.kcal, protein: lhs.protein + rhs.protein, carbs: lhs.carbs + rhs.carbs,
               fat: lhs.fat + rhs.fat, fiber: lhs.fiber + rhs.fiber, sugar: lhs.sugar + rhs.sugar)
    }

    public func scaled(by factor: Double) -> Macros {
        Macros(kcal: kcal * factor, protein: protein * factor, carbs: carbs * factor,
               fat: fat * factor, fiber: fiber * factor, sugar: sugar * factor)
    }
}
