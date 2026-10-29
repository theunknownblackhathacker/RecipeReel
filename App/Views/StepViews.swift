import SwiftData
import SwiftUI
import UIKit
import RecipeCore

// MARK: - Step row (recipe screen)

struct StepRow: View {
    @Bindable var step: Step
    let number: Int
    let ingredientNames: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.bold())
                .foregroundStyle(step.isDone ? .secondary : .primary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(step.isDone ? Color.green.opacity(0.25) : Color.accentColor.opacity(0.18)))
            VStack(alignment: .leading, spacing: 6) {
                Text(StepText.highlighted(step.text, names: step.ingredientNames + ingredientNames))
                    .strikethrough(step.isDone)
                    .foregroundStyle(step.isDone ? .secondary : .primary)
                if step.needsReview {
                    Label("Check this step against the video", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if step.minutes != nil {
                    StepTimerButton(step: step)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { step.isDone.toggle() }
        .padding(.vertical, 2)
        .listRowBackground(step.needsReview ? Color.orange.opacity(0.12) : nil)
    }
}

enum StepText {
    /// Bolds and tints ingredient names (or their main words) inside a step.
    static func highlighted(_ text: String, names: [String]) -> AttributedString {
        var result = AttributedString(text)
        var phrases: [String] = []
        for name in names {
            let base = name.split(separator: ",").first.map(String.init) ?? name
            phrases.append(base.trimmingCharacters(in: .whitespaces))
            phrases += base.split(separator: " ").map(String.init).filter { $0.count >= 4 }
        }
        var seen = Set<String>()
        for phrase in phrases.sorted(by: { $0.count > $1.count }) where !phrase.isEmpty && seen.insert(phrase.lowercased()).inserted {
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result[searchStart...].range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) {
                if result[range].inlinePresentationIntent == nil {
                    result[range].inlinePresentationIntent = .stronglyEmphasized
                    result[range].swiftUI.foregroundColor = .accentColor
                }
                searchStart = range.upperBound
            }
        }
        return result
    }
}

// MARK: - Timer

struct StepTimerButton: View {
    let step: Step
    @Environment(TimerCenter.self) private var timers
    var large = false

    var body: some View {
        if let end = timers.endDate(for: step) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = end.timeIntervalSince(context.date)
                HStack {
                    Label(remaining > 0 ? TimerCenter.format(remaining) : "Done!",
                          systemImage: remaining > 0 ? "timer" : "bell.fill")
                        .font(large ? .title2.monospacedDigit().bold() : .subheadline.monospacedDigit().bold())
                        .foregroundStyle(remaining > 0 ? Color.accentColor : Color.green)
                    Button("Cancel") { timers.cancel(step) }
                        .font(large ? .body : .caption)
                        .buttonStyle(.bordered)
                }
            }
        } else if let minutes = step.minutes {
            Button {
                timers.start(step)
            } label: {
                Label("\(minutes) min timer", systemImage: "timer")
                    .font(large ? .title3 : .subheadline)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Edit steps (reword, reorder, add, delete)

struct StepsEditorView: View {
    @Bindable var recipe: Recipe
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Step?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(recipe.sortedSteps) { step in
                    Button {
                        editing = step
                    } label: {
                        HStack(alignment: .top) {
                            Text("\(step.order + 1).").bold()
                            Text(step.text).foregroundStyle(.primary)
                            Spacer()
                            if let minutes = step.minutes {
                                Text("\(minutes) min").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onMove { source, destination in
                    var steps = recipe.sortedSteps
                    steps.move(fromOffsets: source, toOffset: destination)
                    for (index, step) in steps.enumerated() {
                        step.order = index
                        step.userEdited = true
                    }
                }
                .onDelete { offsets in
                    let steps = recipe.sortedSteps
                    for index in offsets { context.delete(steps[index]) }
                    let remaining = steps.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
                    for (index, step) in remaining.enumerated() { step.order = index }
                }
                Button {
                    adding = true
                } label: {
                    Label("Add step", systemImage: "plus")
                }
            }
            .navigationTitle("Edit steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        recipe.hasInstructions = !recipe.steps.isEmpty
                        try? context.save()
                        dismiss()
                    }
                }
            }
            .sheet(item: $editing) { step in
                StepEditorSheet(step: step, recipe: recipe)
            }
            .sheet(isPresented: $adding) {
                StepEditorSheet(step: nil, recipe: recipe)
            }
        }
    }
}

struct StepEditorSheet: View {
    let step: Step?
    let recipe: Recipe
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var minutesText = ""
    @State private var used: Set<String> = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Instruction") {
                    TextField("e.g. Bake at 180°C for 20 min", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    TextField("Minutes", text: $minutesText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Timer (optional)")
                } footer: {
                    Text("Only add a time the video states.")
                }
                if !recipe.ingredients.isEmpty {
                    Section("Ingredients used") {
                        ForEach(recipe.sortedIngredients) { ingredient in
                            Button {
                                if used.contains(ingredient.name) { used.remove(ingredient.name) } else { used.insert(ingredient.name) }
                            } label: {
                                HStack {
                                    Text(ingredient.name).foregroundStyle(.primary)
                                    Spacer()
                                    if used.contains(ingredient.name) { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
                if let step, !step.sourceQuote.isEmpty {
                    Section("From the video") {
                        Text("“\(step.sourceQuote)”").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(step == nil ? "New step" : "Edit step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let step {
                    text = step.text
                    minutesText = step.minutes.map(String.init) ?? ""
                    used = Set(step.ingredientNames)
                }
            }
        }
    }

    private func save() {
        let minutes = Int(minutesText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        let names = recipe.sortedIngredients.map(\.name).filter(used.contains)
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let step {
            step.text = cleanText
            step.minutes = minutes
            step.ingredientNames = names
            step.userEdited = true
            step.reviewed = true
        } else {
            let newStep = Step(order: recipe.steps.count, text: cleanText, minutes: minutes, ingredientNames: names, origin: .manual)
            newStep.userEdited = true
            newStep.reviewed = true
            recipe.steps.append(newStep)
        }
        dismiss()
    }
}

// MARK: - Cook mode

struct CookModeView: View {
    let recipe: Recipe
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        let steps = recipe.sortedSteps
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(steps.enumerated()), id: \.offset) { offset, step in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            Text("Step \(offset + 1) of \(steps.count)")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text(StepText.highlighted(step.text, names: step.ingredientNames))
                                .font(.system(size: 30, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            if !step.ingredientNames.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("You'll need").font(.headline)
                                    ForEach(step.ingredientNames, id: \.self) { name in
                                        Text(ingredientLine(name)).font(.title3)
                                    }
                                }
                            }
                            if step.minutes != nil {
                                StepTimerButton(step: step, large: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                    }
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .navigationTitle(recipe.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        withAnimation { index = max(0, index - 1) }
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .disabled(index == 0)
                    Spacer()
                    if index < steps.count - 1 {
                        Button {
                            steps[index].isDone = true
                            withAnimation { index += 1 }
                        } label: {
                            Label("Next", systemImage: "chevron.right")
                        }
                    } else {
                        Button("Finish") {
                            if steps.indices.contains(index) { steps[index].isDone = true }
                            dismiss()
                        }
                        .bold()
                    }
                }
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }   // screen stays awake
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func ingredientLine(_ name: String) -> String {
        guard let ingredient = recipe.ingredients.first(where: { $0.name == name }) else { return "• \(name)" }
        let amount = RecipeMath.amountText(quantity: ingredient.quantity, unit: ingredient.unit)
        return "• \(amount == "?" ? "" : amount + " ")\(name)"
    }
}
