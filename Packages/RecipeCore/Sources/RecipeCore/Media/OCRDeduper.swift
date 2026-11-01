import Foundation

/// Turns per-frame OCR results into a clean, time-ordered list of unique lines.
///
/// Overlays stay on screen for several sampled frames, and recipe lists are often shown twice
/// (e.g. at the start and the end), so a line is kept only the first time it appears.
/// Near-identical OCR variants ("200g chicken breast" / "200g chicken breas") count as the same line.
public enum OCRDeduper {

    public static func merge(
        _ frames: [OCRFrame],
        minimumConfidence: Double = 0.3,
        similarityThreshold: Double = 0.88
    ) -> [OCRLine] {
        var kept: [OCRLine] = []
        var keptNormalized: [String] = []
        for frame in frames.sorted(by: { $0.time < $1.time }) {
            for line in frame.lines {
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.confidence >= minimumConfidence, isUseful(text) else { continue }
                let normalized = TextMatching.normalize(text)
                guard !normalized.isEmpty else { continue }
                if isDuplicate(normalized, of: keptNormalized, threshold: similarityThreshold) { continue }
                kept.append(OCRLine(time: frame.time, text: text, confidence: line.confidence))
                keptNormalized.append(normalized)
            }
        }
        return kept
    }

    /// Same text, a misread of text already kept, or a piece of it.
    /// Lines with numbers (amounts, times) must match closely; title-like lines without numbers are
    /// treated as misreads of a kept line when roughly similar ("Parato Bread" → "Potato Bread").
    static func isDuplicate(_ line: String, of kept: [String], threshold: Double) -> Bool {
        let hasDigits = line.contains { $0.isNumber }
        let words = Set(line.split(separator: " ").map(String.init))
        for other in kept {
            if other == line { return true }
            let similarity = TextMatching.similarity(other, line)
            if similarity >= threshold { return true }
            if !hasDigits {
                let otherWords = Set(other.split(separator: " ").map(String.init))
                // Fragment of a kept line ("Potato", "Bread" after "Potato Bread").
                if !words.isEmpty, words.isSubset(of: otherWords) { return true }
                // Misread: similar overall, and every longer word resembles a word of the kept line
                // ("cho sy garuc" → "cheesy garlic"), but "mix the sugar" ≠ "mix the flour".
                if similarity >= 0.66, wordsResemble(words, otherWords) { return true }
            }
        }
        return false
    }

    static func wordsResemble(_ words: Set<String>, _ others: Set<String>) -> Bool {
        let long = words.filter { $0.count >= 4 }
        guard !long.isEmpty else { return true }
        return long.allSatisfy { word in
            others.contains { TextMatching.similarity($0, word) >= 0.5 }
        }
    }

    /// Skips text that never carries recipe information: handles, hashtags-only lines,
    /// single characters, and long runs of symbols.
    static func isUseful(_ text: String) -> Bool {
        guard text.count >= 2 else { return false }
        if text.hasPrefix("@") { return false }
        let words = text.split(separator: " ")
        if !words.isEmpty, words.allSatisfy({ $0.hasPrefix("#") }) { return false }
        let letters = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        return Double(letters) / Double(text.unicodeScalars.count) >= 0.4
    }
}
