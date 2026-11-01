import Foundation

/// A food that isn't in the bundled USDA data: entered from a label, scanned, or found on Open Food Facts.
/// Uses negative IDs so it can sit in the same `fdcID` slot as USDA foods.
public struct CustomFood: Codable, Sendable, Equatable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case label          // typed by the user from a nutrition label
        case openFoodFacts  // Open Food Facts (scanned barcode or name search)
    }

    public var id: Int
    public var name: String
    public var brand: String
    public var source: Source
    public var barcode: String?
    /// Per 100 g.
    public var kcal: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double
    public var fiber: Double?
    public var sugar: Double?
    /// Weight of one piece, if known (e.g. one egg, one tortilla).
    public var gramsPerPiece: Double?
    public var createdAt: Date

    public init(id: Int = 0, name: String, brand: String = "", source: Source, barcode: String? = nil,
                kcal: Double, protein: Double, carbs: Double, fat: Double, fiber: Double? = nil, sugar: Double? = nil,
                gramsPerPiece: Double? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.brand = brand
        self.source = source
        self.barcode = barcode
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.sugar = sugar
        self.gramsPerPiece = gramsPerPiece
        self.createdAt = createdAt
    }

    public var displayName: String {
        let base = brand.isEmpty ? name : "\(name) — \(brand)"
        switch source {
        case .label: return "\(base) (my food)"
        case .openFoodFacts: return "\(base) (Open Food Facts)"
        }
    }

    public var record: FoodRecord {
        FoodRecord(
            fdcID: id,
            description: displayName,
            dataType: source.rawValue,
            nutrients: FoodNutrients(kcal: kcal, kcalSource: source.rawValue, protein: protein, fat: fat, carbs: carbs,
                                     fiber: fiber, sugar: sugar),
            portions: gramsPerPiece.map { [FoodPortion(amount: 1, unitText: "piece", grams: $0)] } ?? []
        )
    }
}

/// The user's own foods, saved as JSON in the app's folder. Thread-safe.
public final class CustomFoodStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private var foods: [CustomFood]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([CustomFood].self, from: data) {
            foods = decoded
        } else {
            foods = []
        }
    }

    public var all: [CustomFood] {
        lock.lock(); defer { lock.unlock() }
        return foods.sorted { $0.createdAt > $1.createdAt }
    }

    public func food(id: Int) -> CustomFood? {
        lock.lock(); defer { lock.unlock() }
        return foods.first { $0.id == id }
    }

    /// Saves a food and returns it with its new (negative) ID. The same barcode is saved only once.
    @discardableResult
    public func add(_ food: CustomFood) -> CustomFood {
        lock.lock(); defer { lock.unlock() }
        if let barcode = food.barcode, !barcode.isEmpty, let existing = foods.first(where: { $0.barcode == barcode }) {
            return existing
        }
        var saved = food
        saved.id = min(-1, (foods.map(\.id).min() ?? 0) - 1)
        foods.append(saved)
        persistLocked()
        return saved
    }

    public func delete(id: Int) {
        lock.lock(); defer { lock.unlock() }
        foods.removeAll { $0.id == id }
        persistLocked()
    }

    /// Saved foods whose name fits an ingredient name ("low-fat mayonnaise" ↔ "Light mayonnaise"
    /// doesn't match; "mayonnaise" ↔ "Hellmann's mayonnaise light" does).
    public func matching(ingredientName: String) -> [CustomFood] {
        // The ingredient's own words (no USDA synonyms), without preparation and fat-level descriptors,
        // so "low-fat mayonnaise" finds a saved "Light mayonnaise".
        let wanted = Set(TextMatching.tokens(ingredientName).filter {
            $0.count >= 2 && !$0.allSatisfy(\.isNumber) && !FoodSearch.ignoredWords.contains($0)
                && !FoodSearch.genericTerms.contains($0) && !Self.descriptors.contains($0)
        })
        guard !wanted.isEmpty else { return [] }
        return all.filter { food in
            let have = Set(TextMatching.tokens(food.name + " " + food.brand))
            let haveStems = Set(have.map(Self.stem))
            return wanted.allSatisfy { have.contains($0) || haveStems.contains(Self.stem($0)) }
        }
    }

    static let descriptors: Set<String> = [
        "low", "fat", "lowfat", "nonfat", "light", "lite", "reduced", "free", "zero", "skimmed", "semi",
        "organic", "full", "lean", "extra", "virgin", "unsalted", "salted", "sweetened", "unsweetened"
    ]

    static func stem(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
    }

    private func persistLocked() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(foods) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
