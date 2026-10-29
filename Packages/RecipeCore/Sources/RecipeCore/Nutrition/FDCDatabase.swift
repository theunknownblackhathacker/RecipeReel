import Foundation
import SQLite3

public enum FDCDatabaseError: LocalizedError, Sendable {
    case openFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Couldn't open the nutrition database: \(message)"
        }
    }
}

/// Read-only access to the bundled `fdc.sqlite` (USDA FoodData Central, built by fdc.yml).
/// Uses Apple's built-in SQLite C API. All access is serialized by a lock.
public final class FDCDatabase: @unchecked Sendable {
    // @unchecked: the connection is only touched while holding `lock`, and the file is read-only.
    private let db: OpaquePointer
    private let lock = NSLock()

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path(percentEncoded: false), &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(result)"
            if let handle { sqlite3_close(handle) }
            throw FDCDatabaseError.openFailed(message)
        }
        db = handle
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Queries

    /// Up to `limit` candidate foods for an ingredient name, best first.
    public func search(ingredientName: String, limit: Int = 10) -> [FoodCandidate] {
        let terms = FoodSearch.terms(for: ingredientName)
        guard !terms.isEmpty else { return [] }
        var hits = searchFTS(FoodSearch.ftsQuery(terms: terms, all: true), limit: 40)
        if hits.count < limit {
            let seen = Set(hits.map(\.fdcID))
            hits += searchFTS(FoodSearch.ftsQuery(terms: terms, all: false), limit: 40).filter { !seen.contains($0.fdcID) }
        }
        return Array(FoodSearch.rerank(hits, ingredientName: ingredientName).prefix(limit))
    }

    /// Free-text search for the manual food picker.
    public func search(text: String, limit: Int = 30) -> [FoodCandidate] {
        let terms = FoodSearch.terms(for: text)
        guard !terms.isEmpty else { return [] }
        let hits = searchFTS(FoodSearch.ftsQuery(terms: terms, all: true), limit: limit)
        return hits.isEmpty ? searchFTS(FoodSearch.ftsQuery(terms: terms, all: false), limit: limit) : hits
    }

    public func searchFTS(_ match: String, limit: Int) -> [FoodCandidate] {
        let sql = """
            SELECT f.fdc_id, f.description FROM food_fts
            JOIN food f ON f.fdc_id = food_fts.fdc_id
            WHERE food_fts MATCH ?1 ORDER BY bm25(food_fts) LIMIT ?2
            """
        return query(sql, bind: { statement in
            Self.bindText(statement, 1, match)
            sqlite3_bind_int(statement, 2, Int32(limit))
        }) { statement in
            FoodCandidate(fdcID: Int(sqlite3_column_int64(statement, 0)), description: Self.text(statement, 1) ?? "")
        }
    }

    public func food(id: Int) -> FoodRecord? {
        let sql = """
            SELECT f.fdc_id, f.description, f.data_type, f.category,
                   m.kcal, m.kcal_source, m.protein, m.fat, m.carbs, m.fiber, m.sugar
            FROM food f JOIN macro m ON m.fdc_id = f.fdc_id WHERE f.fdc_id = ?1
            """
        let records = query(sql, bind: { sqlite3_bind_int64($0, 1, sqlite3_int64(id)) }) { s in
            FoodRecord(
                fdcID: Int(sqlite3_column_int64(s, 0)),
                description: Self.text(s, 1) ?? "",
                dataType: Self.text(s, 2) ?? "",
                category: Self.text(s, 3) ?? "",
                nutrients: FoodNutrients(
                    kcal: Self.double(s, 4),
                    kcalSource: Self.text(s, 5) ?? "missing",
                    protein: Self.double(s, 6),
                    fat: Self.double(s, 7),
                    carbs: Self.double(s, 8),
                    fiber: Self.double(s, 9),
                    sugar: Self.double(s, 10)
                )
            )
        }
        guard var record = records.first else { return nil }
        record.portions = query(
            "SELECT amount, unit_text, grams FROM portion WHERE fdc_id = ?1",
            bind: { sqlite3_bind_int64($0, 1, sqlite3_int64(id)) }
        ) { s in
            FoodPortion(amount: sqlite3_column_double(s, 0), unitText: Self.text(s, 1) ?? "", grams: sqlite3_column_double(s, 2))
        }
        return record
    }

    public func food(description: String) -> FoodRecord? {
        let ids = query("SELECT fdc_id FROM food WHERE description = ?1 LIMIT 1",
                        bind: { Self.bindText($0, 1, description) }) { Int(sqlite3_column_int64($0, 0)) }
        return ids.first.flatMap(food(id:))
    }

    public func metadata() -> [String: String] {
        let pairs = query("SELECT key, value FROM meta", bind: { _ in }) { s in
            (Self.text(s, 0) ?? "", Self.text(s, 1) ?? "")
        }
        var result = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        let count = query("SELECT COUNT(*) FROM food", bind: { _ in }) { Int(sqlite3_column_int64($0, 0)) }
        result["food_count"] = count.first.map(String.init) ?? "0"
        return result
    }

    // MARK: - SQLite helpers

    private func query<T>(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        row: (OpaquePointer) -> T
    ) -> [T] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(row(statement))
        }
        return rows
    }

    private static func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        // SQLITE_TRANSIENT: SQLite copies the string.
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private static func double(_ statement: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
    }
}
