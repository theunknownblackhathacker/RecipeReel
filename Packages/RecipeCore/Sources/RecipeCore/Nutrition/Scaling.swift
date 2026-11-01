import Foundation

/// Scaling a recipe from the servings it makes (its yield) to the servings you're cooking.
/// Stored amounts always stay at the original yield; only what's shown and calculated is scaled.
public enum Scaling {

    public static func factor(cookingFor: Int, yield: Int) -> Double {
        Double(max(1, cookingFor)) / Double(max(1, yield))
    }

    /// The amount to show/calculate for a stored amount. "To taste" and missing amounts stay as they are.
    public static func scaled(_ quantity: Double?, unit: CanonicalUnit, factor: Double) -> Double? {
        guard let quantity, unit != .toTaste else { return quantity }
        return rounded(quantity * factor, unit: unit)
    }

    /// Back from a shown (scaled) amount to the stored amount, e.g. when editing while scaled.
    public static func unscaled(_ quantity: Double?, factor: Double) -> Double? {
        guard let quantity, factor > 0 else { return quantity }
        return quantity / factor
    }

    /// Sensible precision for cooking: whole grams/ml above 10, quarters for spoons, cups and pieces.
    public static func rounded(_ value: Double, unit: CanonicalUnit) -> Double {
        switch unit {
        case .g, .ml:
            return value >= 10 ? value.rounded() : (value * 10).rounded() / 10
        case .kg, .l:
            return (value * 100).rounded() / 100
        case .tsp, .tbsp, .cup, .piece, .clove, .slice, .oz, .lb, .pinch:
            let quarter = (value * 4).rounded() / 4
            return quarter == 0 ? (value * 100).rounded() / 100 : quarter
        case .toTaste:
            return value
        }
    }
}
