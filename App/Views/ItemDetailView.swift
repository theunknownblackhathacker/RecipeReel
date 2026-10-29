import AVKit
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
    let item: InboxItem
    @State private var player: AVPlayer?
    @State private var editingCaption = false

    var body: some View {
        List {
            switch item.kind {
            case .video:
                Section {
                    VideoPlayer(player: player)
                        .frame(height: 380)
                        .listRowInsets(EdgeInsets())
                }
            case .linkOnly:
                Section {
                    LinkOnlyHelpView(link: item.sourceLink)
                }
            case .captionOnly:
                Section {
                    Text("Caption only. Import the video too for the best results, or keep this if the caption has the full recipe.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let caption = item.caption {
                    Text(caption)
                        .textSelection(.enabled)
                } else {
                    Text("No caption yet. Many creators list ingredients and steps in the caption — paste it here.")
                        .foregroundStyle(.secondary)
                }
                Button(item.caption == nil ? "Add caption" : "Edit caption") {
                    editingCaption = true
                }
            } header: {
                Text("Caption")
            }

            Section("Details") {
                LabeledContent("Type", value: item.kind.displayName)
                LabeledContent("Came from", value: item.origin.displayName)
                LabeledContent("Added", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let size = item.sizeText {
                    LabeledContent("Size", value: size)
                }
            }

            Section {
                Text("Recipe extraction (ingredients, steps, macros) comes in a later milestone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(item.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if player == nil, let url = model.videoURL(for: item) {
                player = AVPlayer(url: url)
            }
        }
        .onDisappear { player?.pause() }
        .sheet(isPresented: $editingCaption) {
            CaptionEditorSheet(title: "Caption", initialText: item.caption ?? "") { text in
                model.updateCaption(text, for: item)
            }
        }
    }
}
