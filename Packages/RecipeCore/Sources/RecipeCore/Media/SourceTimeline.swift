import Foundation

/// All text collected for one video — caption, on-screen text and speech — merged in time order.
/// This is what the model reads (as untrusted data in the prompt, never in instructions).
public struct SourceTimeline: Codable, Sendable, Equatable {
    public var caption: String?
    public var spoken: [TranscriptSegment]
    public var onScreen: [OCRLine]

    public init(caption: String?, spoken: [TranscriptSegment], onScreen: [OCRLine]) {
        self.caption = caption
        self.spoken = spoken
        self.onScreen = onScreen
    }

    public var isEmpty: Bool {
        (caption?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && spoken.isEmpty && onScreen.isEmpty
    }

    /// One labelled line per piece of text: caption lines first, then on-screen and spoken text
    /// interleaved by time, e.g. `[0:12] SCREEN: 200g flour`.
    public var lines: [String] {
        var result: [String] = []
        if let caption {
            let captionLines = caption
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            result += captionLines.map { "CAPTION: \($0)" }
        }
        let timed: [(Double, Int, String)] =
            onScreen.map { ($0.time, 0, "[\(Self.clock($0.time))] SCREEN: \($0.text)") }
            + spoken.map { ($0.start, 1, "[\(Self.clock($0.start))] VOICE: \($0.text)") }
        result += timed.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
        return result
    }

    /// The whole source as one string (used for prompts and quote matching).
    public var text: String { lines.joined(separator: "\n") }

    /// Plain source text without labels, for checking that quotes really appear in the source.
    public var plainText: String {
        var parts: [String] = []
        if let caption { parts.append(caption) }
        parts += onScreen.map(\.text)
        parts += spoken.map(\.text)
        return parts.joined(separator: "\n")
    }

    /// Splits the labelled lines into chunks of at most `maxCharacters`, keeping order.
    /// A single line longer than the limit is split on word boundaries.
    public func chunks(maxCharacters: Int) -> [String] {
        Self.chunk(lines: lines, maxCharacters: maxCharacters)
    }

    static func chunk(lines: [String], maxCharacters: Int) -> [String] {
        precondition(maxCharacters > 20)
        var pieces: [String] = []
        for line in lines {
            if line.count <= maxCharacters {
                pieces.append(line)
            } else {
                var current = ""
                for word in line.split(separator: " ") {
                    if current.count + word.count + 1 > maxCharacters, !current.isEmpty {
                        pieces.append(current)
                        current = ""
                    }
                    current += current.isEmpty ? String(word) : " " + word
                }
                if !current.isEmpty { pieces.append(current) }
            }
        }
        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            if !current.isEmpty, current.count + piece.count + 1 > maxCharacters {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? piece : "\n" + piece
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
