import Foundation

/// One part of a recipe ("Chicken", "Alfredo sauce") and its ingredients.
/// Recipes without headings have a single group with an empty title.
public struct IngredientGroup<Item> {
    public var title: String
    public var items: [Item]

    public init(title: String, items: [Item]) {
        self.title = title
        self.items = items
    }

    /// Groups items by their group name, keeping parts in the order they first appear and items in
    /// their original order. Names differing only in case or spacing count as the same part.
    public static func make(_ items: [Item], group: (Item) -> String) -> [IngredientGroup<Item>] {
        var groups: [IngredientGroup<Item>] = []
        var indexByKey: [String: Int] = [:]
        for item in items {
            let title = IngredientGroups.clean(group(item))
            let key = IngredientGroups.key(title)
            if let index = indexByKey[key] {
                groups[index].items.append(item)
            } else {
                indexByKey[key] = groups.count
                groups.append(IngredientGroup(title: title, items: [item]))
            }
        }
        return groups
    }

}

public enum IngredientGroups {
    /// Names once each, in order (an ingredient can appear in two parts, e.g. salt).
    public static func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    /// "For the Alfredo Sauce:" → "Alfredo Sauce". Leading "for the", "for", trailing colons/dashes and
    /// emoji-style bullets are removed; the casing the model chose is kept.
    public static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ":-–—•*#").union(.whitespaces))
        let lower = text.lowercased()
        for prefix in ["for the ", "for "] where lower.hasPrefix(prefix) && text.count > prefix.count + 1 {
            text = String(text.dropFirst(prefix.count))
            break
        }
        guard let first = text.first else { return "" }
        return first.uppercased() + text.dropFirst()
    }

    /// Comparison key: lowercased letters and digits only.
    public static func key(_ title: String) -> String {
        TextMatching.normalize(clean(title))
    }

    /// Group names that mean "no particular part".
    static let noGroupKeys: Set<String> = ["", "ingredients", "ingredient", "ingredient list", "you will need",
                                            "you ll need", "youll need", "what you need", "recipe", "main", "other", "none"]

    public static func isNoGroup(_ title: String) -> Bool {
        noGroupKeys.contains(key(title))
    }
}
