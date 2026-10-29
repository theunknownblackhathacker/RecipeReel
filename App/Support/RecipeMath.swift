import Foundation
import RecipeCore

/// Formatting and parsing helpers for amounts and macros.
enum RecipeMath {

    /// "80", "0.5", "1.25" — no trailing zeros.
    static func quantityText(_ value: Double?) -> String {
        guard let value else { return "" }
        if value == value.rounded() { return String(Int(value)) }
        let fractions: [(Double, String)] = [(0.25, "¼"), (0.5, "½"), (0.75, "¾"), (1.0 / 3, "⅓"), (2.0 / 3, "⅔")]
        let whole = value.rounded(.down)
        if let match = fractions.first(where: { abs(value - whole - $0.0) < 0.01 }) {
            return whole == 0 ? match.1 : "\(Int(whole))\(match.1)"
        }
        return String(format: "%g", (value * 100).rounded() / 100)
    }

    /// Parses "1.5", "1,5", "1/2", "1 1/2", "½". Empty → nil.
    static func parseQuantity(_ text: String) -> Double? {
        let unicode: [Character: Double] = ["¼": 0.25, "½": 0.5, "¾": 0.75, "⅓": 1.0 / 3, "⅔": 2.0 / 3]
        var trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }
        var extra = 0.0
        if let last = trimmed.last, let value = unicode[last] {
            extra = value
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return extra }
        }
        let parts = trimmed.split(separator: " ")
        var total = extra
        for part in parts {
            if part.contains("/") {
                let pieces = part.split(separator: "/")
                guard pieces.count == 2, let a = Double(pieces[0]), let b = Double(pieces[1]), b != 0 else { return nil }
                total += a / b
            } else {
                guard let value = Double(part) else { return nil }
                total += value
            }
        }
        return total > 0 ? total : nil
    }

    static func amountText(quantity: Double?, unit: CanonicalUnit) -> String {
        if unit == .toTaste { return "to taste" }
        let q = quantityText(quantity)
        if q.isEmpty { return "?" }
        switch unit {
        case .g, .kg, .ml, .l: return "\(q) \(unit.rawValue)"
        case .piece: return q
        default: return "\(q) \(unit.label)"
        }
    }

    static func kcal(_ value: Double) -> String { String(format: "%.0f", value) }
    static func grams(_ value: Double) -> String { String(format: "%.1f g", value) }
}
