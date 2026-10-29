import Observation
import SwiftData
import SwiftUI
import WebKit
import RecipeCore

/// In-app browser for finding a method when the video has none. Opens a web search for the recipe;
/// on a recipe page the app reads the page's published recipe data (schema.org, the same data search
/// engines use) and offers "Import steps". Only the page you open is read — nothing is crawled.
struct WebStepsImportView: View {
    let recipe: Recipe
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var browser = BrowserModel()
    @State private var query = ""
    @State private var preview: ImportPreview?

    struct ImportPreview: Identifiable {
        let id = UUID()
        let steps: [String]
        let pageTitle: String
        let host: String
        let url: URL?
        let fromSelection: Bool
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search recipes", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { browser.search(query) }
                    if browser.isLoading { ProgressView() }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                if let found = browser.foundRecipe {
                    Button {
                        preview = ImportPreview(steps: found.steps, pageTitle: found.name.isEmpty ? browser.title : found.name,
                                                host: browser.host, url: browser.url, fromSelection: false)
                    } label: {
                        Label("Recipe found: \(found.steps.count) steps — tap to import", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                WebViewContainer(model: browser)
            }
            .navigationTitle("Find steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!browser.canGoBack)
                    Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!browser.canGoForward)
                    Spacer()
                    Button("Use selected text") {
                        Task {
                            let text = await browser.selectedText()
                            let steps = WebRecipeParser.steps(fromSelection: text)
                            if !steps.isEmpty {
                                preview = ImportPreview(steps: steps, pageTitle: browser.title, host: browser.host,
                                                        url: browser.url, fromSelection: true)
                            }
                        }
                    }
                }
            }
            .onAppear {
                if query.isEmpty {
                    query = "\(recipe.title) recipe"
                    browser.search(query)
                }
            }
            .sheet(item: $preview) { item in
                ImportPreviewView(preview: item) {
                    importSteps(item)
                }
            }
        }
    }

    private func importSteps(_ item: ImportPreview) {
        let names = recipe.sortedIngredients.map(\.name)
        let drafts = ExtractionPostProcessor.webSteps(item.steps, ingredientNames: names)
        for old in recipe.steps { context.delete(old) }
        _ = RecipeFactory.replaceSteps(of: recipe, with: drafts, origin: .web,
                                       sourceLabel: item.host, sourceURL: item.url?.absoluteString)
        try? context.save()
        AppLog.shared.log("web", "Imported \(drafts.count) steps from \(item.host)\(item.fromSelection ? " (selection)" : "")")
        preview = nil
        dismiss()
    }
}

private struct ImportPreviewView: View {
    let preview: WebStepsImportView.ImportPreview
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(preview.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top) {
                            Text("\(index + 1).").bold()
                            Text(step)
                        }
                    }
                } header: {
                    Text(preview.pageTitle)
                } footer: {
                    Text("From \(preview.host). These steps replace the recipe's steps and are marked as imported. Your ingredients and macros stay as they are.")
                }
            }
            .navigationTitle("Import steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { onImport() }
                }
            }
        }
    }
}

// MARK: - Browser

@MainActor
@Observable
final class BrowserModel {
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var title = ""
    var host = ""
    var url: URL?
    var foundRecipe: WebRecipe?

    @ObservationIgnored weak var webView: WKWebView?

    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        if let url = components.url { webView?.load(URLRequest(url: url)) }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func updateState() {
        guard let webView else { return }
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        title = webView.title ?? ""
        url = webView.url
        host = (webView.url?.host() ?? "").replacingOccurrences(of: "www.", with: "")
    }

    /// Reads the current page's recipe data (JSON-LD, then microdata).
    func detectRecipe() async {
        foundRecipe = nil
        guard let webView, !host.contains("duckduckgo") else { return }
        let script = """
        (function() {
          var ld = [];
          document.querySelectorAll('script[type="application/ld+json"]').forEach(function(s) { ld.push(s.textContent || ''); });
          var micro = [];
          document.querySelectorAll('[itemprop="recipeInstructions"]').forEach(function(e) { micro.push(e.innerText || ''); });
          return JSON.stringify({ ld: ld, micro: micro });
        })();
        """
        guard let json = try? await webView.evaluateJavaScript(script) as? String,
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PagePayload.self, from: data)
        else { return }
        foundRecipe = WebRecipeParser.parse(jsonLD: payload.ld, microdataInstructions: payload.micro)
        if let found = foundRecipe {
            AppLog.shared.log("web", "Recipe data on \(host): \(found.steps.count) steps")
        }
    }

    func selectedText() async -> String {
        guard let webView else { return "" }
        let script = "(function() { return String(window.getSelection ? window.getSelection().toString() : ''); })();"
        return (try? await webView.evaluateJavaScript(script) as? String) ?? ""
    }

    private struct PagePayload: Decodable {
        let ld: [String]
        let micro: [String]
    }
}

struct WebViewContainer: UIViewRepresentable {
    let model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()      // no cookies kept between sessions
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        model.webView = webView
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: BrowserModel

        init(model: BrowserModel) {
            self.model = model
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            model.foundRecipe = nil
            model.updateState()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.updateState()
            Task { await model.detectRecipe() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model.updateState()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            model.updateState()
        }
    }
}
