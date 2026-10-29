import SwiftData
import SwiftUI
import RecipeCore

@main
struct RecipeReelApp: App {
    @State private var model = ImportModel()
    @State private var services = AppServices()
    @State private var runner = AnalysisRunner()
    @State private var timers = TimerCenter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(services)
                .environment(runner)
                .environment(timers)
                // "Open in RecipeReel" from Files and other apps.
                .onOpenURL { url in
                    Task { await model.importOpenedFile(url) }
                }
        }
        .modelContainer(for: [Recipe.self, Ingredient.self, Step.self])
    }
}

struct RootView: View {
    @Environment(ImportModel.self) private var model
    @Environment(AppServices.self) private var services
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
            if phase == .active {
                model.collectSharedInbox()
                services.refreshAvailability()
            }
        }
    }
}
