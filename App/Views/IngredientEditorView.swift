import SwiftData
import SwiftUI
import RecipeCore

/// Edit or add one ingredient: name, amount, unit, note and the nutrition match.
/// Changes are applied on Save; picking a food also teaches the app for next time.
struct IngredientEditorView: View {
    let ingredient: Ingredient?
    let recipe: Recipe
    let onSave: () -> Void

    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var quantityText = ""
    @State private var unit: CanonicalUnit = .g
    @State private var note = ""
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
        quantityText = RecipeMath.quantityText(ingredient.quantity).replacingOccurrences(of: "½", with: ".5")
        if quantityText.hasPrefix(".") { quantityText = "0" + quantityText }
        if let q = ingredient.quantity, q != q.rounded() { quantityText = String(format: "%g", q) }
        unit = ingredient.unit
        note = ingredient.note
        fdcID = ingredient.fdcID
        foodDescription = ingredient.foodDescription
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let quantity = unit == .toTaste ? nil : RecipeMath.parseQuantity(quantityText)
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

/// Search the bundled USDA database and pick a food (or "no match").
struct FoodPickerView: View {
    let initialQuery: String
    let onPick: (FoodCandidate?) -> Void

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [FoodCandidate] = []

    var body: some View {
        List {
            if services.database == nil {
                Text(services.databaseProblem ?? "Nutrition database unavailable.")
                    .foregroundStyle(.orange)
            }
            Section {
                Button("No match (don't count this ingredient)") {
                    onPick(nil)
                    dismiss()
                }
            }
            Section {
                ForEach(results) { candidate in
                    Button {
                        onPick(candidate)
                        dismiss()
                    } label: {
                        Text(candidate.description)
                            .foregroundStyle(.primary)
                    }
                }
            } footer: {
                Text("Data: USDA FoodData Central (public domain).")
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
        .navigationTitle("Choose food")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if query.isEmpty { query = initialQuery }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let text = query
            if let db = services.database {
                let ranked = db.search(ingredientName: text, limit: 10)
                let more = db.search(text: text, limit: 40).filter { hit in !ranked.contains { $0.fdcID == hit.fdcID } }
                results = ranked + more
            }
        }
    }
}
