import Foundation
import RecipeCore

extension InboxItem.Kind {
    var displayName: String {
        switch self {
        case .video: "Video"
        case .linkOnly: "Link only"
        case .captionOnly: "Caption"
        }
    }

    var systemImage: String {
        switch self {
        case .video: "film"
        case .linkOnly: "link"
        case .captionOnly: "text.quote"
        }
    }
}

extension InboxItem.Origin {
    var displayName: String {
        switch self {
        case .shareExtension: "Share sheet"
        case .photosPicker: "Photos picker"
        case .openIn: "Open in"
        case .captionPaste: "Pasted caption"
        }
    }
}

extension InboxItem {
    /// First line of the caption, or the kind name.
    var title: String {
        if let first = caption?.split(separator: "\n").first {
            return String(first)
        }
        return kind.displayName
    }

    var sizeText: String? {
        videoByteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}
