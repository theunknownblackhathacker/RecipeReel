import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A frame from the video, sent to a vision-capable cloud model when the text has no method.
public struct KeyFrame: Sendable, Equatable {
    public var time: Double
    public var jpeg: Data

    public init(time: Double, jpeg: Data) {
        self.time = time
        self.jpeg = jpeg
    }
}

public protocol KeyFrameProviding: Sendable {
    func keyFrames(videoURL: URL, maxFrames: Int) async throws -> [KeyFrame]
}

/// Picks frames where the picture changes (new action), up to `maxFrames`, in time order.
/// Pure logic, unit-tested in CI.
public enum KeyFrameSelector {

    /// `differences[i]` = how much sample i differs from sample i-1 (0…1); sample 0 has no previous.
    /// Returns sample indices to keep, sorted.
    public static func select(differences: [Double], maxFrames: Int, minimumGapSamples: Int = 2) -> [Int] {
        let count = differences.count
        guard count > 0, maxFrames > 0 else { return [] }
        if count <= maxFrames { return Array(0..<count) }

        // Biggest changes first, keeping some spacing so one cut doesn't fill the budget.
        var chosen: [Int] = [0]
        let ranked = differences.indices.dropFirst().sorted { differences[$0] > differences[$1] }
        for index in ranked where chosen.count < maxFrames {
            guard differences[index] > 0.04 else { break }
            if chosen.allSatisfy({ abs($0 - index) >= minimumGapSamples }) {
                chosen.append(index)
            }
        }
        // Too few cuts (one long shot): fill evenly across the video.
        if chosen.count < maxFrames {
            let slots = maxFrames - chosen.count
            for k in 1...slots {
                let index = min(count - 1, Int((Double(k) * Double(count) / Double(slots + 1)).rounded()))
                if !chosen.contains(where: { abs($0 - index) < max(1, minimumGapSamples / 2) }) {
                    chosen.append(index)
                }
            }
        }
        return Array(Set(chosen)).sorted().prefix(maxFrames).map { $0 }
    }

    /// Mean absolute difference of two equal-size grayscale thumbnails, 0…1.
    public static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var total = 0
        for i in a.indices { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count) / 255
    }
}

/// Samples the video every half second, picks the frames where the scene changes, and returns them
/// as JPEGs (long side `maxPixel`, enough for a model to see what's happening).
public struct VideoKeyFrameProvider: KeyFrameProviding {
    public let sampleInterval: Double
    public let maxPixel: CGFloat

    public init(sampleInterval: Double = 0.5, maxPixel: CGFloat = 768) {
        self.sampleInterval = sampleInterval
        self.maxPixel = maxPixel
    }

    public func keyFrames(videoURL: URL, maxFrames: Int) async throws -> [KeyFrame] {
        let asset = AVURLAsset(url: videoURL)
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { return [] }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let tolerance = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var times: [Double] = []
        var images: [CGImage] = []
        var thumbnails: [[UInt8]] = []
        var t = min(0.3, duration / 2)
        while t < duration {
            try Task.checkCancellation()
            if let frame = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)),
               let thumb = Self.grayThumbnail(frame.image) {
                times.append(frame.actualTime.seconds.isFinite ? frame.actualTime.seconds : t)
                images.append(frame.image)
                thumbnails.append(thumb)
            }
            t += sampleInterval
        }
        guard !images.isEmpty else { return [] }

        var differences: [Double] = [0]
        for i in 1..<thumbnails.count {
            differences.append(KeyFrameSelector.difference(thumbnails[i - 1], thumbnails[i]))
        }
        let minimumGap = max(1, Int((1.0 / sampleInterval).rounded()))
        return KeyFrameSelector.select(differences: differences, maxFrames: maxFrames, minimumGapSamples: minimumGap)
            .compactMap { index in
                Self.jpeg(images[index]).map { KeyFrame(time: times[index], jpeg: $0) }
            }
    }

    /// 32×32 grayscale pixels.
    static func grayThumbnail(_ image: CGImage) -> [UInt8]? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? pixels : nil
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.6) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
