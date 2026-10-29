import Foundation

/// A recipe read from a web page the user opened in the in-app browser.
public struct WebRecipe: Sendable, Equatable {
    public var name: String
    public var ingredients: [String]
    public var steps: [String]

    public init(name: String, ingredients: [String], steps: [String]) {
        self.name = name
        self.ingredients = ingredients
        self.steps = steps
    }
}

/// Reads the schema.org `Recipe` data that most recipe sites publish in their pages
/// (`<script type="application/ld+json">`, the same data search engines use for recipe cards).
/// Only runs on a single page the user chose to open — no crawling.
public enum WebRecipeParser {

    /// Parses the page's JSON-LD blocks (and, as a fallback, microdata instruction texts).
    public static func parse(jsonLD blocks: [String], microdataInstructions: [String] = []) -> WebRecipe? {
        for block in blocks {
            guard let data = block.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let recipe = findRecipe(in: json)
            else { continue }
            let steps = instructions(from: recipe["recipeInstructions"])
            let ingredients = (recipe["recipeIngredient"] as? [Any] ?? recipe["ingredients"] as? [Any] ?? [])
                .compactMap { $0 as? String }
                .map(clean)
                .filter { !$0.isEmpty }
            let name = clean(recipe["name"] as? String ?? "")
            if !steps.isEmpty {
                return WebRecipe(name: name, ingredients: ingredients, steps: steps)
            }
            if !microdataInstructions.isEmpty {
                return WebRecipe(name: name, ingredients: ingredients, steps: microdataSteps(microdataInstructions))
            }
        }
        if !microdataInstructions.isEmpty {
            let steps = microdataSteps(microdataInstructions)
            return steps.isEmpty ? nil : WebRecipe(name: "", ingredients: [], steps: steps)
        }
        return nil
    }

    /// Finds the first object whose @type is (or includes) "Recipe", anywhere in the JSON.
    static func findRecipe(in json: Any) -> [String: Any]? {
        if let dict = json as? [String: Any] {
            if isRecipe(dict["@type"]) { return dict }
            for key in ["@graph", "mainEntity", "mainEntityOfPage", "itemListElement", "item"] {
                if let value = dict[key], let found = findRecipe(in: value) { return found }
            }
            return nil
        }
        if let array = json as? [Any] {
            for element in array {
                if let found = findRecipe(in: element) { return found }
            }
        }
        return nil
    }

    static func isRecipe(_ type: Any?) -> Bool {
        if let string = type as? String { return string.caseInsensitiveCompare("Recipe") == .orderedSame || string.hasSuffix("/Recipe") }
        if let array = type as? [Any] { return array.contains { isRecipe($0) } }
        return false
    }

    /// recipeInstructions can be a string, a list of strings, HowToStep objects, or HowToSections.
    static func instructions(from value: Any?) -> [String] {
        switch value {
        case let text as String:
            return split(clean(text, keepBreaks: true))
        case let array as [Any]:
            return array.flatMap { instructions(from: $0) }
        case let dict as [String: Any]:
            if let items = dict["itemListElement"] {
                return instructions(from: items)                     // HowToSection
            }
            if let text = dict["text"] as? String ?? dict["name"] as? String ?? dict["description"] as? String {
                return split(clean(text, keepBreaks: true))           // HowToStep / HowToDirection
            }
            return []
        default:
            return []
        }
    }

    static func microdataSteps(_ texts: [String]) -> [String] {
        texts.flatMap { split(clean($0, keepBreaks: true)) }
    }

    /// Text the user selected on a page → steps (one per line, numbering removed).
    public static func steps(fromSelection text: String) -> [String] {
        split(text)
    }

    /// Splits text into steps on line breaks and removes "1.", "Step 2:" style prefixes.
    static func split(_ text: String) -> [String] {
        let pattern = #"^\s*(?:step\s*)?\d{1,2}\s*[\.\):\-]\s*"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return text
            .components(separatedBy: .newlines)
            .map { line -> String in
                var cleaned = line.trimmingCharacters(in: .whitespaces)
                if let regex {
                    let range = NSRange(cleaned.startIndex..., in: cleaned)
                    cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
                }
                return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " •-–·\t"))
            }
            .filter { $0.count >= 3 && !$0.lowercased().hasPrefix("step ") }
    }

    /// Strips HTML tags and decodes common entities.
    public static func clean(_ html: String, keepBreaks: Bool = false) -> String {
        var text = html
        if keepBreaks {
            for tag in ["<br>", "<br/>", "<br />", "</p>", "</li>", "</div>"] {
                text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
            }
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let named = ["&amp;": "&", "&nbsp;": " ", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">",
                     "&deg;": "°", "&frac12;": "½", "&frac14;": "¼", "&frac34;": "¾", "&ndash;": "–", "&mdash;": "—",
                     "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&hellip;": "…"]
        for (entity, value) in named {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = decodeNumericEntities(text)
        let lines = text.components(separatedBy: .newlines).map {
            $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        return (keepBreaks ? lines : [lines.joined(separator: " ")])
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeNumericEntities(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let isHex = match.range(at: 1).length > 0
            let digits = ns.substring(with: match.range(at: 2))
            if let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
            } else {
                result += ns.substring(with: match.range)
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}

/// Finds a cooking duration in step text ("bake for 20–25 minutes" → 25, "1 hour" → 60).
public enum DurationParser {
    public static func minutes(in text: String) -> Int? {
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(?:(?:-|–|to)\s*(\d+(?:[.,]\d+)?))?\s*(hours?|hrs?|minutes?|mins?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func number(_ index: Int) -> Double? {
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return nil }
            return Double(ns.substring(with: range).replacingOccurrences(of: ",", with: "."))
        }
        guard let low = number(1) else { return nil }
        let value = number(2) ?? low                 // ranges: use the upper bound
        let unit = ns.substring(with: match.range(at: 3)).lowercased()
        let minutes = unit.hasPrefix("h") ? value * 60 : value
        guard minutes > 0, minutes <= 24 * 60 else { return nil }
        return Int(minutes.rounded())
    }
}
