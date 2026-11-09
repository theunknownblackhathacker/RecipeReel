import SwiftData
import SwiftUI
import RecipeCore

/// "Ask the chef": a conversation about one recipe (each recipe keeps its own). The chef can propose
/// edits; they're applied only when the user taps Apply, and the latest applied set can be undone.
struct ChefChatView: View {
    let recipe: Recipe

    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var messages: [ChefMessage]
    @State private var draft = ""
    @State private var sending = false
    @State private var confirmClear = false
    @FocusState private var inputFocused: Bool

    init(recipe: Recipe) {
        self.recipe = recipe
        let id = recipe.id
        _messages = Query(filter: #Predicate<ChefMessage> { $0.recipeID == id }, sort: \ChefMessage.createdAt)
    }

    private static let starters = [
        "Make it taste better",
        "Make it lighter without losing flavour",
        "More protein, same taste",
        "What would you change?"
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        intro
                        ForEach(messages) { message in
                            ChefBubble(message: message,
                                       canUndo: message.persistentModelID == latestApplied?.persistentModelID,
                                       onApply: { apply(message) },
                                       onUndo: { undo(message) })
                                .id(message.persistentModelID)
                        }
                        if sending {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("The chef is thinking…").foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            .id("thinking")
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { scrollToEnd(proxy, animated: false) }
                .onChange(of: messages.count) { scrollToEnd(proxy) }
                .onChange(of: sending) { scrollToEnd(proxy) }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("Ask the chef")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button(role: .destructive) {
                            confirmClear = true
                        } label: {
                            Label("Clear conversation", systemImage: "trash")
                        }
                        .disabled(messages.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Clear this conversation?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { clear() }
            } message: {
                Text("The recipe keeps any changes you applied.")
            }
        }
    }

    // MARK: - Pieces

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chat about “\(recipe.title)”. The chef can suggest changes; nothing changes until you tap Apply. Macros are always calculated by the app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Label("Using \(services.engineLabel)", systemImage: "cpu")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem = services.extractionProblem {
                Text(problem).font(.footnote).foregroundStyle(.orange)
            }
            if messages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.starters, id: \.self) { starter in
                        Button(starter) { send(starter) }
                            .buttonStyle(.bordered)
                            .disabled(sending || services.extractionProblem != nil)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the chef", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || services.extractionProblem != nil)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// The most recently applied proposal: the only one Undo is offered for (undoing an older one
    /// would also throw away later changes).
    private var latestApplied: ChefMessage? {
        messages.last(where: { $0.status == .applied })
    }

    // MARK: - Actions

    private func send(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !sending else { return }
        let history = turns()
        context.insert(ChefMessage(recipeID: recipe.id, role: .user, text: message))
        try? context.save()
        draft = ""
        sending = true
        Task {
            do {
                let answer = try await services.askChef(recipe: recipe, history: history, message: message)
                context.insert(ChefMessage(recipeID: recipe.id, role: .chef, text: answer.reply,
                                           proposal: answer.proposal, preview: answer.preview))
            } catch {
                AppLog.shared.log("chef", "Failed: \(error.localizedDescription)")
                context.insert(ChefMessage(recipeID: recipe.id, role: .error, text: error.localizedDescription))
            }
            try? context.save()
            sending = false
        }
    }

    /// The conversation for the prompt; proposals are summarised with whether they were applied.
    private func turns() -> [ChefTurn] {
        messages.compactMap { message in
            switch message.role {
            case .user:
                return ChefTurn(role: .user, text: message.text)
            case .chef:
                var text = message.text
                if let proposal = message.proposal {
                    let state = switch message.status {
                    case .applied: "applied"
                    case .undone: "undone"
                    case .pending: "not applied"
                    }
                    text += " (Proposed: \(proposal.lines.joined(separator: "; ")) — \(state))"
                }
                return ChefTurn(role: .chef, text: text)
            case .error:
                return nil
            }
        }
    }

    private func apply(_ message: ChefMessage) {
        guard let proposal = message.proposal else { return }
        let before = ChefRecipe(recipe)
        let after = Chef.apply(proposal.changes, to: before)
        message.undoSnapshot = before
        RecipeFactory.update(recipe, to: after, context: context)
        message.status = .applied
        try? context.save()
        AppLog.shared.log("chef", "Applied \(proposal.changes.count) changes to “\(recipe.title)”")
    }

    private func undo(_ message: ChefMessage) {
        guard let snapshot = message.undoSnapshot else { return }
        RecipeFactory.update(recipe, to: snapshot, context: context, replaceAll: true)
        message.status = .undone
        try? context.save()
        AppLog.shared.log("chef", "Undid changes to “\(recipe.title)”")
    }

    private func clear() {
        for message in messages { context.delete(message) }
        try? context.save()
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let scroll = {
            if sending {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.persistentModelID, anchor: .bottom)
            }
        }
        if animated {
            withAnimation { scroll() }
        } else {
            scroll()
        }
    }
}

// MARK: - Message bubble

struct ChefBubble: View {
    let message: ChefMessage
    let canUndo: Bool
    let onApply: () -> Void
    let onUndo: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
            }
        case .chef:
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message.text)
                    if let proposal = message.proposal {
                        proposalCard(proposal)
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Spacer(minLength: 24)
            }
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private func proposalCard(_ proposal: ChefProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Suggested changes").font(.subheadline.bold())
            ForEach(Array(zip(proposal.changes, proposal.lines).enumerated()), id: \.offset) { _, pair in
                Label(pair.1, systemImage: Self.icon(for: pair.0))
                    .font(.subheadline)
            }
            if !message.preview.isEmpty {
                Text(message.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch message.status {
            case .pending, .undone:
                HStack {
                    Button(message.status == .undone ? "Apply again" : "Apply changes", action: onApply)
                        .buttonStyle(.borderedProminent)
                    if message.status == .undone {
                        Text("Undone").font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .applied:
                HStack {
                    Label("Applied", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    Spacer()
                    if canUndo {
                        Button("Undo", action: onUndo)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    static func icon(for change: ChefChange) -> String {
        switch change {
        case .addIngredient: "plus.circle"
        case .changeIngredient: "pencil.circle"
        case .removeIngredient: "minus.circle"
        case .addStep, .changeStep: "list.number"
        case .removeStep: "minus.circle"
        case .rename: "textformat"
        case .setYield: "person.2"
        }
    }
}
