import AVFoundation
import Foundation
import Speech
import Vision

// MARK: - Protocols (mocked in tests; the real implementations only run on the iPhone)

public protocol TranscriptionService: Sendable {
    /// Speech in the video, as time-ordered segments. Empty when there's no speech.
    /// `status` receives short human-readable updates (e.g. "Downloading speech model…").
    func transcribe(videoURL: URL, status: @escaping @Sendable (String) -> Void) async throws -> [TranscriptSegment]
}

public protocol FrameOCRService: Sendable {
    /// On-screen text, de-duplicated, with the time each line first appeared.
    func readText(videoURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [OCRLine]
}

public enum MediaError: LocalizedError, Sendable {
    case speechUnavailable
    case localeUnsupported(String)
    case audioExportFailed(String)
    case speechNotAuthorized

    public var errorDescription: String? {
        switch self {
        case .speechUnavailable: "On-device speech recognition isn't available on this device."
        case .localeUnsupported(let id): "Speech recognition doesn't support \(id) on this device."
        case .audioExportFailed(let reason): "Couldn't extract the audio: \(reason)"
        case .speechNotAuthorized: "Speech recognition permission was denied (Settings → RecipeReel)."
        }
    }
}

// MARK: - Speech (SpeechAnalyzer + SpeechTranscriber, iOS 26+)

/// Transcribes the video's audio entirely on-device.
/// Steps: export the audio track to .m4a → open as AVAudioFile → SpeechAnalyzer with a SpeechTranscriber.
public struct SpeechTranscriptionService: TranscriptionService {
    public let localeIdentifier: String
    /// Words to bias recognition towards (units, common ingredients).
    public let contextualWords: [String]

    public init(localeIdentifier: String = "en-US", contextualWords: [String] = CookingVocabulary.words) {
        self.localeIdentifier = localeIdentifier
        self.contextualWords = contextualWords
    }

    public func transcribe(videoURL: URL, status: @escaping @Sendable (String) -> Void) async throws -> [TranscriptSegment] {
        let asset = AVURLAsset(url: videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            status("no audio track")
            return []
        }

        try await Self.ensureAuthorization()
        status("permission ok")

        status("Extracting audio…")
        let audioURL = try await Self.exportAudio(from: asset)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let audioFile = try AVAudioFile(forReading: audioURL)
        let seconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        status("audio \(String(format: "%.1f", seconds))s")

        // 1. SpeechAnalyzer (iOS 26+).
        var segments: [TranscriptSegment] = []
        do {
            segments = try await analyze(audioFile: audioFile, status: status)
            status("SpeechAnalyzer: \(segments.count) segments")
        } catch {
            status("SpeechAnalyzer failed: \(error.localizedDescription)")
        }

        // 2. Fallback: the older on-device recognizer, when nothing was heard in more than a few seconds of audio.
        if segments.isEmpty, seconds > 3 {
            do {
                segments = try await Self.recognizeOnDevice(audioURL: audioURL, localeIdentifier: localeIdentifier)
                status("SFSpeechRecognizer: \(segments.count) segments")
            } catch {
                status("SFSpeechRecognizer: \(error.localizedDescription)")
            }
        }
        if let first = segments.first {
            status("heard: \(first.text.prefix(60))")
        }
        return segments
    }

    private func analyze(audioFile: AVAudioFile, status: @escaping @Sendable (String) -> Void) async throws -> [TranscriptSegment] {
        guard SpeechTranscriber.isAvailable else { throw MediaError.speechUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw MediaError.localeUnsupported(localeIdentifier)
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status("Downloading speech model…")
            try await request.downloadAndInstall()
            status("speech model installed")
        } else {
            status("speech model ready (\(locale.identifier))")
        }

        status("Transcribing…")
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Start reading results before feeding audio, or the stream can stall.
        let collector = Task { () throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let range = result.range
                segments.append(TranscriptSegment(
                    start: range.start.seconds.isFinite ? range.start.seconds : 0,
                    end: range.end.seconds.isFinite ? range.end.seconds : 0,
                    text: text
                ))
            }
            return segments
        }
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collector.value.sorted { $0.start < $1.start }
    }

    /// On-device SFSpeechRecognizer on an audio file. Words are grouped into segments at pauses > 0.8 s.
    static func recognizeOnDevice(audioURL: URL, localeIdentifier: String) async throws -> [TranscriptSegment] {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw MediaError.localeUnsupported(localeIdentifier)
        }
        guard recognizer.supportsOnDeviceRecognition else { throw MediaError.speechUnavailable }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let words: [(String, Double, Double)] = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let items = result.bestTranscription.segments.map { ($0.substring, $0.timestamp, $0.duration) }
                    if once.claim() { continuation.resume(returning: items) }
                } else if let error {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
        }
        return group(words: words)
    }

    static func group(words: [(String, Double, Double)]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [String] = []
        var start = 0.0
        var end = 0.0
        for (word, timestamp, duration) in words {
            if !current.isEmpty, timestamp - end > 0.8 {
                segments.append(TranscriptSegment(start: start, end: end, text: current.joined(separator: " ")))
                current = []
            }
            if current.isEmpty { start = timestamp }
            current.append(word)
            end = timestamp + duration
        }
        if !current.isEmpty {
            segments.append(TranscriptSegment(start: start, end: end, text: current.joined(separator: " ")))
        }
        return segments
    }

    static func ensureAuthorization() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            if status != .authorized { throw MediaError.speechNotAuthorized }
        default:
            throw MediaError.speechNotAuthorized
        }
    }

    static func exportAudio(from asset: AVURLAsset) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaError.audioExportFailed("no export session for this video")
        }
        let output = URL.temporaryDirectory.appending(path: "audio-\(UUID().uuidString).m4a")
        do {
            try await session.export(to: output, as: .m4a)
        } catch {
            throw MediaError.audioExportFailed(error.localizedDescription)
        }
        return output
    }
}

/// Makes sure a continuation is resumed only once.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - Vision OCR (RecognizeTextRequest, iOS 18+)

/// Samples one frame every `interval` seconds and reads overlay text with Vision.
public struct VisionFrameOCRService: FrameOCRService {
    public let interval: Double
    public let customWords: [String]

    public init(interval: Double = 1.0, customWords: [String] = CookingVocabulary.words) {
        self.interval = interval
        self.customWords = customWords
    }

    public func readText(videoURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [OCRLine] {
        let asset = AVURLAsset(url: videoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { return [] }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true   // portrait Reels stay upright
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let tolerance = CMTime(seconds: min(0.4, interval / 2), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        request.usesLanguageCorrection = true
        request.customWords = customWords
        request.minimumTextHeightFraction = 0.015

        var frames: [OCRFrame] = []
        var time = min(0.5, duration / 2)
        while time < duration {
            try Task.checkCancellation()
            if let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) {
                let observations = (try? await request.perform(on: frame.image)) ?? []
                let lines = observations.compactMap { observation -> OCRFrame.Line? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return OCRFrame.Line(text: candidate.string, confidence: Double(candidate.confidence))
                }
                let seconds = frame.actualTime.seconds.isFinite ? frame.actualTime.seconds : time
                frames.append(OCRFrame(time: seconds, lines: lines))
            }
            progress(min(1, time / duration))
            time += interval
        }
        progress(1)
        return OCRDeduper.merge(frames)
    }
}

/// Words that help speech recognition and OCR with recipe vocabulary.
public enum CookingVocabulary {
    public static let words: [String] = [
        "tbsp", "tsp", "g", "kg", "ml", "oz", "lb", "°C", "°F",
        "tablespoon", "teaspoon", "gram", "grams", "cup", "cups", "pinch", "clove", "cloves",
        "tahini", "feta", "halloumi", "gochujang", "sriracha", "harissa", "miso", "quinoa", "bulgur",
        "chia", "whey", "skyr", "ricotta", "mascarpone", "parmesan", "mozzarella", "burrata",
        "basmati", "jasmine", "orzo", "gnocchi", "edamame", "tofu", "tempeh", "paprika", "cumin",
        "turmeric", "oregano", "zaatar", "sumac", "cardamom", "cinnamon", "nutmeg", "cayenne",
        "chipotle", "jalapeño", "zucchini", "courgette", "aubergine", "scallion", "shallot",
        "air fryer", "preheat", "sear", "simmer", "marinate", "baste", "sauté"
    ]
}
