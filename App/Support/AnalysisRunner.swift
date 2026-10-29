import Foundation
import Observation
import SwiftData
import RecipeCore

/// Runs the pipeline for one imported item and turns the result into a saved Recipe.
@MainActor
@Observable
final class AnalysisRunner {
    private(set) var isRunning = false
    private(set) var stage: PipelineStage?
    private(set) var detail = ""
    private(set) var completedStages: Set<PipelineStage> = []
    private(set) var lastReport: AnalysisReport?
    var errorMessage: String?

    var showingError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    static let reportFileName = "analysis.json"

    func run(item: InboxItem, importModel: ImportModel, services: AppServices, context: ModelContext) async -> Recipe? {
        guard !isRunning else { return nil }
        isRunning = true
        completedStages = []
        stage = nil
        detail = ""
        defer {
            isRunning = false
            stage = nil
        }

        let log = AppLog.shared
        let pipeline = services.makePipeline()
        log.log("pipeline", "Start \(item.id.uuidString.prefix(8)) (\(item.kind.rawValue)), AI \(services.aiAvailability.shortLabel)")
        let started = Date()

        let videoURL = item.kind == .video ? importModel.videoURL(for: item) : nil
        let report = await pipeline.run(
            videoURL: videoURL,
            caption: item.caption,
            itemID: item.id,
            rememberedMatches: services.rememberedMatches
        ) { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
        lastReport = report
        importModel.saveReport(report, for: item)

        let timings = report.timings.map { "\($0.stage) \(String(format: "%.1f", $0.seconds))s" }.joined(separator: ", ")
        log.log("pipeline", "Done in \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(timings)")
        for error in report.errors { log.log("pipeline", "Error: \(error)") }

        guard let outcome = report.outcome else {
            errorMessage = report.errors.first ?? "Nothing could be extracted."
            return nil
        }
        if outcome.ingredients.isEmpty && outcome.steps.isEmpty {
            errorMessage = "No ingredients or steps were found. Check the caption and try again."
            return nil
        }

        // Replace an earlier recipe made from the same item.
        let itemID = item.id
        let existing = (try? context.fetch(FetchDescriptor<Recipe>(predicate: #Predicate<Recipe> { $0.sourceItemID == itemID }))) ?? []
        for old in existing { context.delete(old) }

        let recipe = RecipeFactory.makeRecipe(
            from: outcome,
            sourceItemID: item.id,
            caption: item.caption,
            fallbackTitle: item.title == item.kind.displayName ? "Untitled recipe" : item.title
        )
        context.insert(recipe)
        try? context.save()
        log.log("pipeline", "Saved recipe “\(recipe.title)”: \(recipe.ingredients.count) ingredients, \(recipe.steps.count) steps")
        return recipe
    }

    private func apply(_ update: PipelineUpdate) {
        if let current = stage, current != update.stage {
            completedStages.insert(current)
        }
        stage = update.stage
        detail = update.detail
    }
}
