import Foundation
import Testing
@testable import RecipeCore

struct FakeKeyFrames: KeyFrameProviding {
    var times: [Double]
    func keyFrames(videoURL: URL, maxFrames: Int) async throws -> [KeyFrame] {
        times.prefix(maxFrames).map { KeyFrame(time: $0, jpeg: Data([0xFF, 0xD8, 0xFF])) }
    }
}

struct FakeVisual: VisualStepExtracting {
    var method: RawVisualMethod
    func extractStepsFromFrames(_ frames: [KeyFrame], sourceText: String, ingredientNames: [String]) async throws -> RawVisualMethod {
        method
    }
}

/// Records how many picks run at the same time.
final class ConcurrencyProbe: FoodMatching, @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private(set) var peak = 0

    private func enter() { lock.lock(); running += 1; peak = max(peak, running); lock.unlock() }
    private func leave() { lock.lock(); running -= 1; lock.unlock() }

    func pickFood(ingredient: String, detail: String, candidates: [FoodCandidate]) async throws -> FoodPick {
        enter()
        try await Task.sleep(for: .milliseconds(50))
        leave()
        return FoodPick(index: 0, rawOutput: "1. \(candidates[0].description)")
    }
}

/// The potato-bread Reel: no speech, only the title on screen, method only visible in the pictures.
private let potatoBread = SourceTimeline(
    caption: "Cheesy Garlic Potato Stuffed Bread\n600 g russet potatoes (boiled and mashed)\n150 g all-purpose flour\n1 large egg\n120 g mozzarella cheese (shredded)",
    spoken: [],
    onScreen: [OCRLine(time: 0, text: "cheesy garlic", confidence: 1), OCRLine(time: 0, text: "Potato Bread", confidence: 1)]
)

@Suite("Steps from the video's pictures")
struct VideoPicturesTests {

    @Test func visualStepsMustCiteRealFramesAndStatedTimes() {
        let method = RawVisualMethod(hasInstructions: true, steps: [
            RawVisualStep(text: "Add the flour to the mashed potatoes.", ingredientsUsed: ["all-purpose flour", "russet potato"], frameTimes: [7.3]),
            RawVisualStep(text: "Crack in the egg and mix into a dough.", ingredientsUsed: ["egg"], frameTimes: [10.0, 10.4], confidence: "high"),
            RawVisualStep(text: "Bake at 200°C for 20 minutes.", frameTimes: [99]),                     // no such frame
            RawVisualStep(text: "Fry until golden on both sides, about 4 minutes.", frameTimes: [18.5], minutes: 4)
        ])
        let checked = ExtractionPostProcessor.visualSteps(method, frameTimes: [0.5, 7.3, 10.4, 18.6],
                                                          sourceText: potatoBread.plainText,
                                                          ingredientNames: ["russet potato", "all-purpose flour", "egg"])
        #expect(checked.steps.map(\.text) == [
            "Add the flour to the mashed potatoes.",
            "Crack in the egg and mix into a dough.",
            "Fry until golden on both sides, about 4 minutes."
        ])
        #expect(checked.steps.allSatisfy { $0.fromPictures == true })
        #expect(checked.steps[1].confidence == .medium)          // capped: pictures can't be "high"
        #expect(checked.steps[2].minutes == nil)                  // 4 minutes was never stated
        #expect(checked.steps[2].confidence == .low)
        #expect(checked.steps[0].sourceQuote == "Seen at 0:07")
        #expect(checked.dropped.contains { $0.contains("cites no real frame") })
    }

    @Test func statedDurations() {
        #expect(ExtractionPostProcessor.statedDurations(in: "Bake 20-25 minutes, rest 1 hour, simmer for ten minutes") == [20, 25, 60, 10])
        #expect(ExtractionPostProcessor.statedDurations(in: "2 tsp baking powder, 600 g potatoes").isEmpty)
    }

    @Test func pipelineLooksAtPicturesOnlyWhenTextHasNoMethod() async throws {
        let extractor = MockExtractor(
            recipe: RawRecipe(title: "Cheesy Garlic Potato Stuffed Bread", servings: 0, ingredients: [
                RawIngredient(name: "russet potato", quantity: 600, unit: "g"),
                RawIngredient(name: "egg", quantity: 1, unit: "piece")
            ]),
            method: RawMethod(hasInstructions: false, steps: [])
        )
        let visual = FakeVisual(method: RawVisualMethod(hasInstructions: true, steps: [
            RawVisualStep(text: "Mash the potatoes in a bowl.", ingredientsUsed: ["russet potato"], frameTimes: [6.5]),
            RawVisualStep(text: "Fry the filled discs until golden on both sides.", frameTimes: [18.6])
        ], rawOutput: "{}"))
        let pipeline = PipelineCoordinator(transcriber: NoMedia(), ocr: NoMedia(), extractor: extractor, matcher: nil,
                                           database: nil, aiStatus: "cloud", visual: visual,
                                           keyFrames: FakeKeyFrames(times: [0.5, 6.5, 12.1, 18.6]))
        let report = await pipeline.run(videoURL: URL(filePath: "/tmp/none.mov"), caption: potatoBread.caption,
                                        itemID: nil, rememberedMatches: [:], update: { _ in })
        let outcome = try #require(report.outcome)
        #expect(outcome.steps.count == 2)
        #expect(outcome.hasInstructions)
        #expect(outcome.steps.allSatisfy { $0.fromPictures == true })
        #expect(report.keyFrameTimes == [0.5, 6.5, 12.1, 18.6])
    }

    @Test func textMethodWinsAndPicturesAreSkipped() async throws {
        let extractor = MockExtractor(
            recipe: RawRecipe(title: "Oats", servings: 1, ingredients: [RawIngredient(name: "oats", quantity: 80, unit: "g")]),
            method: RawMethod(hasInstructions: true, steps: [RawStep(sourceQuote: "stir it", text: "Stir well.")])
        )
        let visual = FakeVisual(method: RawVisualMethod(hasInstructions: true, steps: [RawVisualStep(text: "Should not appear", frameTimes: [1])]))
        let pipeline = PipelineCoordinator(transcriber: NoMedia(), ocr: NoMedia(), extractor: extractor, matcher: nil,
                                           database: nil, aiStatus: "cloud", visual: visual, keyFrames: FakeKeyFrames(times: [1]))
        let report = await pipeline.run(videoURL: URL(filePath: "/tmp/none.mov"), caption: "80g oats\nstir it",
                                        itemID: nil, rememberedMatches: [:], update: { _ in })
        #expect(report.outcome?.steps.map(\.text) == ["Stir well."])
        #expect(report.keyFrameTimes == nil)
    }
}

@Suite("Key frame selection")
struct KeyFrameSelectorTests {

    @Test func picksBiggestChangesInOrder() {
        //            0    1     2     3    4     5     6     7    8     9
        let diffs = [0, 0.01, 0.30, 0.02, 0.01, 0.50, 0.01, 0.02, 0.4, 0.01]
        #expect(KeyFrameSelector.select(differences: diffs, maxFrames: 4, minimumGapSamples: 2) == [0, 2, 5, 8])
    }

    @Test func fillsEvenlyWhenFewCuts() {
        let diffs = [Double](repeating: 0.01, count: 40)
        let picked = KeyFrameSelector.select(differences: diffs, maxFrames: 5, minimumGapSamples: 2)
        #expect(picked.first == 0)
        #expect(picked.count >= 4)
        #expect(picked == picked.sorted())
    }

    @Test func shortVideoKeepsEverything() {
        #expect(KeyFrameSelector.select(differences: [0, 0.2, 0.3], maxFrames: 12) == [0, 1, 2])
        #expect(KeyFrameSelector.select(differences: [], maxFrames: 12).isEmpty)
    }

    @Test func thumbnailDifference() {
        #expect(KeyFrameSelector.difference([0, 0, 0, 0], [0, 0, 0, 0]) == 0)
        #expect(KeyFrameSelector.difference([0, 0], [255, 255]) == 1)
    }
}

@Suite("Pipeline fixes")
struct PipelineFixTests {

    @Test func garbledTitleOverlaysAreDropped() {
        let frames = [
            OCRFrame(time: 0, lines: [.init(text: "cheesy garlic", confidence: 0.9), .init(text: "Potato Bread", confidence: 0.9)]),
            OCRFrame(time: 12, lines: [.init(text: "cheesy gartio,", confidence: 0.6), .init(text: "Potato", confidence: 0.6), .init(text: "Bread", confidence: 0.6)]),
            OCRFrame(time: 15, lines: [.init(text: "cho sy garuc", confidence: 0.5), .init(text: "Parato Bread", confidence: 0.5)]),
            OCRFrame(time: 19, lines: [.init(text: "Potato Bredi", confidence: 0.5)])
        ]
        #expect(OCRDeduper.merge(frames).map(\.text) == ["cheesy garlic", "Potato Bread"])
    }

    @Test func differentInstructionsAreKept() {
        let frames = [
            OCRFrame(time: 1, lines: [.init(text: "mix the flour", confidence: 1), .init(text: "preheat oven", confidence: 1)]),
            OCRFrame(time: 5, lines: [.init(text: "mix the sugar", confidence: 1), .init(text: "preheat grill", confidence: 1),
                                     .init(text: "1 tsp salt", confidence: 1), .init(text: "1 tsp sugar", confidence: 1)])
        ]
        #expect(OCRDeduper.merge(frames).count == 6)
    }

    @Test func matchesRunInParallelAndKeepOrder() async {
        let probe = ConcurrencyProbe()
        let jobs = (0..<10).map { i in
            PipelineCoordinator.MatchJob(index: i, name: "item \(i)", detail: "",
                                         candidates: [FoodCandidate(fdcID: i, description: "Food \(i)")])
        }
        let results = await PipelineCoordinator.runMatches(jobs, matcher: probe, concurrency: 5, progress: { _ in })
        #expect(results.count == 10)
        for (i, result) in results.enumerated() {
            if case .success(let pick) = result { #expect(pick.rawOutput == "1. Food \(i)") } else { Issue.record("job \(i) failed") }
        }
        #expect(probe.peak > 1)
        #expect(probe.peak <= 5)
    }

    @Test func wordGroupingForFallbackRecognizer() {
        let words: [(String, Double, Double)] = [("Season", 1.0, 0.4), ("the", 1.4, 0.1), ("salmon", 1.5, 0.4), ("then", 3.0, 0.2), ("sear", 3.2, 0.3)]
        let segments = SpeechTranscriptionService.group(words: words)
        #expect(segments.map(\.text) == ["Season the salmon", "then sear"])
        #expect(segments[1].start == 3.0)
    }
}

@Suite("Cloud images")
struct CloudImageRequestTests {

    @Test func anthropicSendsImageBlocks() throws {
        let blocks = AnthropicBackend.blocks([.text("Frame at 1.0 s:"), .jpeg(Data([1, 2, 3]))])
        #expect(blocks[0]["type"] as? String == "text")
        let source = blocks[1]["source"] as? [String: Any]
        #expect(blocks[1]["type"] as? String == "image")
        #expect(source?["media_type"] as? String == "image/jpeg")
        #expect(source?["data"] as? String == Data([1, 2, 3]).base64EncodedString())
    }

    @Test func openAISendsImageURLParts() throws {
        #expect(OpenAICompatibleBackend.userContent([.text("hi")]) as? String == "hi")
        let parts = try #require(OpenAICompatibleBackend.userContent([.text("a"), .jpeg(Data([9]))]) as? [[String: Any]])
        #expect(parts[1]["type"] as? String == "image_url")
        let url = (parts[1]["image_url"] as? [String: Any])?["url"] as? String
        #expect(url == "data:image/jpeg;base64," + Data([9]).base64EncodedString())
    }

    @Test func visualRequestCarriesFramesAndSchema() async throws {
        let answer = #"{"hasInstructions":true,"steps":[{"text":"Mash the potatoes.","ingredientsUsed":["russet potato"],"frameTimes":[6.5],"minutes":0,"confidence":"medium"}]}"#
        let escaped = String(String(data: try JSONSerialization.data(withJSONObject: [answer]), encoding: .utf8)!.dropFirst().dropLast())
        let transport = FakeTransport([(200, #"{"content":[{"type":"text","text":\#(escaped)}],"stop_reason":"end_turn","usage":{"input_tokens":5000,"output_tokens":200}}"#)])
        let extractor = try CloudExtractor(config: CloudConfig(provider: .anthropic, model: "m", baseURL: "", apiKey: "k"), transport: transport)
        let method = try await extractor.extractStepsFromFrames(
            [KeyFrame(time: 6.5, jpeg: Data([1])), KeyFrame(time: 9.0, jpeg: Data([2]))],
            sourceText: "CAPTION: 600 g russet potatoes", ingredientNames: ["russet potato"]
        )
        #expect(method.steps.first?.frameTimes == [6.5])
        let httpBody = try #require(transport.requests.first?.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let content = try #require(((body["messages"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]])
        #expect(content.filter { $0["type"] as? String == "image" }.count == 2)
        #expect((content[1]["text"] as? String) == "Frame at 6.5 s:")
    }
}
