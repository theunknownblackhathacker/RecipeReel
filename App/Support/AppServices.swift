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
                aiStatus: "Apple Intelligence \(aiAvailability.shortLabel)"
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
                matchConcurrency: 5               // food picks in parallel
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
            return amount == "?" ? ingredient.name : "\(amount) \(ingredient.name)"
        }
        AppLog.shared.log("suggest", "Suggesting steps for “\(recipe.title)” (\(lines.count) ingredients) with \(engineLabel)")
        let suggester: any StepSuggesting = ai.engine == .cloud ? try ai.makeCloudExtractor() : FoundationModelsExtractor()
        let raws = try await suggester.suggestSteps(title: recipe.title, ingredients: lines)
        let steps = ExtractionPostProcessor.cleanSuggestedSteps(raws, ingredientNames: ingredients.map(\.name))
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

    func food(id: Int?) -> FoodRecord? {
        guard let id else { return nil }
        return database?.food(id: id)
    }
}
