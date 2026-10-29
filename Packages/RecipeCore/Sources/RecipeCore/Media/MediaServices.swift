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
        guard !audioTracks.isEmpty else { return [] }

        try await Self.ensureAuthorization()
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
        }

        status("Extracting audio…")
        let audioURL = try await Self.exportAudio(from: asset)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let audioFile = try AVAudioFile(forReading: audioURL)

        status("Transcribing…")
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // TODO: bias recognition with `contextualWords` via AnalysisContext once its API is verified
        // (apple-api-notes.md: analyzer.setContext(_:) with contextualStrings).

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
