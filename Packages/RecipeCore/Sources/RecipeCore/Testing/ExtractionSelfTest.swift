import Foundation

/// The synthetic cases from recipe-test-cases.md, runnable on the iPhone against the real model
/// (Diagnostics → AI self-test) and with mocks in CI.
public struct ExtractionTestCase: Sendable, Identifiable {
    public struct ExpectedIngredient: Sendable {
        /// Words that must all appear in the extracted name (e.g. ["salmon"]).
        public var keywords: [String]
        public var quantity: Double?
        public var unit: CanonicalUnit

        public init(_ keywords: [String], _ quantity: Double?, _ unit: CanonicalUnit) {
            self.keywords = keywords
            self.quantity = quantity
            self.unit = unit
        }
    }

    public var id: String { name }
    public var name: String
    public var timeline: SourceTimeline
    public var servings: Int?
    public var ingredients: [ExpectedIngredient]
    /// Allowed number of steps (Case 3 must be exactly 0).
    public var stepCount: ClosedRange<Int>
}

public struct SelfTestCheck: Sendable, Codable {
    public var passed: Bool
    public var message: String
}

public struct SelfTestResult: Sendable {
    public var caseName: String
    public var checks: [SelfTestCheck]
    public var report: AnalysisReport

    public init(caseName: String, checks: [SelfTestCheck], report: AnalysisReport) {
        self.caseName = caseName
        self.checks = checks
        self.report = report
    }

    public var passed: Bool { checks.allSatisfy(\.passed) }
    public var summary: String { "\(passed ? "PASS" : "FAIL") \(caseName): \(checks.filter(\.passed).count)/\(checks.count) checks" }
}

public enum ExtractionSelfTest {

    public static let cases: [ExtractionTestCase] = [
        ExtractionTestCase(
            name: "Case 1 — caption has the full list",
            timeline: SourceTimeline(
                caption: """
                High-protein overnight oats 🥣 (2 servings)
                80g rolled oats
                250ml milk
                150g Greek yogurt 2%
                1 scoop (30g) vanilla whey
                1 tbsp chia seeds
                1 tsp honey
                #mealprep #highprotein #breakfast
                """,
                spoken: [TranscriptSegment(start: 1, end: 9, text: "Okay so oats in the jar, milk, yogurt, protein powder, chia, little bit of honey, stir it, fridge overnight, done. Super easy.")],
                onScreen: [OCRLine(time: 0.5, text: "PROTEIN OATS", confidence: 1), OCRLine(time: 2, text: "38g protein per jar", confidence: 1)]
            ),
            servings: 2,
            ingredients: [
                .init(["oat"], 80, .g), .init(["milk"], 250, .ml), .init(["yogurt"], 150, .g),
                .init(["whey"], 30, .g), .init(["chia"], 1, .tbsp), .init(["honey"], 1, .tsp)
            ],
            stepCount: 2...4
        ),
        ExtractionTestCase(
            name: "Case 2 — voiceover only, vague amounts, US units",
            timeline: SourceTimeline(
                caption: "15 minute garlic butter salmon 🔥 save this for later!",
                spoken: [
                    TranscriptSegment(start: 1, end: 5, text: "Season two salmon fillets, about six ounces each, with salt and pepper."),
                    TranscriptSegment(start: 5, end: 10, text: "Sear them skin side down in a tablespoon of olive oil. Flip, then add a big knob of butter, three cloves of garlic, and a squeeze of lemon. Baste for a minute."),
                    TranscriptSegment(start: 10, end: 13, text: "Serve it over a cup of cooked rice. Feeds two.")
                ],
                onScreen: []
            ),
            servings: 2,
            ingredients: [
                .init(["salmon"], 12, .oz), .init(["olive", "oil"], 1, .tbsp), .init(["butter"], 1, .tbsp),
                .init(["garlic"], 3, .clove), .init(["lemon"], 1, .tbsp), .init(["rice"], 1, .cup),
                .init(["salt"], nil, .toTaste), .init(["pepper"], nil, .toTaste)
            ],
            stepCount: 3...6
        ),
        ExtractionTestCase(
            name: "Case 3 — on-screen text only (must have 0 steps)",
            timeline: SourceTimeline(
                caption: "Recipe below 👇 (it's in the video)",
                spoken: [],
                onScreen: [
                    OCRLine(time: 1, text: "200g chicken breast", confidence: 1),
                    OCRLine(time: 2, text: "200g chicken breast", confidence: 1),
                    OCRLine(time: 3, text: "1 tbsp soy sauce", confidence: 1),
                    OCRLine(time: 4, text: "1 tsp sesame oil", confidence: 1),
                    OCRLine(time: 5, text: "1 tsp sesame oil", confidence: 1),
                    OCRLine(time: 6, text: "100g broccoli", confidence: 1),
                    OCRLine(time: 7, text: "1/2 red pepper", confidence: 1),
                    OCRLine(time: 8, text: "125g cooked basmati", confidence: 1),
                    OCRLine(time: 9, text: "1 tsp sriracha (optional)", confidence: 1),
                    OCRLine(time: 10, text: "SERVES 1", confidence: 1)
                ]
            ),
            servings: 1,
            ingredients: [
                .init(["chicken"], 200, .g), .init(["soy"], 1, .tbsp), .init(["sesame"], 1, .tsp),
                .init(["broccoli"], 100, .g), .init(["pepper"], 0.5, .piece), .init(["basmati"], 125, .g),
                .init(["sriracha"], 1, .tsp)
            ],
            stepCount: 0...0
        )
    ]

    /// Compares an outcome against a case's expectations.
    public static func evaluate(_ testCase: ExtractionTestCase, outcome: ExtractionOutcome?) -> [SelfTestCheck] {
        guard let outcome else { return [SelfTestCheck(passed: false, message: "No result (see errors)")] }
        var checks: [SelfTestCheck] = []

        checks.append(SelfTestCheck(
            passed: outcome.servings == testCase.servings,
            message: "servings \(outcome.servings.map(String.init) ?? "nil") (expected \(testCase.servings.map(String.init) ?? "nil"))"
        ))

        var unmatched = outcome.ingredients
        for expected in testCase.ingredients {
            guard let index = unmatched.firstIndex(where: { draft in
                let name = TextMatching.normalize(draft.name)
                return expected.keywords.allSatisfy { name.contains($0) }
            }) else {
                checks.append(SelfTestCheck(passed: false, message: "missing ingredient \(expected.keywords.joined(separator: " "))"))
                continue
            }
            let found = unmatched.remove(at: index)
            let ok = amountsMatch(found, expected)
            checks.append(SelfTestCheck(
                passed: ok,
                message: "\(found.name): \(found.quantity.map { String(format: "%g", $0) } ?? "nil") \(found.unit.rawValue) (expected \(expected.quantity.map { String(format: "%g", $0) } ?? "nil") \(expected.unit.rawValue))"
            ))
        }
        checks.append(SelfTestCheck(
            passed: unmatched.count <= 1,
            message: unmatched.isEmpty ? "no extra ingredients" : "extra ingredients: \(unmatched.map(\.name).joined(separator: ", "))"
        ))

        checks.append(SelfTestCheck(
            passed: testCase.stepCount.contains(outcome.steps.count),
            message: "\(outcome.steps.count) steps (expected \(testCase.stepCount.lowerBound)…\(testCase.stepCount.upperBound))"
        ))
        let timedSteps = outcome.steps.filter { $0.minutes != nil }
        if testCase.name.hasPrefix("Case 2") {
            checks.append(SelfTestCheck(
                passed: timedSteps.allSatisfy { $0.minutes == 1 },
                message: "only 'baste for a minute' may have a time: \(timedSteps.map { "\($0.minutes ?? 0) min" })"
            ))
        }
        return checks
    }

    static func amountsMatch(_ found: IngredientDraft, _ expected: ExtractionTestCase.ExpectedIngredient) -> Bool {
        guard let want = expected.quantity else { return found.quantity == nil }
        guard let got = found.quantity else { return false }
        if found.unit == expected.unit { return abs(got - want) <= max(0.1, want * 0.1) }
        // Equivalent mass/volume amounts in another unit count too (e.g. 340 g vs 12 oz).
        let a = UnitConverter.grams(quantity: got, unit: found.unit, portions: [])
        let b = UnitConverter.grams(quantity: want, unit: expected.unit, portions: [])
        guard let ga = a.grams, let gb = b.grams, a.method != .notCounted, b.method != .notCounted else { return false }
        return abs(ga - gb) <= gb * 0.1
    }
}
