import Foundation

/// One imported thing waiting to become a recipe: a video, a link-only share, or a pasted caption.
/// Stored on disk as `<inbox>/<id>/manifest.json`, next to the video file (if any).
public struct InboxItem: Codable, Sendable, Identifiable, Hashable {

    /// How the item got into the app.
    public enum Origin: String, Codable, Sendable, CaseIterable {
        case shareExtension
        case photosPicker
        case openIn
        case captionPaste
    }

    /// What the item contains.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A video file (optionally with a caption and/or the original link).
        case video
        /// Only a URL arrived (typical for Instagram). Never downloaded — the user must save/screen-record the Reel.
        case linkOnly
        /// Only pasted caption text.
        case captionOnly
    }

    public var id: UUID
    public var createdAt: Date
    public var origin: Origin
    public var kind: Kind
    /// File name of the video inside the item's folder, e.g. `video.mov`.
    public var videoFileName: String?
    public var videoByteCount: Int64?
    /// The link that was shared (e.g. an Instagram Reel URL). Informational only.
    public var sourceLink: URL?
    public var caption: String?
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        origin: Origin,
        kind: Kind,
        videoFileName: String? = nil,
        videoByteCount: Int64? = nil,
        sourceLink: URL? = nil,
        caption: String? = nil,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.createdAt = createdAt
        self.origin = origin
        self.kind = kind
        self.videoFileName = videoFileName
        self.videoByteCount = videoByteCount
        self.sourceLink = sourceLink
        self.caption = caption
        self.schemaVersion = schemaVersion
    }
}
