import Foundation
import Testing
@testable import RecipeCore

@Suite("TextMatching")
struct TextMatchingTests {

    @Test func normalizeFoldsCaseAccentsAndPunctuation() {
        #expect(TextMatching.normalize("  Sauté the Jalapeño, then STIR!  ") == "saute the jalapeno then stir")
        #expect(TextMatching.normalize("1/2 red pepper") == "1/2 red pepper")
    }

    @Test func quoteFoundEvenWithSmallDifferences() {
        let source = "Season two salmon fillets, about six ounces each, with salt and pepper. Sear them skin side down in a tablespoon of olive oil."
        #expect(TextMatching.quoteAppears("Sear them skin side down in a tablespoon of olive oil", in: source))
        #expect(TextMatching.quoteAppears("sear them skin-side down", in: source))
    }

    @Test func inventedQuoteIsRejected() {
        let source = "200g chicken breast\n1 tbsp soy sauce\n100g broccoli"
        #expect(!TextMatching.quoteAppears("Stir-fry the chicken in a hot wok for 5 minutes", in: source))
        #expect(!TextMatching.quoteAppears("", in: source))
    }

    @Test func bagOfWordsIsNotEnough() {
        // Same words, scrambled order: no word pair matches.
        let source = "add the milk then stir the oats"
        #expect(!TextMatching.quoteAppears("oats stir then milk add", in: source))
    }
}

@Suite("OCRDeduper")
struct OCRDeduperTests {

    @Test func mergesRepeatsAndNearDuplicatesKeepingFirstTime() {
        let frames = [
            OCRFrame(time: 1, lines: [.init(text: "200g chicken breast", confidence: 0.9)]),
            OCRFrame(time: 2, lines: [.init(text: "200g chicken breast", confidence: 0.9), .init(text: "1 tbsp soy sauce", confidence: 0.8)]),
            OCRFrame(time: 3, lines: [.init(text: "200g chicken breas", confidence: 0.7), .init(text: "@foodcreator", confidence: 0.9)]),
            OCRFrame(time: 4, lines: [.init(text: "#mealprep #easy", confidence: 0.9), .init(text: "x", confidence: 0.9)]),
            OCRFrame(time: 5, lines: [.init(text: "1 tsp sesame oil", confidence: 0.1)])
        ]
        let lines = OCRDeduper.merge(frames)
        #expect(lines.map(\.text) == ["200g chicken breast", "1 tbsp soy sauce"])
        #expect(lines.map(\.time) == [1, 2])
    }

    @Test func listShownTwiceIsKeptOnce() {
        let frames = [
            OCRFrame(time: 0, lines: [.init(text: "100g broccoli", confidence: 1)]),
            OCRFrame(time: 30, lines: [.init(text: "100g broccoli", confidence: 1)])
        ]
        #expect(OCRDeduper.merge(frames).count == 1)
    }
}

@Suite("SourceTimeline")
struct SourceTimelineTests {

    @Test func captionFirstThenTimeOrderedScreenAndVoice() {
        let timeline = SourceTimeline(
            caption: "Oats\n\n80g oats",
            spoken: [TranscriptSegment(start: 2, end: 3, text: "stir it"), TranscriptSegment(start: 65, end: 66, text: "done")],
            onScreen: [OCRLine(time: 2, text: "80g oats", confidence: 1), OCRLine(time: 1, text: "TITLE", confidence: 1)]
        )
        #expect(timeline.lines == [
            "CAPTION: Oats",
            "CAPTION: 80g oats",
            "[0:01] SCREEN: TITLE",
            "[0:02] SCREEN: 80g oats",
            "[0:02] VOICE: stir it",
            "[1:05] VOICE: done"
        ])
    }

    @Test func chunksRespectLimitAndOrder() {
        let lines = (1...50).map { "line number \($0) with some words" }
        let chunks = SourceTimeline.chunk(lines: lines, maxCharacters: 200)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 200 })
        #expect(chunks.joined(separator: "\n") == lines.joined(separator: "\n"))
    }

    @Test func overlongLineIsSplitOnWords() {
        let long = Array(repeating: "word", count: 100).joined(separator: " ")
        let chunks = SourceTimeline.chunk(lines: [long], maxCharacters: 60)
        #expect(chunks.allSatisfy { $0.count <= 60 })
        #expect(chunks.joined(separator: " ") == long)
    }

    @Test func emptyTimeline() {
        #expect(SourceTimeline(caption: "  ", spoken: [], onScreen: []).isEmpty)
    }
}

@Suite("CanonicalUnit")
struct CanonicalUnitTests {
    @Test func parsesCommonSpellings() {
        #expect(CanonicalUnit.parse("Tablespoons") == .tbsp)
        #expect(CanonicalUnit.parse("tsp.") == .tsp)
        #expect(CanonicalUnit.parse("grams") == .g)
        #expect(CanonicalUnit.parse("cloves") == .clove)
        #expect(CanonicalUnit.parse("to taste") == .toTaste)
        #expect(CanonicalUnit(rawValue: "to_taste") == .toTaste)
        #expect(CanonicalUnit.parse("handful") == nil)
    }
}
