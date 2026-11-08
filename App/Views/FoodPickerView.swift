import SwiftUI
import VisionKit
import RecipeCore

/// Pick the food behind an ingredient: your own foods, the bundled USDA data, Open Food Facts
/// (search or barcode scan), or a new food typed from a label.
struct FoodPickerView: View {
    let initialQuery: String
    let onPick: (FoodCandidate?) -> Void

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var usda: [FoodCandidate] = []
    @State private var online: [CustomFood] = []
    @State private var onlineState: OnlineState = .idle
    @State private var scanning = false
    @State private var addingLabel = false
    @State private var scanMessage: String?

    enum OnlineState: Equatable {
        case idle, searching, done, failed(String)
    }

    var body: some View {
        List {
            Section {
                Button {
                    scanning = true
                } label: {
                    Label("Scan a barcode", systemImage: "barcode.viewfinder")
                }
                .disabled(!BarcodeScannerView.isAvailable)
                Button {
                    addingLabel = true
                } label: {
                    Label("Enter from a nutrition label", systemImage: "square.and.pencil")
                }
                Button("No match (don't count this ingredient)") {
                    onPick(nil)
                    dismiss()
                }
                if let scanMessage {
                    Text(scanMessage).font(.footnote).foregroundStyle(.orange)
                }
            } footer: {
                if !BarcodeScannerView.isAvailable {
                    Text("Barcode scanning needs camera access (Settings → RecipeReel → Camera).")
                }
            }

            let mine = myFoods
            if !mine.isEmpty {
                Section("My foods") {
                    ForEach(mine) { food in
                        foodRow(food.displayName, detail: macroLine(food)) {
                            pick(FoodCandidate(fdcID: food.id, description: food.displayName))
                        }
                    }
                }
            }

            Section {
                if services.database == nil {
                    Text(services.databaseProblem ?? "Nutrition database unavailable.")
                        .foregroundStyle(.orange)
                }
                ForEach(usda) { candidate in
                    foodRow(candidate.description, detail: candidate.sourceName) { pick(candidate) }
                }
            } header: {
                Text("Food tables")
            } footer: {
                Text("European tables (Ciqual, France; CoFID, UK) come first; USDA fills the gaps.")
            }

            Section {
                switch onlineState {
                case .idle:
                    Button {
                        Task { await searchOnline() }
                    } label: {
                        Label("Search Open Food Facts for “\(query)”", systemImage: "globe")
                    }
                    .disabled(query.trimmingCharacters(in: .whitespaces).count < 2)
                case .searching:
                    HStack { ProgressView(); Text("Searching Open Food Facts…") }
                case .failed(let message):
                    Text(message).font(.footnote).foregroundStyle(.orange)
                    Button("Try again") { Task { await searchOnline() } }
                case .done:
                    if online.isEmpty {
                        Text("Nothing found with full nutrition values.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(online.enumerated()), id: \.offset) { _, food in
                        foodRow(food.displayName, detail: macroLine(food)) {
                            let saved = services.customFoods.add(food)
                            pick(FoodCandidate(fdcID: saved.id, description: saved.displayName))
                        }
                    }
                }
            } header: {
                Text("Open Food Facts (online)")
            } footer: {
                Text("Packaged products, products sold in Greece first, added by volunteers — check the values against your pack. Open Food Facts is ODbL.")
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
        .navigationTitle("Choose food")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if query.isEmpty { query = initialQuery }
        }
        .task(id: query) {
            onlineState = .idle
            online = []
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let text = query
            if let db = services.database {
                let ranked = db.search(ingredientName: text, limit: 10)
                let more = db.search(text: text, limit: 40).filter { hit in !ranked.contains { $0.fdcID == hit.fdcID } }
                usda = ranked + more
            }
        }
        .sheet(isPresented: $scanning) {
            BarcodeScannerSheet { code in
                scanning = false
                Task { await lookUp(barcode: code) }
            }
        }
        .sheet(isPresented: $addingLabel) {
            NavigationStack {
                CustomFoodForm(initialName: query) { food in
                    let saved = services.customFoods.add(food)
                    AppLog.shared.log("food", "Added my food “\(saved.displayName)”")
                    pick(FoodCandidate(fdcID: saved.id, description: saved.displayName))
                }
            }
        }
    }

    // MARK: - Pieces

    private var myFoods: [CustomFood] {
        let all = services.customFoods.all
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        let matched = services.customFoods.matching(ingredientName: q)
        let byText = all.filter { ($0.name + " " + $0.brand).localizedCaseInsensitiveContains(q) }
        var seen = Set<Int>()
        return (matched + byText).filter { seen.insert($0.id).inserted }
    }

    private func foodRow(_ title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func macroLine(_ food: CustomFood) -> String {
        "per 100 g: \(Int(food.kcal.rounded())) kcal · P \(String(format: "%.1f", food.protein)) · C \(String(format: "%.1f", food.carbs)) · F \(String(format: "%.1f", food.fat))"
    }

    private func pick(_ candidate: FoodCandidate?) {
        onPick(candidate)
        dismiss()
    }

    private func searchOnline() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return }
        onlineState = .searching
        do {
            online = try await services.openFoodFacts.search(name: text, limit: 15)
            onlineState = .done
            AppLog.shared.log("food", "Open Food Facts search “\(text)”: \(online.count) results")
        } catch {
            onlineState = .failed(error.localizedDescription)
        }
    }

    private func lookUp(barcode: String) async {
        scanMessage = "Looking up \(barcode)…"
        do {
            if let food = try await services.openFoodFacts.product(barcode: barcode) {
                let saved = services.customFoods.add(food)
                AppLog.shared.log("food", "Scanned \(barcode): \(saved.displayName)")
                scanMessage = nil
                pick(FoodCandidate(fdcID: saved.id, description: saved.displayName))
            } else {
                scanMessage = "Product \(barcode) isn't on Open Food Facts with full nutrition values. Enter it from the label instead."
            }
        } catch {
            scanMessage = error.localizedDescription
        }
    }
}

// MARK: - Label entry

/// Type a product's nutrition label (per 100 g) once; the app remembers it.
struct CustomFoodForm: View {
    let initialName: String
    let onSave: (CustomFood) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var brand = ""
    @State private var kcal = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var fiber = ""
    @State private var sugar = ""
    @State private var piece = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Name (e.g. low-fat mayonnaise)", text: $name)
                TextField("Brand (optional)", text: $brand)
            }
            Section {
                number("Energy (kcal)", $kcal)
                number("Protein (g)", $protein)
                number("Carbohydrate (g)", $carbs)
                number("Fat (g)", $fat)
                number("Fibre (g, optional)", $fiber)
                number("Sugars (g, optional)", $sugar)
            } header: {
                Text("Per 100 g (or 100 ml)")
            } footer: {
                Text("Copy the “per 100 g” column of the label. If the label only shows kJ, divide by 4.184.")
            }
            Section {
                number("Weight of one piece (g, optional)", $piece)
            } footer: {
                Text("Only for foods counted in pieces, e.g. one tortilla or one egg.")
            }
        }
        .navigationTitle("My food")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let food else { return }
                    onSave(food)
                    dismiss()
                }
                .disabled(food == nil)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = initialName
        }
    }

    private var food: CustomFood? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let k = value(kcal), let p = value(protein), let c = value(carbs), let f = value(fat),
              k < 950, p <= 100, c <= 100, f <= 100 else { return nil }
        return CustomFood(name: trimmed, brand: brand.trimmingCharacters(in: .whitespaces), source: .label,
                          kcal: k, protein: p, carbs: c, fat: f, fiber: value(fiber), sugar: value(sugar),
                          gramsPerPiece: value(piece).flatMap { $0 > 0 ? $0 : nil })
    }

    private func value(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let number = Double(cleaned), number >= 0 else { return nil }
        return number
    }

    private func number(_ title: String, _ binding: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("0", text: binding)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
        }
    }
}

// MARK: - Barcode scanner (VisionKit)

struct BarcodeScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BarcodeScannerView(onCode: onCode)
                .ignoresSafeArea()
                .navigationTitle("Scan barcode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
    }
}

struct BarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let code = barcode.payloadStringValue, !code.isEmpty {
                    done = true
                    dataScanner.stopScanning()
                    onCode(code)
                    return
                }
            }
        }
    }
}
