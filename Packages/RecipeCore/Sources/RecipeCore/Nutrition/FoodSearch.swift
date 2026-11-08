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
        "melted", "room", "temperature", "cold", "warm", "hot", "skin", "on", "off", "crumbled", "cubed",
        "thicken", "drizzle", "garnish", "dusting", "frying", "greasing", "brushing", "topping"
    ]

    /// Words that mean the ingredient is already cooked or processed (keeps cooked entries in results).
    static let cookedWords: Set<String> = [
        "cooked", "boiled", "fried", "roasted", "grilled", "baked", "steamed", "canned", "smoked", "mashed",
        "toasted", "leftover", "stewed", "braised", "poached", "sauteed", "casseroled"
    ]

    /// Description words that usually make a database entry a poor default.
    static let penalizedWords: Set<String> = [
        "babyfood", "infant", "formula", "fast", "restaurant", "dehydrated", "imitation", "mixed",
        "frozen", "canned", "prepared", "glazed", "breaded", "supplement", "candies", "snacks"
    ]

    /// Search terms for an ingredient name (normalized, synonyms applied, prep words removed).
    static let sortedSynonymKeys: [String] = synonyms.keys.sorted { ($0.count, $0) > ($1.count, $1) }

    public static func terms(for ingredientName: String) -> [String] {
        terms(for: ingredientName, table: synonyms, sortedKeys: sortedSynonymKeys)
    }

    static func terms(for ingredientName: String, table: [String: String], sortedKeys: [String]) -> [String] {
        // Replace every recipe phrase with its database wording, longest phrases first. Replaced parts are
        // protected with placeholders so a replacement is never rewritten again.
        var text = " " + TextMatching.normalize(ingredientName) + " "
        var replacements: [String] = []
        for key in sortedKeys where text.contains(" \(key) ") {
            text = text.replacingOccurrences(of: " \(key) ", with: " §\(replacements.count)§ ")
            replacements.append(table[key]!)
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

    // MARK: - European tables (Ciqual, CoFID)

    /// Recipe wording → Ciqual/CoFID wording, used for the European search (checked before the USDA
    /// wording). Only needed where the plain recipe words don't find the right European food.
    public static let europeanSynonyms: [String: String] = [
        "flour": "flour wheat white plain",
        "plain flour": "flour wheat white plain",
        "all purpose flour": "flour wheat white plain",
        "white flour": "flour wheat white plain",
        "wheat flour": "flour wheat white plain",
        "self raising flour": "flour wheat self raising",
        "self rising flour": "flour wheat self raising",
        "bread flour": "flour wheat white breadmaking",
        "cornstarch": "maize corn starch",
        "corn starch": "maize corn starch",
        "cornflour": "maize corn starch",
        "heavy cream": "cream fresh whipping",
        "heavy whipping cream": "cream fresh whipping",
        "whipping cream": "cream fresh whipping",
        "double cream": "cream fresh double",
        "single cream": "cream fresh single",
        "light cream": "cream fresh single",
        "cooking cream": "cream fresh single",
        "sour cream": "cream fresh soured",
        "ground beef": "beef mince raw",
        "minced beef": "beef mince raw",
        "beef mince": "beef mince raw",
        "ground pork": "pork mince raw",
        "minced pork": "pork mince raw",
        "ground lamb": "lamb mince raw",
        "minced lamb": "lamb mince raw",
        "chicken breast": "chicken breast without skin raw",
        "chicken breasts": "chicken breast without skin raw",
        "mustard": "mustard smooth",
        "dijon mustard": "mustard smooth",
        "yellow mustard": "mustard smooth",
        "wholegrain mustard": "mustard wholegrain",
        "spaghetti": "pasta dry raw",
        "penne": "pasta dry raw",
        "fusilli": "pasta dry raw",
        "macaroni": "pasta dry raw",
        "rigatoni": "pasta dry raw",
        "orzo": "pasta dry raw",
        "pasta": "pasta dry raw",
        "chickpea": "chick pea dried",
        "chickpeas": "chick pea dried",
        "garbanzo beans": "chick pea dried",
        "cumin": "cumin",
        "ground cumin": "cumin",
        "paprika": "paprika powder",
        "smoked paprika": "paprika powder",
        "sweet paprika": "paprika powder",
        "cinnamon": "cinnamon powder",
        "ground cinnamon": "cinnamon powder",
        "black pepper": "black pepper powder",
        "pepper": "black pepper powder",
        "ground black pepper": "black pepper powder",
        "baking soda": "bicarbonate soda",
        "bicarbonate of soda": "bicarbonate soda",
        "sugar": "sugar white",
        "brown sugar": "sugar brown",
        "light brown sugar": "sugar brown",
        "dark brown sugar": "sugar brown",
        "milk": "milk whole",
        "apple cider vinegar": "vinegar cider",
        "cider vinegar": "vinegar cider",
        "red wine vinegar": "vinegar red wine",
        "balsamic vinegar": "vinegar balsamic",
        "feta": "feta ewe",
        "feta cheese": "feta ewe",
        "white sugar": "sugar white",
        "granulated sugar": "sugar white",
        "caster sugar": "sugar white",
        "icing sugar": "sugar icing",
        "powdered sugar": "sugar icing",
        "confectioners sugar": "sugar icing",
        "panko": "breadcrumbs",
        "panko breadcrumbs": "breadcrumbs",
        "panko bread crumbs": "breadcrumbs",
        "bread crumbs": "breadcrumbs",
        "flour tortilla": "tortilla wheat",
        "flour tortillas": "tortilla wheat",
        "tortilla wrap": "tortilla wheat",
        "tortilla wraps": "tortilla wheat",
        "wraps": "tortilla wheat",
        "corn tortilla": "tortilla maize corn",
        "corn tortillas": "tortilla maize corn",
        "tomato paste": "tomato puree",
        "skim milk": "milk skimmed",
        "skimmed milk": "milk skimmed",
        "semi skimmed milk": "milk semi skimmed",
        "whole milk": "milk whole",
        "greek yogurt": "yogurt greek style plain",
        "greek yoghurt": "yogurt greek style plain",
        "yoghurt": "yogurt",
        "zucchini": "courgette zucchini",
        "eggplant": "aubergine",
        "scallion": "onion spring",
        "scallions": "onion spring",
        "green onion": "onion spring",
        "green onions": "onion spring",
        "spring onion": "onion spring",
        "spring onions": "onion spring"
    ]

    static let sortedEuropeanKeys: [String] = europeanSynonyms.keys.sorted { ($0.count, $0) > ($1.count, $1) }

    /// The recipe's own words, without preparation words (no synonyms).
    public static func plainTerms(for ingredientName: String) -> [String] {
        var seen = Set<String>()
        return TextMatching.normalize(ingredientName).split(separator: " ").map(String.init).filter { token in
            guard token.count >= 2, !ignoredWords.contains(token), !token.allSatisfy(\.isNumber) else { return false }
            return seen.insert(token).inserted
        }
    }

    /// Term lists to try against the European tables, best first: European wording (or the plain words
    /// when no European synonym applies), then the USDA wording.
    public static func europeanTermOptions(for ingredientName: String) -> [[String]] {
        let text = " " + TextMatching.normalize(ingredientName) + " "
        var options: [[String]] = []
        if sortedEuropeanKeys.contains(where: { text.contains(" \($0) ") }) {
            options.append(terms(for: ingredientName, table: europeanSynonyms, sortedKeys: sortedEuropeanKeys))
        }
        options.append(plainTerms(for: ingredientName))
        options.append(terms(for: ingredientName))
        var seen = Set<[String]>()
        return options.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Words a European description may lack and still be the same food.
    static let optionalEuropeanTerms: Set<String> = ["raw", "only", "meat", "regular", "plain", "whole", "fluid"]

    /// A European food goes ahead of USDA only when it contains every important search word and isn't a
    /// cooked or processed version the recipe didn't ask for.
    public static func isGoodEuropeanMatch(_ description: String, terms: [String], ingredientName: String) -> Bool {
        let words = descriptionWords(description)
        let required = terms.filter { !optionalEuropeanTerms.contains($0) }
        let covers = (required.isEmpty ? terms : required).allSatisfy { term in
            words.contains { $0.hasPrefix(term) || (term.count > 3 && term.hasPrefix($0) && $0.count >= 3) }
        }
        guard covers else { return false }
        let nameTokens = Set(TextMatching.tokens(ingredientName))
        let wordSet = Set(words)
        if nameTokens.isDisjoint(with: cookedWords), !wordSet.isDisjoint(with: cookedWords.union(["casseroled"])) {
            return false
        }
        return wordSet.intersection(penalizedWords).subtracting(nameTokens).isEmpty
    }

    /// Words of a database description; "roasted/baked" counts as two words.
    static func descriptionWords(_ description: String) -> [String] {
        TextMatching.tokens(description)
            .flatMap { $0.split(separator: "/").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) } }
            .filter { !$0.isEmpty }
    }

    /// European matches first (up to six), then USDA, then any remaining European matches.
    public static func europeanFirst(_ european: [FoodCandidate], _ usda: [FoodCandidate], limit: Int) -> [FoodCandidate] {
        var seen = Set<String>()
        let merged = Array(european.prefix(6)) + usda + european.dropFirst(6)
        return Array(merged.filter { seen.insert($0.description.lowercased()).inserted }.prefix(limit))
    }

    /// Re-ranks database hits: entries matching every term first, then prefer raw/plain entries unless the
    /// ingredient says cooked, and entries whose leading words follow the search terms.
    public static func rerank(_ hits: [FoodCandidate], ingredientName: String, fullMatchIDs: Set<Int> = [],
                              searchTerms givenTerms: [String]? = nil) -> [FoodCandidate] {
        let nameTokens = Set(TextMatching.tokens(ingredientName))
        let wantsCooked = !nameTokens.isDisjoint(with: cookedWords)
        let searchTerms = givenTerms ?? terms(for: ingredientName)
        return hits.enumerated().map { offset, hit -> (FoodCandidate, Double) in
            let words = Set(descriptionWords(hit.description))
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
