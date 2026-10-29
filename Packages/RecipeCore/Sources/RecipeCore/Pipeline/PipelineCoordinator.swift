import Foundation

public enum PipelineStage: String, Codable, Sendable, CaseIterable {
    case transcribing, readingText, findingIngredients, matchingFoods, writingSteps, calculating

    public var title: String {
        switch self {
        case .transcribing: "Transcribing"
        case .readingText: "Reading on-screen text"
        case .findingIngredients: "Finding ingredients"
        case .matchingFoods: "Matching foods"
        case .writingSteps: "Writing steps"
        case .calculating: "Calculating"
        }
    }
}

public struct PipelineUpdate: Sendable, Equatable {
    public var stage: PipelineStage
    public var detail: String

    public init(stage: PipelineStage, detail: String = "") {
        self.stage = stage
        self.detail = detail
    }
}

public struct StageTiming: Codable, Sendable, Equatable {
    public var stage: String
    public var seconds: Double
    public var note: String
}

/// Everything about one analysis run, for the Diagnostics screen and exported logs.
public struct AnalysisReport: Codable, Sendable {
    public var createdAt: Date
    public var itemID: UUID?
    public var aiStatus: String
    public var timings: [StageTiming]
    public var timeline: SourceTimeline
    public var chunkCount: Int
    public var rawIngredientOutputs: [String]
    public var rawStepOutputs: [String]
    public var foodMatchLog: [String]
    public var errors: [String]
    public var outcome: ExtractionOutcome?

    public init(itemID: UUID?, aiStatus: String, timeline: SourceTimeline) {
        self.createdAt = Date()
        self.itemID = itemID
        self.aiStatus = aiStatus
        self.timings = []
        self.timeline = timeline
        self.chunkCount = 0
        self.rawIngredientOutputs = []
        self.rawStepOutputs = []
        self.foodMatchLog = []
        self.errors = []
        self.outcome = nil
    }

    /// Human-readable dump for "Export log".
    public var textDump: String {
        var lines: [String] = []
        lines.append("Analysis \(createdAt.formatted(.iso8601)) · AI: \(aiStatus) · chunks: \(chunkCount)")
        lines.append("Timings: " + timings.map { "\($0.stage) \(String(format: "%.1f", $0.seconds))s\($0.note.isEmpty ? "" : " (\($0.note))")" }.joined(separator: ", "))
        if !errors.isEmpty {
            lines.append("Errors:")
            lines += errors.map { "  - \($0)" }
        }
        lines.append("-- Source timeline --")
        lines.append(timeline.text.isEmpty ? "(empty)" : timeline.text)
        lines.append("-- Raw ingredient output --")
        lines += rawIngredientOutputs
        lines.append("-- Raw step output --")
        lines += rawStepOutputs
        lines.append("-- Food matching --")
        lines += foodMatchLog
        if let outcome {
            lines.append("-- Result --")
            lines.append("Title: \(outcome.title) · servings: \(outcome.servings.map(String.init) ?? "not stated") · instructions: \(outcome.hasInstructions)")
            for i in outcome.ingredients {
                lines.append("  • \(i.quantity.map { String(format: "%g", $0) } ?? "–") \(i.unit.rawValue) \(i.name) [\(i.confidence.rawValue)] → \(i.foodDescription ?? "unmatched") (\(i.matchStatus.rawValue))\(i.note.isEmpty ? "" : " note: \(i.note)")")
            }
            for (n, s) in outcome.steps.enumerated() {
                lines.append("  \(n + 1). \(s.text)\(s.minutes.map { " [\($0) min]" } ?? "") [\(s.confidence.rawValue)] uses: \(s.ingredientNames.joined(separator: ", "))")
            }
            if !outcome.droppedSteps.isEmpty {
                lines.append("Dropped/flagged by checks:")
                lines += outcome.droppedSteps.map { "  - \($0)" }
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Runs the whole on-device pipeline: transcribe → OCR → ingredients (pass A) → food matching →
/// steps (pass B). Each stage is independent: a failure is recorded and the next stage still runs,
/// so macros work even when steps fail.
public actor PipelineCoordinator {
    private let transcriber: any TranscriptionService
    private let ocr: any FrameOCRService
    private let extractor: (any RecipeExtracting)?
    private let matcher: (any FoodMatching)?
    private let database: FDCDatabase?
    private let aiStatus: String
    private let maxChunkCharacters: Int

    public init(
        transcriber: any TranscriptionService,
        ocr: any FrameOCRService,
        extractor: (any RecipeExtracting)?,
        matcher: (any FoodMatching)?,
        database: FDCDatabase?,
        aiStatus: String,
        maxChunkCharacters: Int = 4_000
    ) {
        self.transcriber = transcriber
        self.ocr = ocr
        self.extractor = extractor
        self.matcher = matcher
        self.database = database
        self.aiStatus = aiStatus
        self.maxChunkCharacters = maxChunkCharacters
    }

    public func run(
        videoURL: URL?,
        caption: String?,
        itemID: UUID?,
        rememberedMatches: [String: Int],
        update: @escaping @Sendable (PipelineUpdate) -> Void
    ) async -> AnalysisReport {
        var report = AnalysisReport(itemID: itemID, aiStatus: aiStatus, timeline: SourceTimeline(caption: caption, spoken: [], onScreen: []))

        if let videoURL {
            update(PipelineUpdate(stage: .transcribing))
            let start = Date()
            do {
                report.timeline.spoken = try await transcriber.transcribe(videoURL: videoURL) { status in
                    update(PipelineUpdate(stage: .transcribing, detail: status))
                }
                report.timings.append(StageTiming(stage: "transcribe", seconds: Date().timeIntervalSince(start),
                                                  note: "\(report.timeline.spoken.count) segments"))
            } catch {
                report.errors.append("Transcription: \(error.localizedDescription)")
                report.timings.append(StageTiming(stage: "transcribe", seconds: Date().timeIntervalSince(start), note: "failed"))
            }

            update(PipelineUpdate(stage: .readingText))
            let ocrStart = Date()
            do {
                report.timeline.onScreen = try await ocr.readText(videoURL: videoURL) { fraction in
                    update(PipelineUpdate(stage: .readingText, detail: "\(Int(fraction * 100))%"))
                }
                report.timings.append(StageTiming(stage: "ocr", seconds: Date().timeIntervalSince(ocrStart),
                                                  note: "\(report.timeline.onScreen.count) lines"))
            } catch {
                report.errors.append("On-screen text: \(error.localizedDescription)")
                report.timings.append(StageTiming(stage: "ocr", seconds: Date().timeIntervalSince(ocrStart), note: "failed"))
            }
        }

        return await extract(into: report, rememberedMatches: rememberedMatches, update: update)
    }

    /// Extraction only (used by `run` and by the in-app self-test with prepared text).
    public func extract(
        into startingReport: AnalysisReport,
        rememberedMatches: [String: Int],
        update: @escaping @Sendable (PipelineUpdate) -> Void
    ) async -> AnalysisReport {
        var report = startingReport
        let timeline = report.timeline
        guard !timeline.isEmpty else {
            report.errors.append("No text found: no speech, no on-screen text and no caption.")
            return report
        }
        guard let extractor else {
            report.errors.append("AI extraction skipped: Apple Intelligence \(aiStatus).")
            return report
        }

        let chunks = timeline.chunks(maxCharacters: maxChunkCharacters)
        report.chunkCount = chunks.count

        // Pass A — ingredients.
        update(PipelineUpdate(stage: .findingIngredients, detail: chunks.count > 1 ? "\(chunks.count) parts" : ""))
        let aStart = Date()
        var raws: [RawRecipe] = []
        for chunk in chunks {
            do {
                let results = try await withSplitRetry(chunk) { try await extractor.extractIngredients(from: $0) }
                raws += results
                report.rawIngredientOutputs += results.map(\.rawOutput)
            } catch {
                report.errors.append("Ingredients: \(error.localizedDescription)")
            }
        }
        let merged = ExtractionPostProcessor.mergeIngredients(raws)
        var ingredients = merged.ingredients
        report.timings.append(StageTiming(stage: "ingredients", seconds: Date().timeIntervalSince(aStart),
                                          note: "\(ingredients.count) found"))

        // Food matching — Swift finds candidates; the model only picks one (or none).
        update(PipelineUpdate(stage: .matchingFoods))
        let mStart = Date()
        if let database {
            for index in ingredients.indices {
                let ingredient = ingredients[index]
                update(PipelineUpdate(stage: .matchingFoods, detail: ingredient.name))
                let key = TextMatching.normalize(ingredient.name)
                if let remembered = rememberedMatches[key], let food = database.food(id: remembered) {
                    ingredients[index].fdcID = food.fdcID
                    ingredients[index].foodDescription = food.description
                    ingredients[index].matchStatus = .remembered
                    report.foodMatchLog.append("\(ingredient.name) → \(food.description) (remembered)")
                    continue
                }
                let candidates = database.search(ingredientName: ingredient.name, limit: 10)
                guard !candidates.isEmpty else {
                    report.foodMatchLog.append("\(ingredient.name) → no candidates (terms: \(FoodSearch.terms(for: ingredient.name).joined(separator: " ")))")
                    continue
                }
                guard let matcher else { continue }
                do {
                    let detail = [ingredient.note, ingredient.quantity.map { "\(String(format: "%g", $0)) \(ingredient.unit.label)" } ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: ", ")
                    let pick = try await matcher.pickFood(ingredient: ingredient.name, detail: detail, candidates: candidates)
                    if let chosen = pick.index {
                        ingredients[index].fdcID = candidates[chosen].fdcID
                        ingredients[index].foodDescription = candidates[chosen].description
                        ingredients[index].matchStatus = .matched
                    }
                    report.foodMatchLog.append("\(ingredient.name) → \(pick.rawOutput) | from: \(candidates.prefix(5).map(\.description).joined(separator: " / "))")
                } catch {
                    report.foodMatchLog.append("\(ingredient.name) → error: \(error.localizedDescription)")
                }
            }
        } else {
            report.errors.append("Nutrition database missing: foods not matched.")
        }
        report.timings.append(StageTiming(stage: "match", seconds: Date().timeIntervalSince(mStart),
                                          note: "\(ingredients.filter { $0.fdcID != nil }.count)/\(ingredients.count) matched"))

        // Pass B — steps (independent of pass A's success).
        update(PipelineUpdate(stage: .writingSteps))
        let bStart = Date()
        let names = ingredients.map(\.name)
        var methods: [RawMethod] = []
        for chunk in chunks {
            do {
                let results = try await withSplitRetry(chunk) { try await extractor.extractSteps(from: $0, ingredientNames: names) }
                methods += results
                report.rawStepOutputs += results.map(\.rawOutput)
            } catch {
                report.errors.append("Steps: \(error.localizedDescription)")
            }
        }
        let steps = ExtractionPostProcessor.mergeSteps(methods, source: timeline, ingredientNames: names)
        report.timings.append(StageTiming(stage: "steps", seconds: Date().timeIntervalSince(bStart),
                                          note: "\(steps.steps.count) kept, \(steps.dropped.count) dropped/flagged"))

        update(PipelineUpdate(stage: .calculating))
        report.outcome = ExtractionOutcome(
            title: merged.title,
            servings: merged.servings,
            ingredients: ingredients,
            steps: steps.steps,
            hasInstructions: steps.hasInstructions,
            droppedSteps: steps.dropped
        )
        return report
    }

    /// Runs `work` on the chunk; if it fails (e.g. context window exceeded) and the chunk is long,
    /// splits it in half and tries each half once.
    private func withSplitRetry<T: Sendable>(
        _ chunk: String,
        _ work: @Sendable (String) async throws -> T
    ) async throws -> [T] {
        do {
            return [try await work(chunk)]
        } catch {
            guard chunk.count > 1_200 else { throw error }
            let halves = SourceTimeline.chunk(lines: chunk.components(separatedBy: "\n"), maxCharacters: chunk.count / 2 + 50)
            var results: [T] = []
            for half in halves {
                results.append(try await work(half))
            }
            return results
        }
    }
}
