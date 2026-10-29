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

    var body: some View {
        let ingredients = recipe.sortedIngredients
        let lines = ingredients.map { nutrition(for: $0) }
        let summary = NutritionCalculator.summarize(lines, servings: recipe.servings)

        List {
            Section {
                TextField("Recipe name", text: $recipe.title, axis: .vertical)
                    .font(.title2.bold())
                Stepper(value: $recipe.servings, in: 1...50) {
                    Text("Makes \(recipe.servings) serving\(recipe.servings == 1 ? "" : "s")")
                }
                if !recipe.servingsStated {
                    Text("The video didn't say how many servings — set it here.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
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

            Section {
                ForEach(Array(ingredients.enumerated()), id: \.element.persistentModelID) { offset, ingredient in
                    let line = lines[offset]
                    if !reviewOnly || ingredient.needsReview || line.conversion.isWeak {
                        Button {
                            editingIngredient = ingredient
                        } label: {
                            IngredientRow(ingredient: ingredient, nutrition: line)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(ingredients[index]) }
                    renumberIngredients()
                }
                Button {
                    addingIngredient = true
                } label: {
                    Label("Add ingredient", systemImage: "plus")
                }
            } header: {
                Text("Ingredients")
            }

            Section {
                let steps = recipe.sortedSteps
                if steps.isEmpty {
                    Label("No instructions in this video", systemImage: "text.badge.xmark")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(steps) { step in
                        if !reviewOnly || step.needsReview {
                            StepRow(step: step, number: step.order + 1, ingredientNames: ingredients.map(\.name))
                        }
                    }
                }
            } header: {
                Text("Steps")
            } footer: {
                Text("Tap a step to mark it done.")
            }

            Section {
                Text("Macros are estimates from USDA FoodData Central and depend on the matched foods and amounts. Steps come only from the video and its caption.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(recipe.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
            IngredientEditorView(ingredient: ingredient, recipe: recipe) { loadFoods() }
        }
        .sheet(isPresented: $addingIngredient) {
            IngredientEditorView(ingredient: nil, recipe: recipe) { loadFoods() }
        }
        .sheet(isPresented: $editingSteps) {
            StepsEditorView(recipe: recipe)
        }
        .fullScreenCover(isPresented: $cooking) {
            CookModeView(recipe: recipe)
        }
        .confirmationDialog("Delete this recipe?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                context.delete(recipe)
                try? context.save()
                dismiss()
            }
        }
    }

    private func nutrition(for ingredient: Ingredient) -> IngredientNutrition {
        NutritionCalculator.evaluate(
            quantity: ingredient.quantity,
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
        for (index, ingredient) in recipe.sortedIngredients.enumerated() { ingredient.order = index }
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(RecipeMath.amountText(quantity: ingredient.quantity, unit: ingredient.unit))
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
