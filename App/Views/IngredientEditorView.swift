import SwiftData
import SwiftUI
import RecipeCore

/// Edit or add one ingredient: name, amount, unit, note and the nutrition match.
/// Changes are applied on Save; picking a food also teaches the app for next time.
struct IngredientEditorView: View {
    let ingredient: Ingredient?
    let recipe: Recipe
    /// Amounts are shown scaled to "cooking for"; they're stored at the recipe's yield.
    var factor: Double = 1
    let onSave: () -> Void

    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var quantityText = ""
    @State private var unit: CanonicalUnit = .g
    @State private var note = ""
    @State private var group = ""
    @State private var fdcID: Int?
    @State private var foodDescription: String?
    @State private var foodChanged = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ingredient", text: $name)
                    HStack {
                        TextField("Amount", text: $quantityText)
                            .keyboardType(.decimalPad)
                            .disabled(unit == .toTaste)
                        Picker("Unit", selection: $unit) {
                            ForEach(CanonicalUnit.allCases) { unit in
                                Text(unit.label).tag(unit)
                            }
                        }
                        .labelsHidden()
                    }
                    TextField("Note (e.g. chopped)", text: $note)
                    HStack {
                        TextField("Part of the recipe (optional)", text: $group)
                        if !existingGroups.isEmpty {
                            Menu {
                                ForEach(existingGroups, id: \.self) { name in
                                    Button(name) { group = name }
                                }
                                Button("None") { group = "" }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                        }
                    }
                } footer: {
                    if !quantityText.isEmpty, RecipeMath.parseQuantity(quantityText) == nil {
                        Text("Use a number like 80, 1.5 or 1/2.").foregroundStyle(.red)
                    }
                }

                Section {
                    NavigationLink {
                        FoodPickerView(initialQuery: name) { candidate in
                            fdcID = candidate?.fdcID
                            foodDescription = candidate?.description
                            foodChanged = true
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(foodDescription ?? "No match — not counted")
                                .foregroundStyle(foodDescription == nil ? .orange : .primary)
                            if let fdcID {
                                Text("USDA FoodData Central #\(fdcID)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Nutrition match")
                } footer: {
                    if let preview {
                        Text(preview)
                    }
                }

                if let ingredient, !ingredient.sourceQuote.isEmpty {
                    Section("From the video") {
                        Text("“\(ingredient.sourceQuote)”")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(ingredient == nil ? "Add ingredient" : "Edit ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (!quantityText.isEmpty && RecipeMath.parseQuantity(quantityText) == nil))
                }
            }
            .onAppear(perform: load)
        }
    }

    /// Parts already used in this recipe ("Chicken", "Alfredo sauce").
    private var existingGroups: [String] {
        IngredientGroup.make(recipe.sortedIngredients) { $0.group }.map(\.title).filter { !$0.isEmpty }
    }

    /// Live grams/kcal preview for the current values.
    private var preview: String? {
        guard let food = services.food(id: fdcID) else { return nil }
        let result = NutritionCalculator.evaluate(quantity: RecipeMath.parseQuantity(quantityText), unit: unit, food: food)
        guard let grams = result.conversion.grams, let macros = result.macros else {
            return "Not counted: \(result.conversion.detail)"
        }
        return "≈ \(String(format: "%.0f", grams)) g · \(RecipeMath.kcal(macros.kcal)) kcal · P \(RecipeMath.grams(macros.protein)) · C \(RecipeMath.grams(macros.carbs)) · F \(RecipeMath.grams(macros.fat))"
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let ingredient else { return }
        name = ingredient.name
        let shown = Scaling.scaled(ingredient.quantity, unit: ingredient.unit, factor: factor)
        quantityText = shown.map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%g", $0) } ?? ""
        unit = ingredient.unit
        note = ingredient.note
        group = ingredient.group
        fdcID = ingredient.fdcID
        foodDescription = ingredient.foodDescription
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        // Typed amount is for "cooking for"; store it at the recipe's yield.
        let quantity = unit == .toTaste ? nil : Scaling.unscaled(RecipeMath.parseQuantity(quantityText), factor: factor)
        let target: Ingredient
        if let ingredient {
            target = ingredient
        } else {
            target = Ingredient(order: recipe.ingredients.count, name: trimmedName, quantity: quantity, unit: unit)
            recipe.ingredients.append(target)
        }
        target.name = trimmedName
        target.quantity = quantity
        target.unit = unit
        target.note = note.trimmingCharacters(in: .whitespaces)
        target.group = IngredientGroups.clean(group)
        target.fdcID = fdcID
        target.foodDescription = foodDescription
        if foodChanged {
            target.matchStatus = fdcID == nil ? .unmatched : .manual
            if let fdcID { services.remember(fdcID: fdcID, for: trimmedName) }
        }
        target.confidence = .high
        target.userEdited = true
        target.reviewed = true
        try? context.save()
        onSave()
        dismiss()
    }
}
