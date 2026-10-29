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
        AppLog.shared.log("services", "AI: \(aiAvailability.shortLabel); nutrition DB: \(databaseProblem ?? "\(databaseInfo["food_count"] ?? "?") foods")")
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

    func makePipeline() -> PipelineCoordinator {
        refreshAvailability()
        let ai: FoundationModelsExtractor? = aiAvailability.isAvailable ? FoundationModelsExtractor() : nil
        return PipelineCoordinator(
            transcriber: SpeechTranscriptionService(),
            ocr: VisionFrameOCRService(),
            extractor: ai,
            matcher: ai,
            database: database,
            aiStatus: aiAvailability.shortLabel
        )
    }

    func food(id: Int?) -> FoodRecord? {
        guard let id else { return nil }
        return database?.food(id: id)
    }
}
