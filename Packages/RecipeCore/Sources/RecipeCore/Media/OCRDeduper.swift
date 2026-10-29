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
                let duplicate = keptNormalized.contains {
                    $0 == normalized || TextMatching.similarity($0, normalized) >= similarityThreshold
                }
                if duplicate { continue }
                kept.append(OCRLine(time: frame.time, text: text, confidence: line.confidence))
                keptNormalized.append(normalized)
            }
        }
        return kept
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
