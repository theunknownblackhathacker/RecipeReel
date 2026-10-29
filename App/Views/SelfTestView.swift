import SwiftUI
import RecipeCore

/// Runs the recipe-test-cases.md synthetic cases through the real on-device model and checks the
/// results (including Case 3, which must produce zero steps).
struct SelfTestView: View {
    @Environment(AppServices.self) private var services
    @State private var results: [SelfTestResult] = []
    @State private var running = false
    @State private var progress = ""

    var body: some View {
        List {
            Section {
                Button {
                    Task { await run() }
                } label: {
                    if running {
                        HStack {
                            ProgressView()
                            Text(progress)
                        }
                    } else {
                        Label("Run self-test", systemImage: "checklist")
                    }
                }
                .disabled(running || !services.aiAvailability.isAvailable)
                if !services.aiAvailability.isAvailable {
                    Text(services.aiAvailability.message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Uses the three synthetic cases from recipe-test-cases.md. Takes about a minute. Results are included in Export log.")
            }

            ForEach(results, id: \.caseName) { result in
                Section {
                    ForEach(Array(result.checks.enumerated()), id: \.offset) { _, check in
                        Label(check.message, systemImage: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.passed ? Color.primary : Color.red)
                            .font(.footnote)
                    }
                    NavigationLink("Raw output") {
                        ReportTextView(report: result.report)
                    }
                } header: {
                    Text(result.summary)
                        .foregroundStyle(result.passed ? .green : .red)
                }
            }
        }
        .navigationTitle("AI self-test")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() async {
        running = true
        defer { running = false }
        results = []
        let pipeline = services.makePipeline()
        var log: [String] = ["Run \(Date().formatted(.iso8601)) · AI \(services.aiAvailability.shortLabel)"]
        for testCase in ExtractionSelfTest.cases {
            progress = testCase.name
            let start = AnalysisReport(itemID: nil, aiStatus: services.aiAvailability.shortLabel, timeline: testCase.timeline)
            let report = await pipeline.extract(into: start, rememberedMatches: [:], update: { _ in })
            let result = SelfTestResult(
                caseName: testCase.name,
                checks: ExtractionSelfTest.evaluate(testCase, outcome: report.outcome),
                report: report
            )
            results.append(result)
            log.append(result.summary)
            log += result.checks.filter { !$0.passed }.map { "  ✗ \($0.message)" }
            log += report.errors.map { "  error: \($0)" }
            if let outcome = report.outcome {
                log += outcome.steps.enumerated().map { "  step \($0.offset + 1): \($0.element.text)" }
                log += outcome.droppedSteps.map { "  dropped: \($0)" }
            }
        }
        services.lastSelfTestLog = log
        AppLog.shared.log("selftest", results.map(\.summary).joined(separator: " | "))
    }
}
