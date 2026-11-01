import Foundation

/// Searches an online food database. Implemented by `OpenFoodFactsClient`; mocked in tests.
public protocol OnlineFoodSearching: Sendable {
    func search(name: String, limit: Int) async throws -> [CustomFood]
    func product(barcode: String) async throws -> CustomFood?
}

public enum OpenFoodFactsError: LocalizedError, Sendable {
    case http(Int)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .http(let status): "Open Food Facts didn't answer (HTTP \(status)). Try again later."
        case .badResponse: "Open Food Facts sent an unexpected answer."
        }
    }
}

/// Open Food Facts (openfoodfacts.org): free, open database of packaged foods (ODbL licence).
/// Values are crowd-sourced, so results are labelled as such in the app.
public struct OpenFoodFactsClient: OnlineFoodSearching {
    static let fields = "code,product_name,product_name_en,generic_name,brands,nutriments"
    static let userAgent = "RecipeReel/0.1 (personal iOS app)"

    let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func search(name: String, limit: Int = 10) async throws -> [CustomFood] {
        var components = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")!
        components.queryItems = [
            URLQueryItem(name: "search_terms", value: name),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "30"),
            URLQueryItem(name: "fields", value: Self.fields)
        ]
        let object = try await getJSON(components.url!)
        let products = object["products"] as? [[String: Any]] ?? []
        return Array(products.compactMap(Self.food(from:)).prefix(limit))
    }

    public func product(barcode: String) async throws -> CustomFood? {
        let digits = barcode.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        var components = URLComponents(string: "https://world.openfoodfacts.org/api/v2/product/\(digits).json")!
        components.queryItems = [URLQueryItem(name: "fields", value: Self.fields)]
        let object = try await getJSON(components.url!)
        guard (object["status"] as? Int) == 1 || (object["status"] as? String) == "1",
              let product = object["product"] as? [String: Any] else { return nil }
        var food = Self.food(from: product)
        if food?.barcode == nil { food?.barcode = digits }
        return food
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw OpenFoodFactsError.http(response.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenFoodFactsError.badResponse
        }
        return object
    }

    /// A product with energy, protein, carbs and fat per 100 g; nil when any of those is missing.
    static func food(from product: [String: Any]) -> CustomFood? {
        let nutriments = product["nutriments"] as? [String: Any] ?? [:]
        func value(_ key: String) -> Double? {
            switch nutriments[key] {
            case let number as NSNumber: return number.doubleValue
            case let string as String: return Double(string.replacingOccurrences(of: ",", with: "."))
            default: return nil
            }
        }
        let kcal = value("energy-kcal_100g") ?? value("energy_100g").map { $0 / 4.184 }   // kJ → kcal
        guard let kcal, let protein = value("proteins_100g"), let carbs = value("carbohydrates_100g"),
              let fat = value("fat_100g"), kcal >= 0, kcal < 950 else { return nil }
        let name = [product["product_name"], product["product_name_en"], product["generic_name"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let name else { return nil }
        let brand = ((product["brands"] as? String) ?? "")
            .split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return CustomFood(
            name: name, brand: brand, source: .openFoodFacts, barcode: product["code"] as? String,
            kcal: kcal, protein: protein, carbs: carbs, fat: fat,
            fiber: value("fiber_100g"), sugar: value("sugars_100g")
        )
    }
}
