import Foundation

/// Turns an ingredient name into FoodData Central search terms.
/// FDC descriptions are formal ("Oil, olive, salad or cooking"), so common recipe names are rewritten.
public enum FoodSearch {

    /// Recipe wording → FDC wording. Checked as whole phrases, longest first.
    public static let synonyms: [String: String] = [
        "extra virgin olive oil": "oil olive",
        "evoo": "oil olive",
        "olive oil": "oil olive",
        "sesame oil": "oil sesame",
        "coconut oil": "oil coconut",
        "avocado oil": "oil avocado",
        "panko": "bread crumbs dry grated plain",
        "panko breadcrumbs": "bread crumbs dry grated plain",
        "panko bread crumbs": "bread crumbs dry grated plain",
        "breadcrumbs": "bread crumbs dry grated plain",
        "breadcrumb": "bread crumbs dry grated plain",
        "flour tortilla": "tortillas ready bake fry flour refrigerated",
        "flour tortillas": "tortillas ready bake fry flour refrigerated",
        "corn tortilla": "tortillas ready bake fry corn",
        "corn tortillas": "tortillas ready bake fry corn",
        "tortilla wrap": "tortillas ready bake fry flour refrigerated",
        "tortilla wraps": "tortillas ready bake fry flour refrigerated",
        "vegetable oil": "oil vegetable",
        "scallion": "onions spring",
        "scallions": "onions spring",
        "green onion": "onions spring",
        "spring onion": "onions spring",
        "courgette": "squash summer zucchini",
        "zucchini": "squash summer zucchini",
        "aubergine": "eggplant",
        "cilantro": "coriander leaves",
        "fresh coriander": "coriander leaves",
        "rocket": "arugula",
        "red pepper": "peppers sweet red",
        "red bell pepper": "peppers sweet red",
        "green pepper": "peppers sweet green",
        "yellow pepper": "peppers sweet yellow",
        "bell pepper": "peppers sweet red",
        "capsicum": "peppers sweet red",
        "garbanzo": "chickpeas",
        "chickpea": "chickpeas",
        "greek yogurt": "yogurt greek plain",
        "greek yoghurt": "yogurt greek plain",
        "yoghurt": "yogurt",
        "whey protein": "protein powder whey",
        "protein powder": "protein powder whey",
        "rolled oats": "cereals oats regular quick",
        "porridge oats": "cereals oats regular quick",
        "oats": "cereals oats regular quick",
        "oat": "cereals oats regular quick",
        "plain flour": "wheat flour white all purpose",
        "all purpose flour": "wheat flour white all purpose",
        "flour": "wheat flour white all purpose",
        "caster sugar": "sugars granulated",
        "white sugar": "sugars granulated",
        "sugar": "sugars granulated",
        "brown sugar": "sugars brown",
        "icing sugar": "sugars powdered",
        "powdered sugar": "sugars powdered",
        "double cream": "cream heavy whipping",
        "heavy cream": "cream heavy whipping",
        "single cream": "cream light",
        "minced beef": "beef ground",
        "ground beef": "beef ground",
        "beef mince": "beef ground",
        "mince": "beef ground",
        "minced chicken": "chicken ground",
        "ground turkey": "turkey ground",
        "prawn": "crustaceans shrimp",
        "prawns": "crustaceans shrimp",
        "shrimp": "crustaceans shrimp",
        "chicken breast": "chicken breast meat only raw",
        "chicken thigh": "chicken thigh raw",
        "salmon fillet": "fish salmon atlantic raw",
        "salmon": "fish salmon atlantic",
        "tuna": "fish tuna",
        "cod": "fish cod",
        "egg": "egg whole raw",
        "eggs": "egg whole raw",
        "egg white": "egg white raw",
        "egg whites": "egg white raw",
        "egg yolk": "egg yolk raw",
        "butter": "butter salted",
        "unsalted butter": "butter without salt",
        "lemon juice": "lemon juice raw",
        "lime juice": "lime juice raw",
        "garlic": "garlic raw",
        "garlic paste": "garlic raw",
        "minced garlic": "garlic raw",
        "garlic clove": "garlic raw",
        "garlic powder": "spices garlic powder",
        "granulated garlic": "spices garlic powder",
        "onion powder": "spices onion powder",
        "ginger paste": "ginger root raw",
        "fresh ginger": "ginger root raw",
        "grated ginger": "ginger root raw",
        "ginger": "ginger root raw",
        "ground ginger": "spices ginger ground",
        "sushi rice": "rice white short grain",
        "short grain rice": "rice white short grain",
        "arborio rice": "rice white medium grain",
        "risotto rice": "rice white medium grain",
        "dry weight": "uncooked",
        "skimmed milk": "milk nonfat fluid",
        "skim milk": "milk nonfat fluid",
        "semi skimmed milk": "milk reduced fat fluid 2",
        "low fat milk": "milk lowfat fluid",
        "whole milk": "milk whole",
        "0 fat": "nonfat",
        "zero fat": "nonfat",
        "fat free": "nonfat",
        "skimmed": "nonfat",
        "low fat": "lowfat",
        "water": "water bottled generic",
        "cold water": "water bottled generic",
        "mayonnaise": "salad dressing mayonnaise regular",
        "mayo": "salad dressing mayonnaise regular",
        "low fat mayonnaise": "salad dressing mayonnaise light",
        "low fat mayo": "salad dressing mayonnaise light",
        "light mayonnaise": "salad dressing mayonnaise light",
        "light mayo": "salad dressing mayonnaise light",
        "reduced fat mayonnaise": "salad dressing mayonnaise light",
        "dark soy sauce": "soy sauce shoyu",
        "light soy sauce": "soy sauce shoyu",
        "chicken thighs": "chicken thigh raw",
        "skyr": "yogurt greek plain nonfat",
        "0 greek yogurt": "yogurt greek plain nonfat",
        "fat free greek yogurt": "yogurt greek plain nonfat",
        "nonfat greek yogurt": "yogurt greek plain nonfat",
        "0 greek yoghurt": "yogurt greek plain nonfat",
        "onion": "onions raw",
        "red onion": "onions raw",
        "tomato": "tomatoes red ripe raw",
        "tomatoes": "tomatoes red ripe raw",
        "cherry tomatoes": "tomatoes red ripe raw",
        "potato": "potatoes flesh and skin raw",
        "sweet potato": "sweet potato raw",
        "chia": "seeds chia",
        "chia seeds": "seeds chia",
        "flaxseed": "seeds flaxseed",
        "sesame seeds": "seeds sesame",
        "pumpkin seeds": "seeds pumpkin",
        "peanut butter": "peanut butter smooth",
        "soy sauce": "soy sauce",
        "honey": "honey",
        "maple syrup": "syrups maple",
        "parmesan": "cheese parmesan",
        "feta": "cheese feta",
        "mozzarella": "cheese mozzarella",
        "cheddar": "cheese cheddar",
        "cottage cheese": "cheese cottage",
        "cream cheese": "cheese cream",
        "ricotta": "cheese ricotta",
        "halloumi": "cheese",
        "basmati": "rice white long grain",
        "basmati rice": "rice white long grain",
        "jasmine rice": "rice white long grain",
        "white rice": "rice white long grain",
        "brown rice": "rice brown long grain",
        "spaghetti": "pasta dry",
        "pasta": "pasta dry",
        "noodles": "noodles egg",
        "tofu": "tofu firm",
        "spinach": "spinach raw",
        "kale": "kale raw",
        "broccoli": "broccoli raw",
        "cauliflower": "cauliflower raw",
        "mushrooms": "mushrooms white raw",
        "avocado": "avocados raw",
        "banana": "bananas raw",
        "blueberries": "blueberries raw",
        "strawberries": "strawberries raw",
        "almond milk": "beverages almond milk unsweetened",
        "coconut milk": "nuts coconut milk",
        "smoked paprika": "spices paprika",
        "oat milk": "beverages oat milk",
        "milk": "milk whole",
        "black pepper": "spices pepper black",
        "pepper": "spices pepper black",
        "salt": "salt table",
        "paprika": "spices paprika",
        "cumin": "spices cumin",
        "cinnamon": "spices cinnamon ground",
        "chili flakes": "spices pepper red or cayenne",
        "sriracha": "sauce hot chile sriracha",
        "hot sauce": "sauce hot chile",
        "tahini": "seeds sesame butter tahini",
        "hummus": "hummus",
        "cocoa powder": "cocoa dry powder unsweetened",
        "dark chocolate": "chocolate dark",
        "chocolate chips": "chocolate semisweet",
        "vanilla extract": "vanilla extract",
        "baking powder": "leavening agents baking powder",
        "baking soda": "leavening agents baking soda",
        "cornstarch": "cornstarch",
        "cornflour": "cornstarch"
    ]

    /// Words that describe preparation, not the food.
    static let ignoredWords: Set<String> = [
        "fresh", "freshly", "chopped", "diced", "sliced", "minced", "grated", "shredded", "peeled", "finely",
        "roughly", "thinly", "optional", "organic", "large", "medium", "small", "of", "and", "or", "the", "a",
        "to", "for", "with", "plus", "extra", "some", "about", "handful", "pinch", "splash", "knob",
        "tbsp", "tsp", "g", "ml", "cup", "cups", "oz", "lb", "pieces", "piece", "crushed", "ripe", "softened",
        "weight", "if", "needed", "finish", "serve", "serving", "taste", "packet", "instructions", "according",
        "melted", "room", "temperature", "cold", "warm", "hot", "skin", "on", "off",
        "thicken", "drizzle", "garnish", "dusting", "frying", "greasing", "brushing", "topping"
    ]

    /// Words that mean the ingredient is already cooked or processed (keeps cooked entries in results).
    static let cookedWords: Set<String> = [
        "cooked", "boiled", "fried", "roasted", "grilled", "baked", "steamed", "canned", "smoked", "mashed",
        "toasted", "leftover", "stewed", "braised", "poached", "sauteed"
    ]

    /// Description words that usually make a database entry a poor default.
    static let penalizedWords: Set<String> = [
        "babyfood", "infant", "formula", "fast", "restaurant", "dehydrated", "imitation", "mixed",
        "frozen", "canned", "prepared", "glazed", "breaded", "supplement", "candies", "snacks"
    ]

    /// Search terms for an ingredient name (normalized, synonyms applied, prep words removed).
    static let sortedSynonymKeys: [String] = synonyms.keys.sorted { ($0.count, $0) > ($1.count, $1) }

    public static func terms(for ingredientName: String) -> [String] {
        // Replace every recipe phrase with its FDC wording, longest phrases first. Replaced parts are
        // protected with placeholders so a replacement is never rewritten again.
        var text = " " + TextMatching.normalize(ingredientName) + " "
        var replacements: [String] = []
        for key in sortedSynonymKeys where text.contains(" \(key) ") {
            text = text.replacingOccurrences(of: " \(key) ", with: " §\(replacements.count)§ ")
            replacements.append(synonyms[key]!)
        }
        for (index, value) in replacements.enumerated() {
            text = text.replacingOccurrences(of: "§\(index)§", with: value)
        }
        var seen = Set<String>()
        return text.split(separator: " ").map(String.init).filter { token in
            guard token.count >= 2, !ignoredWords.contains(token), !token.allSatisfy(\.isNumber) else { return false }
            return seen.insert(token).inserted
        }
    }

    /// All subsets of `items` with `size` elements, keeping the original order inside each subset.
    public static func combinations(of items: [String], size: Int) -> [[String]] {
        guard size > 0 else { return [[]] }
        guard items.count >= size else { return [] }
        guard let first = items.first else { return [] }
        let rest = Array(items.dropFirst())
        return combinations(of: rest, size: size - 1).map { [first] + $0 } + combinations(of: rest, size: size)
    }

    /// FTS5 MATCH expression. `all = true` requires every term; otherwise any term.
    public static func ftsQuery(terms: [String], all: Bool) -> String {
        terms
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"*" }
            .joined(separator: all ? " AND " : " OR ")
    }

    /// Modifier words added by synonyms; too generic to search on alone.
    static let genericTerms: Set<String> = [
        "raw", "whole", "white", "plain", "regular", "meat", "only", "sweet", "red", "green", "yellow", "salted",
        "smooth", "table", "ground", "long", "grain", "dry", "fluid", "light", "heavy", "all", "purpose", "firm"
    ]

    /// Terms for the fallback "any term" query: the food words, without generic modifiers.
    public static func coreTerms(_ terms: [String]) -> [String] {
        let core = terms.filter { !genericTerms.contains($0) }
        return core.isEmpty ? terms : core
    }

    /// Re-ranks database hits: entries matching every term first, then prefer raw/plain entries unless the
    /// ingredient says cooked, and entries whose leading words follow the search terms.
    public static func rerank(_ hits: [FoodCandidate], ingredientName: String, fullMatchIDs: Set<Int> = []) -> [FoodCandidate] {
        let nameTokens = Set(TextMatching.tokens(ingredientName))
        let wantsCooked = !nameTokens.isDisjoint(with: cookedWords)
        let searchTerms = terms(for: ingredientName)
        return hits.enumerated().map { offset, hit -> (FoodCandidate, Double) in
            let words = Set(TextMatching.tokens(hit.description))
            var score = -Double(offset) * 0.1                   // full-text rank as a weak base
            if fullMatchIDs.contains(hit.fdcID) { score += 2 }
            if !wantsCooked {
                if words.contains("raw") { score += 1 }
                if !words.isDisjoint(with: cookedWords) { score -= 3 }
            } else if !words.isDisjoint(with: cookedWords) {
                score += 3
            }
            score -= Double(words.intersection(penalizedWords).subtracting(nameTokens).count) * 2
            // FDC names lead with the food ("Oil, olive, …", "Milk, whole, …"): reward descriptions whose
            // leading words follow the search terms in order.
            var lead = 0
            for (word, term) in zip(TextMatching.tokens(hit.description), searchTerms) {
                guard word.hasPrefix(term) || term.hasPrefix(word) else { break }
                lead += 1
            }
            score += Double(lead) * 1.5
            score -= Double(hit.description.count) / 60          // shorter = more generic
            return (hit, score)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }
}
