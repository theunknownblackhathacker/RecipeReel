import Foundation

/// Deterministic Swift clean-up of model output. This is where the "never invent" rules are enforced:
/// steps must be grounded in the source, times must be stated in the source, and amounts are never guessed.
public enum ExtractionPostProcessor {

    // MARK: - Ingredients (pass A)

    /// Names that are nutrition claims or labels, not ingredients.
    static let nonIngredientNames: Set<String> = [
        "protein", "calories", "calorie", "kcal", "carbs", "carb", "carbohydrates", "fat", "fats",
        "macros", "serving", "servings", "fiber", "fibre", "sugar content"
    ]

    public static func mergeIngredients(_ raws: [RawRecipe]) -> (title: String, servings: Int?, ingredients: [IngredientDraft]) {
        var drafts: [IngredientDraft] = []
        var keys: [String] = []
        for raw in raws {
            for item in raw.ingredients {
                guard var draft = clean(item) else { continue }
                let key = TextMatching.normalize(draft.name)
                if let index = keys.firstIndex(where: { $0 == key || TextMatching.similarity($0, key) >= 0.9 }) {
                    // Same ingredient seen again (OCR repeats, chunk overlap): keep one, never add them up.
                    let existing = drafts[index]
                    if existing.quantity == nil, draft.quantity != nil {
                        draft.name = existing.name
                        drafts[index] = draft
                    } else if existing.confidence < draft.confidence, draft.quantity != nil {
                        drafts[index] = draft
                    }
                    continue
                }
                drafts.append(draft)
                keys.append(key)
            }
        }
        let title = raws.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        let servings = raws.map(\.servings).first { $0 > 0 }
        return (title, servings, drafts)
    }

    static func clean(_ item: RawIngredient) -> IngredientDraft? {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = TextMatching.normalize(name)
        guard !normalized.isEmpty, !nonIngredientNames.contains(normalized), !name.hasPrefix("#") else { return nil }

        var unit = CanonicalUnit(rawValue: item.unit) ?? CanonicalUnit.parse(item.unit) ?? .piece
        var quantity: Double? = item.quantity > 0 && item.quantity.isFinite ? item.quantity : nil
        var confidence = Confidence.parse(item.confidence)
        if unit == .toTaste { quantity = nil }
        if quantity == nil {
            // Convention: no amount anywhere → quantity null and flagged low-confidence.
            confidence = .low
            if unit != .toTaste, ["salt", "pepper", "black pepper", "salt and pepper"].contains(normalized) {
                unit = .toTaste
            }
        }
        return IngredientDraft(
            name: name,
            quantity: quantity,
            unit: unit,
            note: item.note.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: confidence,
            sourceQuote: item.sourceQuote
        )
    }

    // MARK: - Steps (pass B)

    /// Verbs and cues that show a source actually describes a method.
    static let methodWords: Set<String> = [
        "add", "mix", "stir", "bake", "cook", "fry", "sear", "boil", "simmer", "season", "serve", "combine",
        "whisk", "chop", "slice", "dice", "heat", "preheat", "pour", "place", "put", "flip", "baste", "blend",
        "fold", "roast", "grill", "toast", "refrigerate", "fridge", "chill", "cool", "rest", "marinate",
        "layer", "top", "spread", "cover", "drain", "rinse", "peel", "cut", "sprinkle", "melt", "knead",
        "roll", "shape", "freeze", "microwave", "airfry", "saute", "steam", "garnish", "transfer", "remove",
        "wait", "scoop", "assemble", "wrap", "fill", "shake", "squeeze", "drizzle", "toss", "beat", "mash",
        "press", "soak", "brown", "reduce", "oven", "pan", "skillet", "minutes", "minute", "mins", "min",
        "hour", "hours", "overnight", "until", "then", "stir", "dip", "coat", "bring", "let", "leave",
        "grate", "crack", "pulse", "smash", "char", "broil", "poach", "fryer", "jar", "bowl"
    ]

    /// True when the source text contains any method vocabulary (hashtags excluded).
    public static func sourceDescribesMethod(_ source: String) -> Bool {
        let withoutHashtags = source
            .split(whereSeparator: \.isWhitespace)
            .filter { !$0.hasPrefix("#") && !$0.hasPrefix("@") }
            .joined(separator: " ")
        let tokens = TextMatching.tokens(withoutHashtags).filter { !servingWords.contains($0) }
        return tokens.contains { token in
            methodWords.contains(token) || methodWords.contains(stem(token))
        }
    }

    /// Light stemming for verbs ("stirring" → "stirr", "adds" → "add"). "-ed" is deliberately not
    /// stripped: "cooked rice" or "chopped onion" in an ingredient line is not a method.
    /// "SERVES 1" / "2 servings" are labels, not actions.
    static let servingWords: Set<String> = ["serves", "serving", "servings", "server"]

    static func stem(_ token: String) -> String {
        for suffix in ["ing", "s"] where token.count > suffix.count + 2 && token.hasSuffix(suffix) {
            return String(token.dropLast(suffix.count))
        }
        return token
    }

    public static func mergeSteps(
        _ methods: [RawMethod],
        source: SourceTimeline,
        ingredientNames: [String]
    ) -> (hasInstructions: Bool, steps: [StepDraft], dropped: [String]) {
        let sourceText = source.plainText
        var dropped: [String] = []

        guard methods.contains(where: { $0.hasInstructions || !$0.steps.isEmpty }) else {
            return (false, [], [])
        }
        guard sourceDescribesMethod(sourceText) else {
            let all = methods.flatMap(\.steps).map { "\($0.text) — source has no method" }
            return (false, [], all)
        }

        var steps: [StepDraft] = []
        for method in methods {
            for raw in method.steps {
                let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                guard TextMatching.quoteAppears(raw.sourceQuote, in: sourceText) else {
                    dropped.append("\(text) — quote not found in source: \"\(raw.sourceQuote)\"")
                    continue
                }
                // The quoted words themselves must describe an action (an ingredient line like
                // "200g chicken breast" can't justify "Cook the chicken").
                guard sourceDescribesMethod(raw.sourceQuote) else {
                    dropped.append("\(text) — quote has no cooking action: \"\(raw.sourceQuote)\"")
                    continue
                }
                if steps.contains(where: { TextMatching.similarity(TextMatching.normalize($0.text), TextMatching.normalize(text)) >= 0.9 }) {
                    continue
                }
                var confidence = Confidence.parse(raw.confidence)
                var minutes: Int? = raw.minutes > 0 ? raw.minutes : nil
                if let stated = minutes, !minutesStated(stated, in: raw.sourceQuote) {
                    dropped.append("\(text) — removed \(stated) min (not stated in source)")
                    minutes = nil
                }
                // Numbers in the step that don't appear in the source (invented times/temperatures).
                var allowed = numbersIncludingWords(in: sourceText)
                if let minutes { allowed.insert(Double(minutes)) }
                let unsupported = numbers(in: text).subtracting(allowed)
                if !unsupported.isEmpty {
                    confidence = .low
                    dropped.append("\(text) — flagged: numbers \(unsupported.sorted()) not in source")
                }
                steps.append(StepDraft(
                    text: text,
                    minutes: minutes,
                    ingredientNames: matchNames(raw.ingredientsUsed, to: ingredientNames),
                    confidence: confidence,
                    sourceQuote: raw.sourceQuote
                ))
            }
        }
        return (!steps.isEmpty, steps, dropped)
    }

    /// Keeps only names that refer to an ingredient in the list (mapped to the list's spelling).
    static func matchNames(_ used: [String], to names: [String]) -> [String] {
        var result: [String] = []
        for name in used {
            let n = TextMatching.normalize(name)
            guard !n.isEmpty else { continue }
            let match = names.first { candidate in
                let c = TextMatching.normalize(candidate)
                return c == n || c.contains(n) || n.contains(c) || TextMatching.similarity(c, n) >= 0.8
            }
            if let match, !result.contains(match) { result.append(match) }
        }
        return result
    }

    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
        "forty five": 45, "sixty": 60, "ninety": 90
    ]

    /// True when the quote states this duration (digits, words, "a minute", hours).
    static func minutesStated(_ minutes: Int, in quote: String) -> Bool {
        let q = " " + TextMatching.normalize(quote) + " "
        let numbersInQuote = numbers(in: quote)
        if numbersInQuote.contains(Double(minutes)) { return true }
        for (word, value) in numberWords where value == minutes && q.contains(" \(word) ") { return true }
        if minutes == 1, q.contains(" a minute ") || q.contains(" one minute ") { return true }
        if minutes == 30, q.contains(" half an hour ") || q.contains(" half hour ") { return true }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            if q.contains(" hour") {
                if hours == 1, q.contains(" an hour ") || q.contains(" one hour ") || q.contains(" 1 hour") { return true }
                if numbersInQuote.contains(Double(hours)) { return true }
                if numberWords.contains(where: { $0.value == hours && q.contains(" \($0.key) hour") }) { return true }
            }
        }
        // Ranges like "3-4 minutes" or "10 to 12 min": accept any number in the range.
        return false
    }

    /// Digits plus number words ("three cloves" → 3, "a minute" → 1).
    static func numbersIncludingWords(in text: String) -> Set<Double> {
        var result = numbers(in: text)
        let q = " " + TextMatching.normalize(text) + " "
        for (word, value) in numberWords where q.contains(" \(word) ") { result.insert(Double(value)) }
        if q.contains(" a minute ") || q.contains(" an hour ") { result.insert(1) }
        if q.contains(" half ") { result.insert(0.5) }
        return result
    }

    /// Numbers written as digits (incl. decimals and fractions like 1/2 → 0.5).
    static func numbers(in text: String) -> Set<Double> {
        var result = Set<Double>()
        let pattern = #"(\d+)\s*/\s*(\d+)|\d+(?:[.,]\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range(at: 1).location != NSNotFound, match.range(at: 2).location != NSNotFound,
               let a = Double(ns.substring(with: match.range(at: 1))),
               let b = Double(ns.substring(with: match.range(at: 2))), b != 0 {
                result.insert(a / b)
                result.insert(a)
                result.insert(b)
            } else {
                let token = ns.substring(with: match.range).replacingOccurrences(of: ",", with: ".")
                if let value = Double(token) { result.insert(value) }
            }
        }
        return result
    }
}
