import Foundation

// "Ask the chef": a conversation per recipe with the chosen AI engine. The chef answers and may
// propose edits; Swift validates them, the app shows the recalculated macros, and nothing changes
// until the user taps Apply (with Undo). The model never states macro numbers.

// MARK: - Model output

/// One edit as the model writes it. Unused fields are empty strings or 0.
public struct RawChefChange: Codable, Sendable, Equatable {
    public var action: String
    public var target: String
    public var name: String
    public var quantity: Double
    public var unit: String
    public var note: String
    public var group: String
    public var text: String
    public var minutes: Int
    public var position: Int

    public init(action: String, target: String = "", name: String = "", quantity: Double = 0, unit: String = "",
                note: String = "", group: String = "", text: String = "", minutes: Int = 0, position: Int = 0) {
        self.action = action
        self.target = target
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.note = note
        self.group = group
        self.text = text
        self.minutes = minutes
        self.position = position
    }
}

public struct RawChefReply: Sendable, Equatable {
    public var reply: String
    public var changes: [RawChefChange]
    public var rawOutput: String

    public init(reply: String, changes: [RawChefChange], rawOutput: String = "") {
        self.reply = reply
        self.changes = changes
        self.rawOutput = rawOutput
    }
}

/// An AI engine that can play the chef (Apple Intelligence or the user's API).
public protocol RecipeChefing: Sendable {
    func chef(instructions: String, prompt: String) async throws -> RawChefReply
}

// MARK: - The recipe as the chef sees and edits it

/// A plain copy of a recipe: what the chef is shown, what proposed edits are applied to, and the
/// snapshot Undo restores. `key` links an item back to the saved ingredient/step it came from.
public struct ChefRecipe: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var key: Int?
        public var name: String
        public var quantity: Double?
        public var unit: CanonicalUnit
        public var note: String
        public var group: String
        public var fdcID: Int?
        public var foodDescription: String?
        public var matchStatus: MatchStatus
        public var confidence: Confidence
        public var sourceQuote: String
        public var reviewed: Bool
        public var changedByChef: Bool

        public init(key: Int?, name: String, quantity: Double?, unit: CanonicalUnit, note: String = "", group: String = "",
                    fdcID: Int? = nil, foodDescription: String? = nil, matchStatus: MatchStatus = .unmatched,
                    confidence: Confidence = .high, sourceQuote: String = "", reviewed: Bool = false,
                    changedByChef: Bool = false) {
            self.key = key
            self.name = name
            self.quantity = quantity
            self.unit = unit
            self.note = note
            self.group = group
            self.fdcID = fdcID
            self.foodDescription = foodDescription
            self.matchStatus = matchStatus
            self.confidence = confidence
            self.sourceQuote = sourceQuote
            self.reviewed = reviewed
            self.changedByChef = changedByChef
        }
    }

    public struct StepItem: Codable, Sendable, Equatable {
        public var key: Int?
        public var text: String
        public var minutes: Int?
        public var ingredientNames: [String]
        public var origin: StepOrigin
        public var confidence: Confidence
        public var sourceQuote: String

        public init(key: Int?, text: String, minutes: Int?, ingredientNames: [String] = [], origin: StepOrigin = .chef,
                    confidence: Confidence = .high, sourceQuote: String = "") {
            self.key = key
            self.text = text
            self.minutes = minutes
            self.ingredientNames = ingredientNames
            self.origin = origin
            self.confidence = confidence
            self.sourceQuote = sourceQuote
        }
    }

    public var title: String
    /// Servings the amounts are for.
    public var yield: Int
    public var ingredients: [Item]
    public var steps: [StepItem]

    public init(title: String, yield: Int, ingredients: [Item], steps: [StepItem]) {
        self.title = title
        self.yield = max(1, yield)
        self.ingredients = ingredients
        self.steps = steps
    }

    /// Takes a saved recipe as it is now (keys = positions in the sorted lists).
    public init(_ recipe: Recipe) {
        self.init(
            title: recipe.title,
            yield: recipe.yield,
            ingredients: recipe.sortedIngredients.enumerated().map { index, i in
                Item(key: index, name: i.name, quantity: i.quantity, unit: i.unit, note: i.note, group: i.group,
                     fdcID: i.fdcID, foodDescription: i.foodDescription, matchStatus: i.matchStatus,
                     confidence: i.confidence, sourceQuote: i.sourceQuote, reviewed: i.reviewed)
            },
            steps: recipe.sortedSteps.enumerated().map { index, s in
                StepItem(key: index, text: s.text, minutes: s.minutes, ingredientNames: s.ingredientNames,
                         origin: s.origin, confidence: s.confidence, sourceQuote: s.sourceQuote)
            }
        )
    }
}

// MARK: - Validated edits

public struct IngredientEdit: Codable, Sendable, Equatable {
    public var name: String
    public var quantity: Double?
    public var unit: CanonicalUnit
    public var note: String
    public var group: String
    /// Food match for a new or renamed ingredient (filled in by the app before the proposal is shown).
    public var fdcID: Int?
    public var foodDescription: String?
    public var matchStatus: MatchStatus?

    public init(name: String, quantity: Double?, unit: CanonicalUnit, note: String = "", group: String = "",
                fdcID: Int? = nil, foodDescription: String? = nil, matchStatus: MatchStatus? = nil) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.note = note
        self.group = group
        self.fdcID = fdcID
        self.foodDescription = foodDescription
        self.matchStatus = matchStatus
    }
}

public enum ChefChange: Codable, Sendable, Equatable {
    case addIngredient(IngredientEdit)
    /// `key` is the ingredient's position when proposed; `oldName` finds it again if the list changed.
    case changeIngredient(key: Int, oldName: String, IngredientEdit)
    case removeIngredient(key: Int, oldName: String)
    /// Inserted after step number `after` (0 = first).
    case addStep(after: Int, text: String, minutes: Int?)
    case changeStep(key: Int, oldText: String, text: String, minutes: Int?)
    case removeStep(key: Int, oldText: String)
    case rename(String)
    case setYield(Int)

    /// True when the edit needs a food match before it can be previewed or applied.
    public var needsFoodMatch: Bool {
        switch self {
        case .addIngredient(let edit): edit.fdcID == nil && edit.matchStatus == nil
        case .changeIngredient(_, let oldName, let edit):
            edit.matchStatus == nil && TextMatching.normalize(oldName) != TextMatching.normalize(edit.name)
        default: false
        }
    }
}

/// The chef's proposed edits, with a line of text for each.
public struct ChefProposal: Codable, Sendable, Equatable {
    public var changes: [ChefChange]
    public var lines: [String]
    /// Edits the model wrote that couldn't be used (shown in Diagnostics, not to the user).
    public var dropped: [String]

    public init(changes: [ChefChange], lines: [String], dropped: [String] = []) {
        self.changes = changes
        self.lines = lines
        self.dropped = dropped
    }

    public var isEmpty: Bool { changes.isEmpty }
}

/// One turn of the conversation, for the prompt.
public struct ChefTurn: Sendable, Equatable {
    public enum Role: String, Sendable { case user, chef }
    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

// MARK: - Prompts, validation, applying

public enum Chef {

    public static let actions = ["add_ingredient", "change_ingredient", "remove_ingredient", "add_step",
                                 "change_step", "remove_step", "rename_recipe", "set_servings"]

    public static let instructions = """
    You are a friendly, expert home cook helping the user make one recipe taste great. You talk about \
    the recipe and, when useful, propose concrete edits that the user can apply with one tap.
    Rules:
    - reply: short and practical (2 to 5 sentences), in English. Explain the why in a few words (balance, \
    acidity, texture, browning, seasoning, timing).
    - changes: only when the user asks for a change or it clearly serves what they asked. Change only what \
    is needed and keep everything else. For a plain question, changes is empty.
    - Never state calorie or macro numbers. The app calculates them from its food database and shows them \
    under your reply.
    - Amounts are for the recipe's servings shown in the recipe. Prefer metric (g, ml); spoons for small \
    amounts. unit is one of: g, kg, ml, l, tsp, tbsp, cup, piece, clove, slice, pinch, to_taste.
    - Refer to existing ingredients by id (i1, i2…) and steps by id (s1, s2…) in target.
    - Actions:
      add_ingredient: name, quantity, unit, note, group (a part of the recipe that exists, or empty).
      change_ingredient: target and the full new name, quantity, unit, note, group.
      remove_ingredient: target.
      add_step: position (the step number it comes after, 0 for first), text, minutes (0 if none).
      change_step: target and the full new text, minutes.
      remove_step: target.
      rename_recipe: text.
      set_servings: quantity (whole number).
      Unused fields: empty string or 0.
    - When an ingredient or the method changes, update the steps that mention it so the recipe stays \
    consistent. Steps are short imperative sentences.
    - Keep food safe: never suggest undercooking poultry, pork or eggs, or unsafe storage.
    """

    /// Builds the prompt: the recipe, macros the app calculated, recent conversation, the new message.
    /// Older turns are dropped first to stay under `maxCharacters` (small on-device context window).
    public static func prompt(recipe: ChefRecipe, macros: String?, history: [ChefTurn], message: String,
                              maxCharacters: Int = 60_000) -> String {
        var head = "Recipe: \(recipe.title.isEmpty ? "Untitled" : recipe.title) — amounts for \(recipe.yield) serving\(recipe.yield == 1 ? "" : "s")\n"
        head += "Ingredients:\n"
        for (index, item) in recipe.ingredients.enumerated() {
            var line = "i\(index + 1). "
            if !item.group.isEmpty { line += "[\(item.group)] " }
            if let quantity = item.quantity, item.unit != .toTaste {
                line += "\(format(quantity)) \(item.unit == .piece ? "" : item.unit.rawValue + " ")"
            } else if item.unit == .toTaste {
                line += "to taste: "
            }
            line += item.name
            if !item.note.isEmpty { line += " (\(item.note))" }
            head += line + "\n"
        }
        head += recipe.steps.isEmpty ? "Steps: none yet\n" : "Steps:\n"
        for (index, step) in recipe.steps.enumerated() {
            head += "s\(index + 1). \(step.text)\(step.minutes.map { " [\($0) min]" } ?? "")\n"
        }
        if let macros { head += "Per serving (calculated by the app): \(macros)\n" }
        let tail = "\nUser: \(message)"

        var turns: [String] = []
        var used = head.count + tail.count + 40
        for turn in history.reversed() {
            let line = "\(turn.role == .user ? "User" : "Chef"): \(turn.text)"
            guard used + line.count + 1 <= maxCharacters else { break }
            turns.insert(line, at: 0)
            used += line.count + 1
        }
        let conversation = turns.isEmpty ? "" : "\nConversation so far:\n" + turns.joined(separator: "\n") + "\n"
        return head + conversation + tail
    }

    /// Turns the model's edits into checked changes. Unknown actions, missing targets and empty
    /// names are dropped; quantities must be ≥ 0; steps must have text.
    public static func validate(_ raws: [RawChefChange], recipe: ChefRecipe) -> ChefProposal {
        var changes: [ChefChange] = []
        var lines: [String] = []
        var dropped: [String] = []
        let groups = Set(recipe.ingredients.map(\.group).filter { !$0.isEmpty })

        func ingredientIndex(_ target: String) -> Int? {
            index(target, prefix: "i", count: recipe.ingredients.count)
                ?? recipe.ingredients.firstIndex { TextMatching.normalize($0.name) == TextMatching.normalize(target) }
        }
        func stepIndex(_ target: String) -> Int? {
            index(target, prefix: "s", count: recipe.steps.count)
        }
        func makeEdit(_ raw: RawChefChange) -> IngredientEdit? {
            let name = raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, raw.quantity >= 0, raw.quantity < 100_000 else { return nil }
            var unit = CanonicalUnit(rawValue: raw.unit.lowercased()) ?? CanonicalUnit.parse(raw.unit) ?? .piece
            var quantity: Double? = raw.quantity > 0 ? raw.quantity : nil
            if unit == .toTaste { quantity = nil }
            if quantity == nil && unit != .toTaste && raw.unit.isEmpty { unit = .toTaste }
            let group = raw.group.trimmingCharacters(in: .whitespaces)
            return IngredientEdit(name: name, quantity: quantity, unit: unit,
                                  note: raw.note.trimmingCharacters(in: .whitespaces),
                                  group: groups.contains(group) ? group : matchingGroup(group, in: groups))
        }

        for raw in raws {
            let action = raw.action.lowercased().trimmingCharacters(in: .whitespaces)
            switch action {
            case "add_ingredient":
                guard let edit = makeEdit(raw) else { dropped.append("add: no name/amount"); continue }
                changes.append(.addIngredient(edit))
                lines.append("Add \(describe(edit))")
            case "change_ingredient":
                guard let index = ingredientIndex(raw.target), let edit = makeEdit(raw) else {
                    dropped.append("change \(raw.target): unknown"); continue
                }
                let old = recipe.ingredients[index]
                let oldItem = IngredientEdit(name: old.name, quantity: old.quantity, unit: old.unit, note: old.note, group: old.group)
                guard oldItem.name != edit.name || oldItem.quantity != edit.quantity || oldItem.unit != edit.unit
                        || oldItem.note != edit.note || oldItem.group != edit.group else { continue }
                changes.append(.changeIngredient(key: index, oldName: old.name, edit))
                lines.append("Change \(describe(oldItem, showGroup: false)) → \(describe(edit, sameNameAs: old.name))")
            case "remove_ingredient":
                guard let index = ingredientIndex(raw.target) else { dropped.append("remove \(raw.target): unknown"); continue }
                let old = recipe.ingredients[index]
                changes.append(.removeIngredient(key: index, oldName: old.name))
                lines.append("Remove \(old.name)")
            case "add_step":
                let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { dropped.append("add_step: no text"); continue }
                let after = min(max(0, raw.position), recipe.steps.count)
                changes.append(.addStep(after: after, text: text, minutes: raw.minutes > 0 ? raw.minutes : nil))
                lines.append(after == 0 ? "New first step: \(text)" : "New step after step \(after): \(text)")
            case "change_step":
                let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let index = stepIndex(raw.target), !text.isEmpty else { dropped.append("change_step \(raw.target): unknown"); continue }
                let old = recipe.steps[index]
                let minutes = raw.minutes > 0 ? raw.minutes : nil
                guard old.text != text || old.minutes != minutes else { continue }
                changes.append(.changeStep(key: index, oldText: old.text, text: text, minutes: minutes))
                lines.append("Step \(index + 1): \(text)")
            case "remove_step":
                guard let index = stepIndex(raw.target) else { dropped.append("remove_step \(raw.target): unknown"); continue }
                changes.append(.removeStep(key: index, oldText: recipe.steps[index].text))
                lines.append("Remove step \(index + 1)")
            case "rename_recipe":
                let text = (raw.text.isEmpty ? raw.name : raw.text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text != recipe.title else { continue }
                changes.append(.rename(text))
                lines.append("Rename to “\(text)”")
            case "set_servings":
                let servings = Int(raw.quantity.rounded())
                guard (1...100).contains(servings), servings != recipe.yield else { continue }
                changes.append(.setYield(servings))
                lines.append("Recipe makes \(servings) serving\(servings == 1 ? "" : "s") (amounts as written)")
            default:
                dropped.append("unknown action \(raw.action)")
            }
        }
        return ChefProposal(changes: changes, lines: lines, dropped: dropped)
    }

    /// Applies changes to a copy of the recipe. Targets are found by their key, or by name/text when
    /// the recipe changed after the proposal; edits whose target is gone are skipped.
    public static func apply(_ changes: [ChefChange], to recipe: ChefRecipe) -> ChefRecipe {
        var result = recipe
        let originalIngredientKeys = recipe.ingredients.map(\.key)
        let originalStepKeys = recipe.steps.map(\.key)

        func ingredientPosition(key: Int, name: String) -> Int? {
            if key < originalIngredientKeys.count, let k = originalIngredientKeys[key],
               let position = result.ingredients.firstIndex(where: { $0.key == k }),
               TextMatching.normalize(result.ingredients[position].name) == TextMatching.normalize(name) {
                return position
            }
            return result.ingredients.firstIndex { TextMatching.normalize($0.name) == TextMatching.normalize(name) }
        }
        func stepPosition(key: Int, text: String) -> Int? {
            if key < originalStepKeys.count, let k = originalStepKeys[key],
               let position = result.steps.firstIndex(where: { $0.key == k }), result.steps[position].text == text {
                return position
            }
            return result.steps.firstIndex { $0.text == text }
        }

        // Step insertions refer to the original numbering: remember the step each one follows.
        var insertions: [(anchorKey: Int?, item: ChefRecipe.StepItem)] = []
        for change in changes {
            switch change {
            case .addIngredient(let edit):
                result.ingredients.append(item(from: edit, key: nil, keeping: nil))
            case .changeIngredient(let key, let oldName, let edit):
                guard let position = ingredientPosition(key: key, name: oldName) else { continue }
                result.ingredients[position] = item(from: edit, key: result.ingredients[position].key,
                                                    keeping: result.ingredients[position])
            case .removeIngredient(let key, let oldName):
                guard let position = ingredientPosition(key: key, name: oldName) else { continue }
                result.ingredients.remove(at: position)
            case .addStep(let after, let text, let minutes):
                let anchorKey: Int? = after > 0 && after <= recipe.steps.count ? (recipe.steps[after - 1].key ?? -1) : nil
                let names = mentionedIngredients(in: text, recipe: result)
                insertions.append((anchorKey, ChefRecipe.StepItem(key: nil, text: text, minutes: minutes, ingredientNames: names)))
            case .changeStep(let key, let oldText, let text, let minutes):
                guard let position = stepPosition(key: key, text: oldText) else { continue }
                result.steps[position].text = text
                result.steps[position].minutes = minutes
                result.steps[position].origin = .chef
                result.steps[position].confidence = .high
                result.steps[position].ingredientNames = mentionedIngredients(in: text, recipe: result)
            case .removeStep(let key, let oldText):
                guard let position = stepPosition(key: key, text: oldText) else { continue }
                result.steps.remove(at: position)
            case .rename(let title):
                result.title = title
            case .setYield(let servings):
                result.yield = servings
            }
        }
        // Insert new steps after their anchor (or at the start); several after one anchor keep their order.
        var placed: [Int: Int] = [:]          // anchor key → steps already inserted after it
        let start = Int.min
        for insertion in insertions {
            let position: Int
            if let anchorKey = insertion.anchorKey {
                if let index = result.steps.firstIndex(where: { $0.key == anchorKey }) {
                    position = index + 1 + placed[anchorKey, default: 0]
                } else {
                    position = result.steps.count            // the step it followed was removed
                }
                placed[anchorKey, default: 0] += 1
            } else {
                position = placed[start, default: 0]
                placed[start, default: 0] += 1
            }
            result.steps.insert(insertion.item, at: min(position, result.steps.count))
        }
        return result
    }

    // MARK: - Helpers

    static func index(_ target: String, prefix: Character, count: Int) -> Int? {
        let t = target.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.first == prefix, let number = Int(t.dropFirst()), (1...count).contains(number) else { return nil }
        return number - 1
    }

    static func matchingGroup(_ group: String, in groups: Set<String>) -> String {
        let key = IngredientGroups.key(group)
        guard !key.isEmpty else { return "" }
        return groups.first { IngredientGroups.key($0) == key } ?? ""
    }

    static func item(from edit: IngredientEdit, key: Int?, keeping old: ChefRecipe.Item?) -> ChefRecipe.Item {
        let renamed = old.map { TextMatching.normalize($0.name) != TextMatching.normalize(edit.name) } ?? true
        let fdcID = renamed || edit.matchStatus != nil ? edit.fdcID : old?.fdcID
        let description = renamed || edit.matchStatus != nil ? edit.foodDescription : old?.foodDescription
        let status = renamed || edit.matchStatus != nil ? (edit.matchStatus ?? .unmatched) : (old?.matchStatus ?? .unmatched)
        return ChefRecipe.Item(key: key, name: edit.name, quantity: edit.quantity, unit: edit.unit, note: edit.note,
                               group: edit.group, fdcID: fdcID, foodDescription: description, matchStatus: status,
                               confidence: .high, sourceQuote: renamed ? "" : (old?.sourceQuote ?? ""),
                               reviewed: true, changedByChef: true)
    }

    static func mentionedIngredients(in text: String, recipe: ChefRecipe) -> [String] {
        let words = Set(TextMatching.tokens(text))
        return IngredientGroups.uniqueNames(recipe.ingredients.map(\.name).filter { name in
            let main = TextMatching.tokens(name).filter { $0.count >= 4 }
            return !main.isEmpty && main.contains { word in words.contains(word) || words.contains(word + "s") }
        })
    }

    static func describe(_ edit: IngredientEdit, sameNameAs oldName: String? = nil, showGroup: Bool = true) -> String {
        var amount = ""
        if edit.unit == .toTaste {
            amount = "to taste"
        } else if let quantity = edit.quantity {
            amount = "\(format(quantity)) \(unitText(edit.unit, quantity: quantity))".trimmingCharacters(in: .whitespaces)
        }
        let name = oldName.map { TextMatching.normalize($0) == TextMatching.normalize(edit.name) } == true && !amount.isEmpty
            ? "" : edit.name
        var text = [amount, name].filter { !$0.isEmpty }.joined(separator: " ")
        if !edit.note.isEmpty { text += " (\(edit.note))" }
        if showGroup, !edit.group.isEmpty, oldName == nil { text += " — \(edit.group)" }
        return text
    }

    static func unitText(_ unit: CanonicalUnit, quantity: Double) -> String {
        switch unit {
        case .piece: ""
        case .clove, .slice, .cup, .pinch: quantity == 1 ? unit.rawValue : unit.rawValue + (unit == .pinch ? "es" : "s")
        default: unit.rawValue
        }
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", (value * 100).rounded() / 100)
    }
}
