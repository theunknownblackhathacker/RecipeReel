import AVKit
import SwiftData
import SwiftUI
import RecipeCore

struct ItemDetailView: View {
    @Environment(ImportModel.self) private var model
    let itemID: UUID

    var body: some View {
        if let item = model.items.first(where: { $0.id == itemID }) {
            ItemDetailContent(item: item)
        } else {
            ContentUnavailableView("Item removed", systemImage: "trash")
        }
    }
}

private struct ItemDetailContent: View {
    @Environment(ImportModel.self) private var model
    @Environment(AppServices.self) private var services
    @Environment(AnalysisRunner.self) private var runner
    @Environment(\.modelContext) private var context
    @Query private var recipes: [Recipe]

    let item: InboxItem
    @State private var player: AVPlayer?
    @State private var editingCaption = false
    @State private var openedRecipe: Recipe?
    @State private var report: AnalysisReport?

    init(item: InboxItem) {
        self.item = item
        let id = item.id
        _recipes = Query(filter: #Predicate<Recipe> { $0.sourceItemID == id })
    }

    var body: some View {
        @Bindable var runner = runner
        List {
            switch item.kind {
            case .video:
                Section {
                    VideoPlayer(player: player)
                        .frame(height: 340)
                        .listRowInsets(EdgeInsets())
                }
            case .linkOnly:
                Section {
                    LinkOnlyHelpView(link: item.sourceLink)
                }
            case .captionOnly:
                EmptyView()
            }

            recipeSection

            Section {
                if let caption = item.caption {
                    Text(caption)
                        .textSelection(.enabled)
                        .lineLimit(12)
                } else {
                    Text("No caption yet. Many creators list ingredients and steps in the caption — paste it before making the recipe.")
                        .foregroundStyle(.secondary)
                }
                Button(item.caption == nil ? "Add caption" : "Edit caption") {
                    editingCaption = true
                }
            } header: {
                Text("Caption")
            }

            if let report {
                Section("Last analysis") {
                    LabeledContent("Speech", value: "\(report.timeline.spoken.count) segments")
                    LabeledContent("On-screen text", value: "\(report.timeline.onScreen.count) lines")
                    if !report.errors.isEmpty {
                        ForEach(report.errors, id: \.self) { error in
                            Text(error).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    NavigationLink("Show source text & AI output") {
                        ReportTextView(report: report)
                    }
                }
            }

            Section("Details") {
                LabeledContent("Type", value: item.kind.displayName)
                LabeledContent("Came from", value: item.origin.displayName)
                LabeledContent("Added", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let size = item.sizeText {
                    LabeledContent("Size", value: size)
                }
            }
        }
        .navigationTitle(item.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openedRecipe) { recipe in
            RecipeView(recipe: recipe)
        }
        .onAppear {
            if player == nil, let url = model.videoURL(for: item) {
                player = AVPlayer(url: url)
            }
            report = model.report(for: item)
        }
        .onDisappear { player?.pause() }
        .sheet(isPresented: $editingCaption) {
            CaptionEditorSheet(title: "Caption", initialText: item.caption ?? "") { text in
                model.updateCaption(text, for: item)
            }
        }
        .alert("Couldn't make a recipe", isPresented: $runner.showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(runner.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var recipeSection: some View {
        Section {
            if !services.aiAvailability.isAvailable {
                Label(services.aiAvailability.message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if runner.isRunning {
                ForEach(stages, id: \.self) { stage in
                    HStack {
                        if runner.completedStages.contains(stage) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if runner.stage == stage {
                            ProgressView()
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                        Text(stage.title)
                        Spacer()
                        if runner.stage == stage, !runner.detail.isEmpty {
                            Text(runner.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                if let recipe = recipes.first {
                    Button {
                        openedRecipe = recipe
                    } label: {
                        Label("Open recipe", systemImage: "fork.knife")
                    }
                }
                Button {
                    Task { await makeRecipe() }
                } label: {
                    Label(recipes.isEmpty ? "Make recipe" : "Make recipe again", systemImage: "wand.and.stars")
                }
            }
        } header: {
            Text("Recipe")
        } footer: {
            if !runner.isRunning {
                Text(item.kind == .video
                     ? "Transcribes the audio, reads on-screen text, then extracts ingredients and steps on this iPhone. Takes about a minute."
                     : "Uses the caption only.")
            }
        }
    }

    private var stages: [PipelineStage] {
        item.kind == .video ? PipelineStage.allCases : PipelineStage.allCases.filter { $0 != .transcribing && $0 != .readingText }
    }

    private func makeRecipe() async {
        player?.pause()
        let recipe = await runner.run(item: item, importModel: model, services: services, context: context)
        report = model.report(for: item)
        if let recipe { openedRecipe = recipe }
    }
}

/// Full text of an analysis: source timeline, raw model output, matching log.
struct ReportTextView: View {
    let report: AnalysisReport

    var body: some View {
        ScrollView {
            Text(report.textDump)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: report.textDump) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}
