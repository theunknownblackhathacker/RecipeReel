import PhotosUI
import SwiftData
import SwiftUI
import RecipeCore

/// Home screen: saved recipes, imports waiting to become recipes, and ways to add more.
struct ImportView: View {
    @Environment(ImportModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \Recipe.createdAt, order: .reverse) private var recipes: [Recipe]
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingCaptionSheet = false

    var body: some View {
        @Bindable var model = model
        List {
            if !recipes.isEmpty {
                Section("Recipes") {
                    ForEach(recipes) { recipe in
                        NavigationLink {
                            RecipeView(recipe: recipe)
                        } label: {
                            RecipeRow(recipe: recipe)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { context.delete(recipes[index]) }
                        try? context.save()
                    }
                }
            }

            Section {
                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    Label("Choose a video", systemImage: "video.badge.plus")
                }
                Button {
                    showingCaptionSheet = true
                } label: {
                    Label("Paste a caption", systemImage: "doc.on.clipboard")
                }
            } header: {
                Text("Add a recipe")
            } footer: {
                Text("You can also share a video to RecipeReel from Photos or Files, or use “Open in RecipeReel”.")
            }

            if !model.shared.isAvailable {
                Section {
                    Label {
                        Text("Sharing from other apps can't hand videos to RecipeReel on this install (no App Group). Use “Choose a video” or Open in instead.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                if model.items.isEmpty {
                    Text("Nothing imported yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.items) { item in
                        NavigationLink(value: item.id) {
                            ImportRow(item: item, hasRecipe: recipes.contains { $0.sourceItemID == item.id })
                        }
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { model.items[$0] }
                        doomed.forEach(model.delete)
                    }
                }
            } header: {
                Text("Imports")
            } footer: {
                Text("Open an import and tap Make recipe.")
            }
        }
        .navigationTitle("RecipeReel")
        .navigationDestination(for: UUID.self) { id in
            ItemDetailView(itemID: id)
        }
        .refreshable { model.collectSharedInbox() }
        .overlay {
            if let message = model.busyMessage {
                ProgressView(message)
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await model.importPicked(newItem)
                pickerItem = nil
            }
        }
        .sheet(isPresented: $showingCaptionSheet) {
            CaptionEditorSheet(title: "Paste caption", initialText: "") { text in
                model.addCaptionOnly(text)
            }
        }
        .alert("Something went wrong", isPresented: $model.showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct RecipeRow: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recipe.title)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("\(recipe.ingredients.count) ingredients · \(recipe.steps.count) steps")
                if recipe.flaggedCount > 0 {
                    Label("\(recipe.flaggedCount) to review", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct ImportRow: View {
    let item: InboxItem
    var hasRecipe = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasRecipe {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Recipe made")
            }
        }
    }

    private var subtitle: String {
        var parts = [item.origin.displayName, item.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let size = item.sizeText { parts.append(size) }
        return parts.joined(separator: " · ")
    }
}
