import SwiftUI

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Shared") {
                    if model.phase == .inspecting {
                        ProgressView("Reading what you shared…")
                    } else {
                        if model.hasVideo {
                            Label("Video", systemImage: "film")
                        }
                        if let link = model.link {
                            Label(link.host() ?? link.absoluteString, systemImage: "link")
                                .lineLimit(1)
                        }
                        if !model.hasVideo && model.link == nil {
                            Label("No video or link", systemImage: "questionmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if model.link != nil && !model.hasVideo {
                    Section {
                        Text("Instagram only shares a link, not the video. RecipeReel will save the link and caption, then show you how to add the video.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextEditor(text: $model.caption)
                        .frame(minHeight: 120)
                } header: {
                    Text("Caption (optional)")
                } footer: {
                    Text("Paste the post's caption — ingredients and steps are often listed there.")
                }

                statusSection
            }
            .navigationTitle("Save to RecipeReel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                        .disabled(model.phase == .saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await model.save() }
                    }
                    .disabled(!model.canSave)
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.phase {
        case .saving:
            Section { ProgressView("Saving…") }
        case .saved:
            Section {
                Label("Saved. Open RecipeReel to continue.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .noAppGroup:
            Section {
                Text("This install can't hand files to RecipeReel (the App Group is missing from the signing profile). Open RecipeReel and use “Choose a video” instead.")
                    .font(.footnote)
                Button("Copy link & caption") { model.copyToClipboard() }
                Button("Done") { model.done() }
            }
        case .failed(let message):
            Section {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        case .inspecting, .ready:
            EmptyView()
        }
    }
}
