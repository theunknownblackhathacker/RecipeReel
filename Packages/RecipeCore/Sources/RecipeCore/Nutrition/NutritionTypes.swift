import Foundation

/// Nutrients per 100 g of a food, from USDA FoodData Central. Nil = not reported.
public struct FoodNutrients: Codable, Sendable, Equatable {
    public var kcal: Double?
    /// "1008", "2048", "2047", "estimated" (4/9/4 from macros) or "missing".
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
