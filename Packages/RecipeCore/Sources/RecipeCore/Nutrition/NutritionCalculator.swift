import Foundation

/// Nutrition for one ingredient line.
public struct IngredientNutrition: Sendable, Equatable {
    public var conversion: GramConversion
    /// Nil when the line isn't counted (no grams or no matched food).
    public var macros: Macros?
    /// Nutrients the matched food doesn't report (counted as 0), e.g. ["carbs"].
    public var missingNutrients: [String]
    public var hasFood: Bool

    public var isCounted: Bool { macros != nil }
}

/// Totals for a recipe.
public struct RecipeNutrition: Sendable, Equatable {
    public var total: Macros
    public var perServing: Macros
    public var servings: Int
    public var countedLines: Int
    public var notCountedLines: Int
    /// Lines counted with an assumed density or with missing nutrients.
    public var approximateLines: Int
}

/// All macro math. Pure Swift; the model never produces numbers.
public enum NutritionCalculator {

    /// Macros for `grams` of a food (values are per 100 g).
    public static func macros(grams: Double, nutrients n: FoodNutrients) -> Macros {
        let factor = grams / 100
        let protein = n.protein ?? 0
        let fat = n.fat ?? 0
        let carbs = n.carbs ?? 0
        let kcalPer100 = n.kcal ?? (4 * protein + 9 * fat + 4 * carbs)
        return Macros(
            kcal: kcalPer100 * factor,
            protein: protein * factor,
            carbs: carbs * factor,
            fat: fat * factor,
            fiber: (n.fiber ?? 0) * factor,
            sugar: (n.sugar ?? 0) * factor
        )
    }

    public static func evaluate(quantity: Double?, unit: CanonicalUnit, food: FoodRecord?) -> IngredientNutrition {
        let conversion = UnitConverter.grams(quantity: quantity, unit: unit, portions: food?.portions ?? [])
        guard let food, let grams = conversion.grams else {
            return IngredientNutrition(conversion: conversion, macros: nil, missingNutrients: [], hasFood: food != nil)
        }
        var missing: [String] = []
        if food.nutrients.kcal == nil { missing.append("kcal") }
        if food.nutrients.protein == nil { missing.append("protein") }
        if food.nutrients.carbs == nil { missing.append("carbs") }
        if food.nutrients.fat == nil { missing.append("fat") }
        return IngredientNutrition(
            conversion: conversion,
            macros: macros(grams: grams, nutrients: food.nutrients),
            missingNutrients: missing,
            hasFood: true
        )
    }

    public static func summarize(_ lines: [IngredientNutrition], servings: Int) -> RecipeNutrition {
        let counted = lines.compactMap(\.macros)
        let total = counted.reduce(Macros.zero, +)
        let safeServings = max(1, servings)
        let approximate = lines.filter { $0.isCounted && ($0.conversion.method == .assumed || !$0.missingNutrients.isEmpty) }.count
        return RecipeNutrition(
            total: total,
            perServing: total.scaled(by: 1 / Double(safeServings)),
            servings: safeServings,
            countedLines: counted.count,
            notCountedLines: lines.count - counted.count,
            approximateLines: approximate
        )
    }
}
