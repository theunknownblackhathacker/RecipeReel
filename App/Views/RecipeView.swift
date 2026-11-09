import SwiftData
import SwiftUI
import RecipeCore

/// The recipe: title + servings → macro card → ingredients → numbered steps.
/// Macros are computed from the ingredients every time, so any edit recalculates instantly.
struct RecipeView: View {
    @Bindable var recipe: Recipe
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var foods: [Int: FoodRecord] = [:]
    @State private var perServing = true
    @State private var reviewOnly = false
    @State private var editingIngredient: Ingredient?
    @State private var addingIngredient = false
    @State private var editingSteps = false
    @State private var cooking = false
    @State private var confirmDelete = false
    @State private var findingOnline = false
    @State private var suggesting = false
    @State private var confirmReplace: StepSource?
    @State private var stepError: String?
    @State private var chatting = false

    enum StepSource: Identifiable {
        case suggest, web
        var id: Self { self }
    }

    var body: some View {
        let ingredients = recipe.sortedIngredients
        let factor = recipe.scaleFactor
        let lines = ingredients.map { nutrition(for: $0, factor: factor) }
        let summary = NutritionCalculator.summarize(lines, servings: recipe.servings)

        List {
            Section {
                TextField("Recipe name", text: $recipe.title, axis: .vertical)
                    .font(.title2.bold())
                Stepper(value: yieldBinding, in: 1...50) {
                    Text("Recipe makes \(recipe.yield) serving\(recipe.yield == 1 ? "" : "s")")
                }
                if !recipe.servingsStated {
                    Text("The video didn't say how many servings the amounts make — set it here.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Stepper(value: servingsBinding, in: 1...100) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cooking for \(recipe.servings)")
                        if recipe.servings != recipe.yield {
                            Text("Amounts × \(RecipeMath.quantityText((factor * 100).rounded() / 100))")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                    }
                }
                if recipe.servings != recipe.yield {
                    Button("Back to \(recipe.yield) serving\(recipe.yield == 1 ? "" : "s")") {
                        recipe.servings = recipe.yield
                    }
                    .font(.footnote)
                }
            }

            Section {
                MacroCard(summary: summary, perServing: $perServing)
            }

            if recipe.flaggedCount > 0 {
                Section {
                    Toggle(isOn: $reviewOnly) {
                        Label("\(recipe.flaggedCount) item\(recipe.flaggedCount == 1 ? "" : "s") to review", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Highlighted lines have a low-confidence amount, no nutrition match, or a weak conversion. Tap one to fix it.")
                }
            }

            // One section per part of the recipe ("Chicken", "Alfredo sauce"…), or a single
            // "Ingredients" section when the recipe has no parts.
            let rows = ingredients.enumerated().map { IngredientLine(ingredient: $0.element, nutrition: lines[$0.offset]) }
            let groups = IngredientGroup.make(rows) { $0.ingredient.group }
            let hasParts = groups.count > 1 || groups.first.map { !$0.title.isEmpty } == true
            if groups.isEmpty {
                Section("Ingredients") {
                    Button {
                        addingIngredient = true
                    } label: {
                        Label("Add ingredient", systemImage: "plus")
                    }
                }
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { groupOffset, group in
                let visible = group.items.filter { !reviewOnly || $0.ingredient.needsReview || $0.nutrition.conversion.isWeak }
                if !visible.isEmpty || groupOffset == groups.count - 1 {
                    Section {
                        ForEach(visible, id: \.ingredient.persistentModelID) { row in
                            Button {
                                editingIngredient = row.ingredient
                            } label: {
                                IngredientRow(ingredient: row.ingredient, nutrition: row.nutrition, factor: factor)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            for index in offsets { context.delete(visible[index].ingredient) }
                            renumberIngredients()
                        }
                        if groupOffset == groups.count - 1 {
                            Button {
                                addingIngredient = true
                            } label: {
                                Label("Add ingredient", systemImage: "plus")
                            }
                        }
                    } header: {
                        if hasParts {
                            GroupHeader(title: group.title.isEmpty ? "Other" : group.title,
                                        summary: NutritionCalculator.summarize(group.items.map(\.nutrition), servings: recipe.servings),
                                        perServing: perServing, isFirst: groupOffset == 0)
                        } else {
                            Text("Ingredients")
                        }
                    }
                }
            }

            let steps = recipe.sortedSteps
            let origin = stepsOrigin(steps)
            Section {
                if steps.isEmpty {
                    Label("No instructions in this video", systemImage: "text.badge.xmark")
                        .foregroundStyle(.secondary)
                    findStepsButtons
                    if services.ai.engine == .onDevice, recipe.sourceItemID != nil {
                        Text("Tip: with your own API (✨ AI settings), RecipeReel can also look at the video's pictures to write the steps when nobody says or writes them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if origin == .aiSuggested || origin == .web || origin == .videoPictures {
                        StepsOriginBanner(steps: steps, origin: origin)
                    }
                    ForEach(steps) { step in
                        if !reviewOnly || step.needsReview {
                            StepRow(step: step, number: step.order + 1, ingredientNames: ingredients.map(\.name))
                        }
                    }
                }
            } header: {
                Text("Steps")
            } footer: {
                if !steps.isEmpty {
                    Text(recipe.servings != recipe.yield
                         ? "Tap a step to mark it done. Amounts written in the steps are for \(recipe.yield) servings; use the scaled ingredient list."
                         : "Tap a step to mark it done.")
                }
            }

            Section {
                Text("Macros are estimates from European food tables (Ciqual, CoFID) and USDA FoodData Central, and depend on the matched foods and amounts. Carbs exclude fibre, as on EU labels. Steps come from the video and its caption unless marked as suggested or imported.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(recipe.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    chatting = true
                } label: {
                    Label("Ask the chef", systemImage: "bubble.left.and.bubble.right")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    cooking = true
                } label: {
                    Label("Cook", systemImage: "frying.pan")
                }
                .disabled(recipe.steps.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editingSteps = true
                    } label: {
                        Label("Edit steps", systemImage: "list.number")
                    }
                    Button {
                        requestSteps(.suggest)
                    } label: {
                        Label("Suggest steps (AI)", systemImage: "sparkles")
                    }
                    Button {
                        requestSteps(.web)
                    } label: {
                        Label("Find steps online", systemImage: "safari")
                    }
                    Button {
                        recipe.steps.forEach { $0.isDone = false }
                    } label: {
                        Label("Reset done steps", systemImage: "arrow.counterclockwise")
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete recipe", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .task(id: recipe.ingredients.map(\.fdcID)) {
            loadFoods()
        }
        .sheet(item: $editingIngredient) { ingredient in
            IngredientEditorView(ingredient: ingredient, recipe: recipe, factor: recipe.scaleFactor) { loadFoods() }
        }
        .sheet(isPresented: $addingIngredient) {
            IngredientEditorView(ingredient: nil, recipe: recipe, factor: recipe.scaleFactor) { loadFoods() }
        }
        .sheet(isPresented: $editingSteps) {
            StepsEditorView(recipe: recipe)
        }
        .fullScreenCover(isPresented: $cooking) {
            CookModeView(recipe: recipe)
        }
        .sheet(isPresented: $findingOnline) {
            WebStepsImportView(recipe: recipe)
        }
        .sheet(isPresented: $chatting) {
            ChefChatView(recipe: recipe)
        }
        .confirmationDialog("Replace the current steps?", isPresented: Binding(
            get: { confirmReplace != nil },
            set: { if !$0 { confirmReplace = nil } }
        ), titleVisibility: .visible, presenting: confirmReplace) { source in
            Button("Replace steps", role: .destructive) { startSteps(source) }
        } message: { _ in
            Text("The steps from the video will be removed.")
        }
        .alert("Couldn't get steps", isPresented: Binding(
            get: { stepError != nil },
            set: { if !$0 { stepError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(stepError ?? "")
        }
        .confirmationDialog("Delete this recipe?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                ChefMessage.deleteConversation(of: recipe.id, in: context)
                context.delete(recipe)
                try? context.save()
                dismiss()
            }
        }
    }

    // MARK: - Finding steps when the video has none

    @ViewBuilder
    private var findStepsButtons: some View {
        Button {
            requestSteps(.suggest)
        } label: {
            if suggesting {
                HStack { ProgressView(); Text("Writing suggested steps…") }
            } else {
                Label("Suggest steps (AI)", systemImage: "sparkles")
            }
        }
        .disabled(suggesting || recipe.ingredients.isEmpty)
        Button {
            requestSteps(.web)
        } label: {
            Label("Find steps online", systemImage: "safari")
        }
    }

    private func stepsOrigin(_ steps: [Step]) -> StepOrigin? {
        let origins = Set(steps.map(\.origin))
        if origins.contains(.aiSuggested) { return .aiSuggested }
        if origins.contains(.web) { return .web }
        if origins.contains(.videoPictures) { return .videoPictures }
        return origins.first
    }

    private func requestSteps(_ source: StepSource) {
        if recipe.steps.contains(where: { $0.origin == .video }) {
            confirmReplace = source
        } else {
            startSteps(source)
        }
    }

    private func startSteps(_ source: StepSource) {
        switch source {
        case .web:
            findingOnline = true
        case .suggest:
            Task { await suggestSteps() }
        }
    }

    private func suggestSteps() async {
        suggesting = true
        defer { suggesting = false }
        do {
            let drafts = try await services.suggestSteps(for: recipe)
            guard !drafts.isEmpty else {
                stepError = "The model didn't return any steps. Try again or find steps online."
                return
            }
            for old in recipe.steps { context.delete(old) }
            _ = RecipeFactory.replaceSteps(of: recipe, with: drafts, origin: .aiSuggested)
            try? context.save()
        } catch {
            stepError = error.localizedDescription
        }
    }

    /// "Cooking for": pins the yield first on older recipes that didn't store one.
    private var servingsBinding: Binding<Int> {
        Binding(
            get: { recipe.servings },
            set: { newValue in
                if recipe.yieldServings == 0 { recipe.yieldServings = recipe.servings }
                recipe.servings = newValue
            }
        )
    }

    /// Changing what the recipe makes keeps "cooking for" in step (no scaling until you change that).
    private var yieldBinding: Binding<Int> {
        Binding(
            get: { recipe.yield },
            set: { newValue in
                let keepScaling = recipe.servings != recipe.yield
                recipe.yieldServings = newValue
                if !keepScaling { recipe.servings = newValue }
            }
        )
    }

    private func nutrition(for ingredient: Ingredient, factor: Double) -> IngredientNutrition {
        NutritionCalculator.evaluate(
            quantity: Scaling.scaled(ingredient.quantity, unit: ingredient.unit, factor: factor),
            unit: ingredient.unit,
            food: ingredient.fdcID.flatMap { foods[$0] }
        )
    }

    private func loadFoods() {
        var loaded: [Int: FoodRecord] = [:]
        for id in recipe.ingredients.compactMap(\.fdcID) where loaded[id] == nil {
            if let food = services.food(id: id) { loaded[id] = food }
        }
        foods = loaded
    }

    private func renumberIngredients() {
        for (index, ingredient) in recipe.sortedIngredients.filter({ !$0.isDeleted }).enumerated() { ingredient.order = index }
    }
}

/// An ingredient with its computed nutrition, for grouping on the recipe screen.
struct IngredientLine {
    let ingredient: Ingredient
    let nutrition: IngredientNutrition
}

/// Section header for one part of a recipe, with that part's calories.
struct GroupHeader: View {
    let title: String
    let summary: RecipeNutrition
    let perServing: Bool
    let isFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isFirst {
                Text("Ingredients")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .textCase(nil)
                Spacer()
                let macros = perServing ? summary.perServing : summary.total
                if macros.kcal > 0 {
                    Text("\(RecipeMath.kcal(macros.kcal)) kcal\(perServing ? " / serving" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
    }
}

// MARK: - Macro card

struct MacroCard: View {
    let summary: RecipeNutrition
    @Binding var perServing: Bool

    var body: some View {
        let macros = perServing ? summary.perServing : summary.total
        VStack(alignment: .leading, spacing: 12) {
            Picker("Show", selection: $perServing) {
                Text("Per serving").tag(true)
                Text("Total").tag(false)
            }
            .pickerStyle(.segmented)

            HStack(alignment: .firstTextBaseline) {
                Text(RecipeMath.kcal(macros.kcal))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("kcal")
                    .foregroundStyle(.secondary)
            }

            HStack {
                macro("Protein", macros.protein, .blue)
                macro("Carbs", macros.carbs, .orange)
                macro("Fat", macros.fat, .pink)
            }

            Text("Fiber \(RecipeMath.grams(macros.fiber)) · Sugar \(RecipeMath.grams(macros.sugar))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if summary.notCountedLines > 0 || summary.approximateLines > 0 {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .animation(.default, value: perServing)
    }

    private var notes: String {
        var parts: [String] = []
        if summary.notCountedLines > 0 {
            parts.append("\(summary.notCountedLines) ingredient\(summary.notCountedLines == 1 ? "" : "s") not counted")
        }
        if summary.approximateLines > 0 {
            parts.append("\(summary.approximateLines) approximate")
        }
        return parts.joined(separator: " · ")
    }

    private func macro(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(RecipeMath.grams(value))
                .font(.headline)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Capsule()
                .fill(color.gradient)
                .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Ingredient row

struct IngredientRow: View {
    let ingredient: Ingredient
    let nutrition: IngredientNutrition
    var factor: Double = 1

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(RecipeMath.amountText(quantity: Scaling.scaled(ingredient.quantity, unit: ingredient.unit, factor: factor), unit: ingredient.unit))
                .font(.body.monospacedDigit())
                .frame(minWidth: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(ingredient.name)
                if !ingredient.note.isEmpty {
                    Text(ingredient.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(flags, id: \.self) { flag in
                    Label(flag, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 4)
            if let macros = nutrition.macros {
                Text("\(RecipeMath.kcal(macros.kcal)) kcal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .listRowBackground(isFlagged ? Color.orange.opacity(0.12) : nil)
    }

    private var isFlagged: Bool { ingredient.needsReview || (nutrition.conversion.isWeak && ingredient.unit != .toTaste && !ingredient.reviewed) }

    private var flags: [String] {
        guard !ingredient.reviewed else { return [] }
        var result: [String] = []
        if ingredient.confidence == .low && ingredient.unit != .toTaste {
            result.append(ingredient.quantity == nil ? "amount not stated" : "amount is an estimate")
        }
        if ingredient.fdcID == nil && ingredient.unit != .toTaste {
            result.append("no nutrition match")
        } else if nutrition.conversion.method == .notCounted && ingredient.unit != .toTaste {
            result.append("not counted: \(nutrition.conversion.detail)")
        } else if nutrition.conversion.method == .assumed {
            result.append("approximate weight (\(nutrition.conversion.detail))")
        }
        return result
    }
}

/// Explains where non-video steps came from.
struct StepsOriginBanner: View {
    let steps: [Step]
    let origin: StepOrigin?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if origin == .videoPictures {
                Label("From the video's pictures", systemImage: "eye")
                    .font(.subheadline.bold())
                Text("Nobody says or writes the method in this video, so these steps describe what it shows. Check amounts against the ingredient list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if origin == .aiSuggested {
                Label("Suggested by AI — not from the video", systemImage: "sparkles")
                    .font(.subheadline.bold())
                Text("A guess from the ingredient list. Check times and temperatures before cooking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let step = steps.first(where: { $0.origin == .web }) {
                Label("Imported from \(step.sourceLabel ?? "a web page") — not from the video", systemImage: "safari")
                    .font(.subheadline.bold())
                if let link = step.sourceURL.flatMap(URL.init(string:)) {
                    Link("Open the original page", destination: link)
                        .font(.caption)
                }
            }
        }
        .foregroundStyle(origin == .videoPictures ? Color.accentColor : Color.orange)
        .padding(.vertical, 2)
    }
}
