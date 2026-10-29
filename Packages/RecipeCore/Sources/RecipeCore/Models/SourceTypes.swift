import Foundation

/// One stretch of speech from the video's audio, in seconds from the start.
public struct TranscriptSegment: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// One line of on-screen text, first seen at `time` seconds.
public struct OCRLine: Codable, Sendable, Equatable {
    public var time: Double
    public var text: String
    public var confidence: Double

    public init(time: Double, text: String, confidence: Double) {
        self.time = time
        self.text = text
        self.confidence = confidence
    }
}

/// The text recognized in one sampled frame (before de-duplication).
public struct OCRFrame: Sendable, Equatable {
    public var time: Double
    public var lines: [Line]

    public struct Line: Sendable, Equatable {
        public var text: String
        public var confidence: Double

        public init(text: String, confidence: Double) {
            self.text = text
            self.confidence = confidence
        }
    }

    public init(time: Double, lines: [Line]) {
        self.time = time
        self.lines = lines
    }
}

/// Canonical units used everywhere in the app (see recipe-test-cases.md).
public enum CanonicalUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case g, kg, ml, l, tsp, tbsp, cup, oz, lb, piece, clove, slice, pinch
    case toTaste = "to_taste"

    public var id: String { rawValue }

    /// Short label for display ("g", "tbsp", "to taste").
    public var label: String {
        switch self {
        case .toTaste: "to taste"
        case .piece: "pc"
        default: rawValue
        }
    }

    public var isMass: Bool { [.g, .kg, .oz, .lb].contains(self) }
    public var isVolume: Bool { [.ml, .l, .tsp, .tbsp, .cup, .pinch].contains(self) }

    /// Parses free text ("tablespoons", "Tbsp.", "grams", "cloves") into a unit.
    public static func parse(_ text: String) -> CanonicalUnit? {
        let t = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch t {
        case "g", "gr", "gram", "grams", "gramme", "grammes": return .g
        case "kg", "kgs", "kilo", "kilos", "kilogram", "kilograms": return .kg
        case "ml", "milliliter", "milliliters", "millilitre", "millilitres": return .ml
        case "l", "liter", "liters", "litre", "litres": return .l
        case "tsp", "tsps", "teaspoon", "teaspoons", "t": return .tsp
        case "tbsp", "tbsps", "tbs", "tablespoon", "tablespoons", "tbl": return .tbsp
        case "cup", "cups", "c": return .cup
        case "oz", "ounce", "ounces": return .oz
        case "lb", "lbs", "pound", "pounds": return .lb
        case "piece", "pieces", "pc", "pcs", "whole", "each", "item", "items", "unit", "units",
             "fillet", "fillets", "egg", "eggs", "scoop", "scoops", "can", "cans": return .piece
        case "clove", "cloves": return .clove
        case "slice", "slices": return .slice
        case "pinch", "pinches", "dash", "dashes": return .pinch
        case "to_taste", "to taste", "totaste", "as needed": return .toTaste
        default: return nil
        }
    }
}

/// How sure the extraction is about a value.
public enum Confidence: String, Codable, Sendable, CaseIterable, Comparable {
    case low, medium, high

    public static func parse(_ text: String) -> Confidence {
        Confidence(rawValue: text.lowercased().trimmingCharacters(in: .whitespaces)) ?? .medium
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }
}
