import Foundation
import Observation
import RecipeCore

/// App-wide services: the bundled nutrition database, the user's remembered food matches,
/// and pipeline construction.
@MainActor
@Observable
final class AppServices {
    let database: FDCDatabase?
    let databaseProblem: String?
    let databaseInfo: [String: String]
    private(set) var aiAvailability: AIAvailability
    /// AI engine choice and the user's own API keys.
    let ai = AISettings()
    /// The user's own foods (from labels, barcodes and Open Food Facts).
    let customFoods = CustomFoodStore(fileURL: AppPaths.customFoodsURL)
    let openFoodFacts = OpenFoodFactsClient()
    /// Look up still-unmatched ingredients on Open Food Facts while making a recipe.
    var onlineLookup: Bool = UserDefaults.standard.object(forKey: "food.onlineLookup") as? Bool ?? true {
        didSet { UserDefaults.standard.set(onlineLookup, forKey: "food.onlineLookup") }
    }
    /// Summary of the last in-app AI self-test, included in exported logs.
    var lastSelfTestLog: [String] = []

    private static let matchMemoryKey = "matchMemory"

    init() {
        if let url = Bundle.main.url(forResource: "fdc", withExtension: "sqlite") {
            do {
                let db = try FDCDatabase(url: url)
                database = db
                databaseProblem = nil
                databaseInfo = db.metadata()
            } catch {
                database = nil
                databaseProblem = error.localizedDescription
                databaseInfo = [:]
            }
        } else {
            database = nil
            databaseProblem = "fdc.sqlite is missing from the app. Run the “Build FDC database” workflow."
            databaseInfo = [:]
        }
        aiAvailability = AIAvailability.current()
        AppLog.shared.log("services", "AI: \(engineLabel); Apple Intelligence \(aiAvailability.shortLabel); nutrition DB: \(databaseProblem ?? "\(databaseInfo["food_count"] ?? "?") foods")")
    }

    func refreshAvailability() {
        aiAvailability = AIAvailability.current()
    }

    // MARK: - Remembered matches (ingredient name → fdc_id), set when the user corrects a match

    var rememberedMatches: [String: Int] {
        (UserDefaults.standard.dictionary(forKey: Self.matchMemoryKey) as? [String: Int]) ?? [:]
    }

    func remember(fdcID: Int, for ingredientName: String) {
        var memory = rememberedMatches
        memory[TextMatching.normalize(ingredientName)] = fdcID
        UserDefaults.standard.set(memory, forKey: Self.matchMemoryKey)
        AppLog.shared.log("match", "Remembered \(ingredientName) → \(fdcID)")
    }

    func forgetAllMatches() {
        UserDefaults.standard.removeObject(forKey: Self.matchMemoryKey)
    }

    // MARK: - Pipeline

    // MARK: - Engine status

    /// What's doing the extraction right now (for logs and Diagnostics; never includes a key).
    var engineLabel: String {
        switch ai.engine {
        case .onDevice: "Apple Intelligence"
        case .cloud: "My API: \(ai.cloudLabel)"
        }
    }

    /// Nil when extraction can run; otherwise a message for the user.
    var extractionProblem: String? {
        switch ai.engine {
        case .onDevice:
            return aiAvailability.isAvailable ? nil : aiAvailability.message
        case .cloud:
            if ai.hasKey[ai.provider] != true { return "Add your API key in Settings → AI, or switch back to Apple Intelligence." }
            if ai.model.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose a model in Settings → AI." }
            return nil
        }
    }

    func makePipeline() -> PipelineCoordinator {
        refreshAvailability()
        switch ai.engine {
        case .onDevice:
            let model: FoundationModelsExtractor? = aiAvailability.isAvailable ? FoundationModelsExtractor() : nil
            return PipelineCoordinator(
                transcriber: SpeechTranscriptionService(),
                ocr: VisionFrameOCRService(),
                extractor: model,
                matcher: model,
                database: database,
                aiStatus: "Apple Intelligence \(aiAvailability.shortLabel)",
                customFoods: customFoods,
                onlineFoods: onlineLookup ? openFoodFacts : nil
            )
        case .cloud:
            let cloud: CloudExtractor?
            var status = engineLabel
            do {
                cloud = try ai.makeCloudExtractor()
            } catch {
                cloud = nil
                status += " — \(error.localizedDescription)"
            }
            return PipelineCoordinator(
                transcriber: SpeechTranscriptionService(),
                ocr: VisionFrameOCRService(),
                extractor: cloud,
                matcher: cloud,
                database: database,
                aiStatus: status,
                maxChunkCharacters: 60_000,       // cloud models have large context windows
                visual: cloud,                    // look at key frames when no text describes the method
                keyFrames: VideoKeyFrameProvider(),
                matchConcurrency: 5,              // food picks in parallel
                customFoods: customFoods,
                onlineFoods: onlineLookup ? openFoodFacts : nil
            )
        }
    }

    /// Asks the on-device model for a suggested method (used only when the user taps "Suggest steps").
    func suggestSteps(for recipe: Recipe) async throws -> [StepDraft] {
        refreshAvailability()
        if let problem = extractionProblem { throw SuggestError.unavailable(problem) }
        let ingredients = recipe.sortedIngredients
        let lines = ingredients.map { ingredient -> String in
            let amount = RecipeMath.amountText(quantity: ingredient.quantity, unit: ingredient.unit)
            let line = amount == "?" ? ingredient.name : "\(amount) \(ingredient.name)"
            return ingredient.group.isEmpty ? line : "\(line) (for the \(ingredient.group.lowercased()))"
        }
        AppLog.shared.log("suggest", "Suggesting steps for “\(recipe.title)” (\(lines.count) ingredients) with \(engineLabel)")
        let suggester: any StepSuggesting = ai.engine == .cloud ? try ai.makeCloudExtractor() : FoundationModelsExtractor()
        let raws = try await suggester.suggestSteps(title: recipe.title, ingredients: lines)
        let steps = ExtractionPostProcessor.cleanSuggestedSteps(raws, ingredientNames: IngredientGroups.uniqueNames(ingredients.map(\.name)))
        AppLog.shared.log("suggest", "Got \(raws.count) raw / \(steps.count) kept: " + steps.map(\.text).joined(separator: " | "))
        return steps
    }

    enum SuggestError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let message): message
            }
        }
    }

    // MARK: - Ask the chef

    struct ChefAnswer {
        let reply: String
        let proposal: ChefProposal
        /// "Per serving: 571 → 498 kcal …" (empty when nothing would change).
        let preview: String
    }

    /// One turn of a recipe's chef conversation with the chosen engine. Proposed edits are checked,
    /// new ingredients get a food match, and the macros before/after are worked out here.
    func askChef(recipe: Recipe, history: [ChefTurn], message: String) async throws -> ChefAnswer {
        refreshAvailability()
        if let problem = extractionProblem { throw SuggestError.unavailable(problem) }
        let snapshot = ChefRecipe(recipe)
        let before = Chef.perServing(snapshot) { self.food(id: $0) }
        let onDevice = ai.engine == .onDevice
        let chef: any RecipeChefing = onDevice ? FoundationModelsExtractor() : try ai.makeCloudExtractor()
        // The on-device model has a small context window (about 4,096 tokens).
        let limit = onDevice ? 6_000 : 60_000
        AppLog.shared.log("chef", "Asking \(engineLabel) about “\(recipe.title)”: \(message.prefix(200))")
        let raw: RawChefReply
        do {
            raw = try await chef.chef(instructions: Chef.instructions,
                                      prompt: Chef.prompt(recipe: snapshot, macros: Chef.macroLine(before), history: history,
                                                          message: message, maxCharacters: limit))
        } catch let error where onDevice && !history.isEmpty {
            AppLog.shared.log("chef", "Retrying without earlier messages: \(error.localizedDescription)")
            raw = try await chef.chef(instructions: Chef.instructions,
                                      prompt: Chef.prompt(recipe: snapshot, macros: Chef.macroLine(before), history: [],
                                                          message: message, maxCharacters: limit))
        }
        var proposal = Chef.validate(raw.changes, recipe: snapshot)
        for index in proposal.changes.indices where proposal.changes[index].needsFoodMatch {
            switch proposal.changes[index] {
            case .addIngredient(var edit):
                await fillMatch(&edit)
                proposal.changes[index] = .addIngredient(edit)
            case .changeIngredient(let key, let oldName, var edit):
                await fillMatch(&edit)
                proposal.changes[index] = .changeIngredient(key: key, oldName: oldName, edit)
            default:
                break
            }
        }
        let after = Chef.perServing(Chef.apply(proposal.changes, to: snapshot)) { self.food(id: $0) }
        let preview = proposal.isEmpty ? "" : Chef.previewLine(before: before, after: after)
        AppLog.shared.log("chef", "Reply: \(raw.changes.count) edits proposed, \(proposal.changes.count) kept" +
                          (proposal.dropped.isEmpty ? "" : " (dropped: \(proposal.dropped.joined(separator: "; ")))") +
                          ". Raw: \(raw.rawOutput.prefix(1500))")
        return ChefAnswer(reply: raw.reply, proposal: proposal, preview: preview)
    }

    private func fillMatch(_ edit: inout IngredientEdit) async {
        let match = await matchFood(name: edit.name, note: edit.note)
        edit.fdcID = match.id
        edit.foodDescription = match.description
        edit.matchStatus = match.status
    }

    /// Food match for one ingredient name: remembered choice → My foods → database search, with the AI
    /// picking among the database candidates when the engine is available (first candidate otherwise).
    func matchFood(name: String, note: String) async -> (id: Int?, description: String?, status: MatchStatus) {
        if let id = rememberedMatches[TextMatching.normalize(name)], let food = food(id: id) {
            return (id, food.description, .remembered)
        }
        if let custom = customFoods.matching(ingredientName: name).first {
            return (custom.id, custom.record.description, .custom)
        }
        guard let database else { return (nil, nil, .unmatched) }
        let candidates = database.search(ingredientName: name, note: note, limit: 10)
        guard !candidates.isEmpty else { return (nil, nil, .unmatched) }
        var pick = 0
        if extractionProblem == nil {
            let matcher: (any FoodMatching)? = ai.engine == .cloud ? try? ai.makeCloudExtractor() : FoundationModelsExtractor()
            if let matcher, let result = try? await matcher.pickFood(ingredient: name, detail: note, candidates: candidates) {
                guard let index = result.index, candidates.indices.contains(index) else { return (nil, nil, .unmatched) }
                pick = index
            }
        }
        return (candidates[pick].fdcID, candidates[pick].description, .matched)
    }

    func food(id: Int?) -> FoodRecord? {
        guard let id else { return nil }
        if id < 0 { return customFoods.food(id: id)?.record }
        return database?.food(id: id)
    }
}
