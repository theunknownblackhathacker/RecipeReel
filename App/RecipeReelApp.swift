import SwiftUI
import RecipeCore

@main
struct RecipeReelApp: App {
    @State private var model = ImportModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // "Open in RecipeReel" from Files and other apps.
                .onOpenURL { url in
                    Task { await model.importOpenedFile(url) }
                }
        }
    }
}

struct RootView: View {
    @Environment(ImportModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ImportView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            DiagnosticsView()
                        } label: {
                            Label("Diagnostics", systemImage: "stethoscope")
                        }
                    }
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Pick up anything the share extension left in the App Group inbox.
            if phase == .active { model.collectSharedInbox() }
        }
    }
}
