import Foundation

/// How an ingredient amount was turned into grams (shown on the review screen).
public enum ConversionMethod: String, Codable, Sendable {
    /// Mass unit, converted exactly.
    case exact
    /// Used a household measure of the matched food (e.g. 1 large egg = 50 g).
    case portion
    /// Volume × the food's density from its cup/tbsp/tsp measures.
    case density
    /// Volume with no density data: assumed 1 g/ml.
    case assumed
    /// Not counted: no amount, "to taste", or no way to convert.
    case notCounted
}

public struct GramConversion: Sendable, Equatable {
    public var grams: Double?
    public var method: ConversionMethod
    public var detail: String

    public init(grams: Double?, method: ConversionMethod, detail: String) {
        self.grams = grams
        self.method = method
        self.detail = detail
    }

    public var isWeak: Bool { method == .assumed || method == .notCounted }
}

/// Deterministic unit → gram conversion using FoodData Central portion data. The model never does this.
public enum UnitConverter {

    public static let gramsPerOunce = 28.3495
    public static let gramsPerPound = 453.592

    /// US measures in ml.
    public static func millilitres(per unit: CanonicalUnit) -> Double? {
        switch unit {
        case .ml: 1
        case .l: 1000
        case .tsp: 4.92892
        case .tbsp: 14.7868
        case .cup: 236.588
        case .pinch: 0.31
        default: nil
        }
    }

    public static func grams(quantity: Double?, unit: CanonicalUnit, portions: [FoodPortion]) -> GramConversion {
        guard unit != .toTaste else { return GramConversion(grams: nil, method: .notCounted, detail: "to taste") }
        guard let quantity, quantity > 0 else {
            return GramConversion(grams: nil, method: .notCounted, detail: "no amount")
        }

        // 1. Mass units: exact.
        switch unit {
        case .g: return GramConversion(grams: quantity, method: .exact, detail: "")
        case .kg: return GramConversion(grams: quantity * 1000, method: .exact, detail: "")
        case .oz: return GramConversion(grams: quantity * gramsPerOunce, method: .exact, detail: "1 oz = 28.35 g")
        case .lb: return GramConversion(grams: quantity * gramsPerPound, method: .exact, detail: "1 lb = 453.6 g")
        default: break
        }

        // 2. A household measure of this food in the same unit.
        if let portion = bestPortion(for: unit, in: portions) {
            return GramConversion(
                grams: quantity * portion.gramsPerUnit,
                method: .portion,
                detail: "1 \(unit.label) = \(format(portion.gramsPerUnit)) g (\(portion.unitText))"
            )
        }

        // 3. Volume via the food's density.
        if let ml = millilitres(per: unit) {
            let volume = quantity * ml
            if let density = density(from: portions) {
                return GramConversion(grams: volume * density, method: .density,
                                      detail: "\(format(density)) g/ml from food measures")
            }
            return GramConversion(grams: volume, method: .assumed, detail: "assumed 1 g/ml")
        }

        // Pieces, cloves, slices without a matching measure.
        return GramConversion(grams: nil, method: .notCounted, detail: "no \(unit.label) weight for this food")
    }

    /// The measure that matches `unit`, if any.
    static func bestPortion(for unit: CanonicalUnit, in portions: [FoodPortion]) -> FoodPortion? {
        let classified = portions.map { ($0, classify($0.unitText)) }
        switch unit {
        case .piece:
            let pieces = classified.filter { $0.1?.kind == .piece }
            for size in ["medium", "large", "whole", "regular", ""] {
                if let match = pieces.first(where: { $0.1?.size == size }) { return match.0 }
            }
            return pieces.first?.0
        case .cup, .tbsp, .tsp, .clove, .slice:
            return classified.first { $0.1?.unit == unit }?.0
        default:
            return nil
        }
    }

    /// Grams per ml from the food's volume measures (cup preferred).
    static func density(from portions: [FoodPortion]) -> Double? {
        let classified = portions.compactMap { portion -> (FoodPortion, Double)? in
            guard let info = classify(portion.unitText), info.kind == .volume else { return nil }
            let ml = info.unit.flatMap(millilitres(per:)) ?? info.millilitres
            guard let ml, ml > 0 else { return nil }
            return (portion, ml)
        }
        let order: [CanonicalUnit] = [.cup, .tbsp, .tsp]
        for unit in order {
            if let match = classified.first(where: { classify($0.0.unitText)?.unit == unit }) {
                return match.0.gramsPerUnit / match.1
            }
        }
        if let any = classified.first { return any.0.gramsPerUnit / any.1 }
        return nil
    }

    struct PortionInfo: Equatable {
        enum Kind: Equatable { case volume, piece, other }
        var kind: Kind
        var unit: CanonicalUnit?
        /// For volume measures without a canonical unit (e.g. "fl oz").
        var millilitres: Double?
        /// For pieces: "large", "medium", "small", "whole", "regular" or "".
        var size: String
    }

    static let pieceWords: Set<String> = [
        "piece", "pieces", "whole", "each", "item", "fruit", "egg", "fillet", "breast", "leg", "thigh",
        "wing", "drumstick", "stalk", "spear", "sprig", "leaf", "head", "bulb", "ear", "link", "patty",
        "pepper", "onion", "potato", "tomato", "banana", "apple", "lemon", "lime", "orange", "carrot",
        "avocado", "steak", "chop", "tortilla", "bagel", "muffin", "roll", "bun", "cookie", "bar", "scoop"
    ]

    /// Reads FDC portion text ("cup, chopped", "large", "1 tbsp", "fl oz") into a unit kind.
    static func classify(_ text: String) -> PortionInfo? {
        let tokens = TextMatching.tokens(text)
        guard !tokens.isEmpty else { return nil }
        let joined = " " + tokens.joined(separator: " ") + " "
        if joined.contains(" fl oz ") {
            return PortionInfo(kind: .volume, unit: nil, millilitres: 29.5735, size: "")
        }
        for token in tokens {
            if let unit = CanonicalUnit.parse(token) {
                switch unit {
                case .cup, .tbsp, .tsp: return PortionInfo(kind: .volume, unit: unit, millilitres: nil, size: "")
                case .ml: return PortionInfo(kind: .volume, unit: .ml, millilitres: nil, size: "")
                case .clove, .slice: return PortionInfo(kind: .other, unit: unit, millilitres: nil, size: "")
                default: break
                }
            }
        }
        for size in ["extra large", "jumbo", "medium", "large", "small"] where joined.contains(" \(size) ") {
            return PortionInfo(kind: .piece, unit: .piece, millilitres: nil, size: size == "extra large" || size == "jumbo" ? "xl" : size)
        }
        if tokens.contains(where: pieceWords.contains) {
            let size = tokens.contains("whole") ? "whole" : ""
            return PortionInfo(kind: .piece, unit: .piece, millilitres: nil, size: size)
        }
        return nil
    }

    static func format(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}
