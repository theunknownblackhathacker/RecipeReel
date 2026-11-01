import Foundation

public enum PipelineStage: String, Codable, Sendable, CaseIterable {
    case transcribing, readingText, findingIngredients, matchingFoods, writingSteps, watchingVideo, calculating

    public var title: String {
        switch self {
        case .transcribing: "Transcribing"
        case .readingText: "Reading on-screen text"
        case .findingIngredients: "Finding ingredients"
        case .matchingFoods: "Matching foods"
        case .writingSteps: "Writing steps"
        case .watchingVideo: "Looking at the video"
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
    /// Speech-recognition details (audio found, permission, model, recognizer used).
    public var transcriptionNotes: [String]?
    /// Times of the key frames sent to the cloud model, and its raw answer.
    public var keyFrameTimes: [Double]?
    public var rawVisualOutput: String?

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
        if let notes = transcriptionNotes, !notes.isEmpty {
            lines.append("Speech: " + notes.joined(separator: " · "))
        }
        lines.append("-- Source timeline --")
        lines.append(timeline.text.isEmpty ? "(empty)" : timeline.text)
        lines.append("-- Raw ingredient output --")
        lines += rawIngredientOutputs
        lines.append("-- Raw step output --")
        lines += rawStepOutputs
        if let times = keyFrameTimes {
            lines.append("-- Video pictures (\(times.count) key frames at \(times.map { String(format: "%.1f", $0) }.joined(separator: ", ")) s) --")
            lines.append(rawVisualOutput ?? "(no answer)")
        }
        lines.append("-- Food matching --")
        lines += foodMatchLog
        if let outcome {
            lines.append("-- Result --")
            lines.append("Title: \(outcome.title) · servings: \(outcome.servings.map(String.init) ?? "not stated") · instructions: \(outcome.hasInstructions)")
            for i in outcome.ingredients {
                lines.append("  • \(i.quantity.map { String(format: "%g", $0) } ?? "–") \(i.unit.rawValue) \(i.name) [\(i.confidence.rawValue)] → \(i.foodDescription ?? "unmatched") (\(i.matchStatus.rawValue))\(i.note.isEmpty ? "" : " note: \(i.note)")")
            }
            for (n, s) in outcome.steps.enumerated() {
                lines.append("  \(n + 1). \(s.text)\(s.minutes.map { " [\($0) min]" } ?? "") [\(s.confidence.rawValue)]\(s.fromPictures == true ? " [\(s.sourceQuote)]" : "") uses: \(s.ingredientNames.joined(separator: ", "))")
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
    private let visual: (any VisualStepExtracting)?
    private let keyFrames: (any KeyFrameProviding)?
    private let matchConcurrency: Int
    private let maxKeyFrames: Int
    private let customFoods: CustomFoodStore?
    private let onlineFoods: (any OnlineFoodSearching)?

    public init(
        transcriber: any TranscriptionService,
        ocr: any FrameOCRService,
        extractor: (any RecipeExtracting)?,
        matcher: (any FoodMatching)?,
        database: FDCDatabase?,
        aiStatus: String,
        maxChunkCharacters: Int = 4_000,
        visual: (any VisualStepExtracting)? = nil,
        keyFrames: (any KeyFrameProviding)? = nil,
        matchConcurrency: Int = 1,
        maxKeyFrames: Int = 12,
        customFoods: CustomFoodStore? = nil,
        onlineFoods: (any OnlineFoodSearching)? = nil
    ) {
        self.transcriber = transcriber
        self.ocr = ocr
        self.extractor = extractor
        self.matcher = matcher
        self.database = database
        self.aiStatus = aiStatus
        self.maxChunkCharacters = maxChunkCharacters
        self.visual = visual
        self.keyFrames = keyFrames
        self.matchConcurrency = max(1, matchConcurrency)
        self.maxKeyFrames = maxKeyFrames
        self.customFoods = customFoods
        self.onlineFoods = onlineFoods
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
            let notes = NoteCollector()
            defer { report.transcriptionNotes = notes.all }
            do {
                report.timeline.spoken = try await transcriber.transcribe(videoURL: videoURL) { status in
                    notes.add(status)
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

        var result = await extract(into: report, rememberedMatches: rememberedMatches, update: update)
        if let videoURL {
            result = await addStepsFromPictures(to: result, videoURL: videoURL, update: update)
        }
        return result
    }

    /// When no text describes the method, a vision-capable cloud model writes steps from key frames.
    private func addStepsFromPictures(
        to startingReport: AnalysisReport,
        videoURL: URL,
        update: @escaping @Sendable (PipelineUpdate) -> Void
    ) async -> AnalysisReport {
        var report = startingReport
        guard let visual, let keyFrames, var outcome = report.outcome, outcome.steps.isEmpty else { return report }
        update(PipelineUpdate(stage: .watchingVideo))
        let start = Date()
        do {
            let frames = try await keyFrames.keyFrames(videoURL: videoURL, maxFrames: maxKeyFrames)
            report.keyFrameTimes = frames.map(\.time)
            guard !frames.isEmpty else {
                report.timings.append(StageTiming(stage: "pictures", seconds: Date().timeIntervalSince(start), note: "no frames"))
                return report
            }
            update(PipelineUpdate(stage: .watchingVideo, detail: "\(frames.count) frames"))
            let names = outcome.ingredients.map(\.name)
            let method = try await visual.extractStepsFromFrames(frames, sourceText: report.timeline.text, ingredientNames: names)
            report.rawVisualOutput = method.rawOutput
            let checked = ExtractionPostProcessor.visualSteps(method, frameTimes: frames.map(\.time),
                                                              sourceText: report.timeline.plainText, ingredientNames: names)
            outcome.steps = checked.steps
            outcome.hasInstructions = !checked.steps.isEmpty
            outcome.droppedSteps += checked.dropped
            report.outcome = outcome
            report.timings.append(StageTiming(stage: "pictures", seconds: Date().timeIntervalSince(start),
                                              note: "\(frames.count) frames, \(checked.steps.count) steps"))
        } catch {
            report.errors.append("Video pictures: \(error.localizedDescription)")
            report.timings.append(StageTiming(stage: "pictures", seconds: Date().timeIntervalSince(start), note: "failed"))
        }
        return report
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
            // Remembered choices and database search first (fast, local).
            var jobs: [MatchJob] = []
            var logLines = [String](repeating: "", count: ingredients.count)
            for index in ingredients.indices {
                let ingredient = ingredients[index]
                let key = TextMatching.normalize(ingredient.name)
                if let remembered = rememberedMatches[key], let food = lookupFood(id: remembered, database: database) {
                    ingredients[index].fdcID = food.fdcID
                    ingredients[index].foodDescription = food.description
                    ingredients[index].matchStatus = .remembered
                    logLines[index] = "\(ingredient.name) → \(food.description) (remembered)"
                    continue
                }
                // The user's own foods first, then USDA (searched with the note too, e.g. "dry weight").
                let own = (customFoods?.matching(ingredientName: ingredient.name) ?? [])
                    .prefix(3).map { FoodCandidate(fdcID: $0.id, description: $0.displayName) }
                let candidates = Array((own + database.search(ingredientName: ingredient.name, note: ingredient.note, limit: 10)).prefix(12))
                guard !candidates.isEmpty else {
                    logLines[index] = "\(ingredient.name) → no candidates (terms: \(FoodSearch.terms(for: ingredient.name).joined(separator: " ")))"
                    continue
                }
                let detail = [ingredient.note, ingredient.quantity.map { "\(String(format: "%g", $0)) \(ingredient.unit.label)" } ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: ", ")
                jobs.append(MatchJob(index: index, name: ingredient.name, detail: detail, candidates: candidates))
            }
            // Model picks — several at once for cloud APIs.
            if let matcher {
                let results = await Self.runMatches(jobs, matcher: matcher, concurrency: matchConcurrency) { name in
                    update(PipelineUpdate(stage: .matchingFoods, detail: name))
                }
                for (job, outcome) in zip(jobs, results) {
                    switch outcome {
                    case .success(let pick):
                        if let chosen = pick.index {
                            let candidate = job.candidates[chosen]
                            ingredients[job.index].fdcID = candidate.fdcID
                            ingredients[job.index].foodDescription = candidate.description
                            ingredients[job.index].matchStatus = candidate.fdcID < 0 ? .custom : .matched
                        }
                        logLines[job.index] = "\(job.name) → \(pick.rawOutput) | from: \(job.candidates.prefix(5).map(\.description).joined(separator: " / "))"
                    case .failure(let error):
                        logLines[job.index] = "\(job.name) → error: \(error.localizedDescription)"
                    }
                }
            }
            report.foodMatchLog += logLines.filter { !$0.isEmpty }
            await lookUpOnline(&ingredients, report: &report, update: update)
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

    private func lookupFood(id: Int, database: FDCDatabase) -> FoodRecord? {
        id < 0 ? customFoods?.food(id: id)?.record : database.food(id: id)
    }

    /// Ingredients still without a match are searched on Open Food Facts; the model picks one result
    /// (or none). Picked products are saved to the user's foods so they're reused next time.
    private func lookUpOnline(
        _ ingredients: inout [IngredientDraft],
        report: inout AnalysisReport,
        update: @escaping @Sendable (PipelineUpdate) -> Void
    ) async {
        guard let onlineFoods, let customFoods, let matcher else { return }
        for index in ingredients.indices {
            let ingredient = ingredients[index]
            guard ingredient.fdcID == nil, ingredient.unit != .toTaste, ingredient.quantity != nil else { continue }
            update(PipelineUpdate(stage: .matchingFoods, detail: "Online: \(ingredient.name)"))
            do {
                let found = try await onlineFoods.search(name: ingredient.name, limit: 8)
                guard !found.isEmpty else {
                    report.foodMatchLog.append("\(ingredient.name) → Open Food Facts: nothing found")
                    continue
                }
                let candidates = found.enumerated().map { FoodCandidate(fdcID: -900_000 - $0.offset, description: $0.element.displayName) }
                let detail = [ingredient.note, ingredient.quantity.map { "\(String(format: "%g", $0)) \(ingredient.unit.label)" } ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: ", ")
                let pick = try await matcher.pickFood(ingredient: ingredient.name, detail: detail, candidates: candidates)
                if let chosen = pick.index {
                    let saved = customFoods.add(found[chosen])
                    ingredients[index].fdcID = saved.id
                    ingredients[index].foodDescription = saved.displayName
                    ingredients[index].matchStatus = .openFoodFacts
                }
                report.foodMatchLog.append("\(ingredient.name) → Open Food Facts: \(pick.rawOutput) | from: \(found.prefix(5).map(\.displayName).joined(separator: " / "))")
            } catch {
                report.foodMatchLog.append("\(ingredient.name) → Open Food Facts error: \(error.localizedDescription)")
            }
        }
    }

    struct MatchJob: Sendable {
        let index: Int
        let name: String
        let detail: String
        let candidates: [FoodCandidate]
    }

    /// Runs food picks with at most `concurrency` in flight; results come back in job order.
    static func runMatches(
        _ jobs: [MatchJob],
        matcher: any FoodMatching,
        concurrency: Int,
        progress: @escaping @Sendable (String) -> Void
    ) async -> [Result<FoodPick, any Error>] {
        var results = [Result<FoodPick, any Error>?](repeating: nil, count: jobs.count)
        await withTaskGroup(of: (Int, Result<FoodPick, any Error>).self) { group in
            var positions = jobs.indices.makeIterator()
            for _ in 0..<min(concurrency, jobs.count) {
                if let position = positions.next() {
                    let job = jobs[position]
                    group.addTask { await Self.pick(job, position: position, matcher: matcher, progress: progress) }
                }
            }
            for await (position, result) in group {
                results[position] = result
                if let nextPosition = positions.next() {
                    let job = jobs[nextPosition]
                    group.addTask { await Self.pick(job, position: nextPosition, matcher: matcher, progress: progress) }
                }
            }
        }
        return results.map { $0 ?? .failure(CancellationError()) }
    }

    private static func pick(
        _ job: MatchJob,
        position: Int,
        matcher: any FoodMatching,
        progress: @Sendable (String) -> Void
    ) async -> (Int, Result<FoodPick, any Error>) {
        progress(job.name)
        do {
            return (position, .success(try await matcher.pickFood(ingredient: job.name, detail: job.detail, candidates: job.candidates)))
        } catch {
            return (position, .failure(error))
        }
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

/// Thread-safe list of status messages from the transcriber.
final class NoteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [String] = []

    func add(_ note: String) {
        lock.lock()
        defer { lock.unlock() }
        if notes.last != note { notes.append(note) }
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return notes
    }
}
