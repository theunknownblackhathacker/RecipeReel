import Foundation

/// Small text helpers shared by OCR de-duplication, quote checks and food search.
public enum TextMatching {

    /// Lowercased, accents folded, punctuation → spaces, whitespace collapsed.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "/" || scalar == "." || scalar == "°" {
                scalars.append(scalar)
            } else {
                scalars.append(" ")
            }
        }
        return String(scalars)
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func tokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    /// Levenshtein similarity in 0...1 (1 = identical).
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    /// True when `quote` is (approximately) contained in `source`: most of its words appear in the
    /// source, and most of its word pairs appear in the same order. Used to drop invented steps.
    public static func quoteAppears(_ quote: String, in source: String) -> Bool {
        let quoteTokens = tokens(quote)
        guard !quoteTokens.isEmpty else { return false }
        let sourceTokens = tokens(source)
        let sourceSet = Set(sourceTokens)
        let fuzzyHit: (String) -> Bool = { token in
            if sourceSet.contains(token) { return true }
            guard token.count >= 5 else { return false }
            return sourceSet.contains { $0.count >= 4 && similarity($0, token) >= 0.8 }
        }
        let wordCoverage = Double(quoteTokens.filter(fuzzyHit).count) / Double(quoteTokens.count)
        if quoteTokens.count == 1 { return wordCoverage == 1 }
        guard wordCoverage >= 0.75 else { return false }

        let sourcePairs = Set(zip(sourceTokens, sourceTokens.dropFirst()).map { "\($0) \($1)" })
        let quotePairs = zip(quoteTokens, quoteTokens.dropFirst()).map { "\($0) \($1)" }
        let pairCoverage = Double(quotePairs.filter(sourcePairs.contains).count) / Double(quotePairs.count)
        return pairCoverage >= 0.5
    }
}
