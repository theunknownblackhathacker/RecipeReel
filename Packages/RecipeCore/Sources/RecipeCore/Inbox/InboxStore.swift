import Foundation

public enum InboxError: Error, LocalizedError, Sendable, Equatable {
    case itemNotFound(UUID)
    case emptyCaption

    public var errorDescription: String? {
        switch self {
        case .itemNotFound(let id): "Imported item \(id.uuidString) no longer exists."
        case .emptyCaption: "The caption is empty."
        }
    }
}

/// A folder of `InboxItem`s. Used twice:
/// - the shared App Group inbox (written by the share extension, emptied by the app), and
/// - the app's own local import library.
///
/// Every write goes into a hidden staging folder first and is renamed into place only
/// after the manifest is written, so a half-finished copy (e.g. the extension being killed)
/// is never seen as a valid item.
public struct InboxStore: Sendable {
    public static let manifestFileName = "manifest.json"

    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    // MARK: - Adding

    /// Copies (or moves) a video into a new item.
    @discardableResult
    public func addVideo(
        from sourceURL: URL,
        caption: String? = nil,
        sourceLink: URL? = nil,
        origin: InboxItem.Origin,
        moveFile: Bool = false,
        now: Date = Date()
    ) throws -> InboxItem {
        let id = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
        let fileName = "video.\(ext)"
        return try writeNewItem(id: id) { staging in
            let destination = staging.appending(path: fileName)
            try Self.transfer(sourceURL, to: destination, move: moveFile)
            return InboxItem(
                id: id,
                createdAt: now,
                origin: origin,
                kind: .video,
                videoFileName: fileName,
                videoByteCount: Self.byteCount(of: destination),
                sourceLink: sourceLink,
                caption: Self.clean(caption)
            )
        }
    }

    /// Stores a link-only share (nothing is downloaded).
    @discardableResult
    public func addLink(
        _ link: URL,
        caption: String? = nil,
        origin: InboxItem.Origin,
        now: Date = Date()
    ) throws -> InboxItem {
        let id = UUID()
        return try writeNewItem(id: id) { _ in
            InboxItem(id: id, createdAt: now, origin: origin, kind: .linkOnly,
                      sourceLink: link, caption: Self.clean(caption))
        }
    }

    /// Stores pasted caption text on its own.
    @discardableResult
    public func addCaption(
        _ caption: String,
        origin: InboxItem.Origin,
        now: Date = Date()
    ) throws -> InboxItem {
        guard let text = Self.clean(caption) else { throw InboxError.emptyCaption }
        let id = UUID()
        return try writeNewItem(id: id) { _ in
            InboxItem(id: id, createdAt: now, origin: origin, kind: .captionOnly, caption: text)
        }
    }

    // MARK: - Reading

    /// All valid items, newest first. Unreadable folders are skipped.
    public func items() throws -> [InboxItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootURL.path(percentEncoded: false)) else { return [] }
        let folders = try fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var result: [InboxItem] = []
        for folder in folders {
            let manifestURL = folder.appending(path: Self.manifestFileName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let item = try? JSONDecoder().decode(InboxItem.self, from: data)
            else { continue }
            result.append(item)
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    public func item(id: UUID) throws -> InboxItem {
        let manifestURL = directoryURL(for: id).appending(path: Self.manifestFileName)
        guard let data = try? Data(contentsOf: manifestURL) else { throw InboxError.itemNotFound(id) }
        return try JSONDecoder().decode(InboxItem.self, from: data)
    }

    public func directoryURL(for id: UUID) -> URL {
        rootURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    public func videoURL(for item: InboxItem) -> URL? {
        item.videoFileName.map { directoryURL(for: item.id).appending(path: $0) }
    }

    // MARK: - Changing

    @discardableResult
    public func updateCaption(_ caption: String?, for id: UUID) throws -> InboxItem {
        var current = try item(id: id)
        current.caption = Self.clean(caption)
        try Self.writeManifest(current, in: directoryURL(for: id))
        return current
    }

    public func delete(id: UUID) throws {
        let folder = directoryURL(for: id)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            throw InboxError.itemNotFound(id)
        }
        try FileManager.default.removeItem(at: folder)
    }

    /// Moves every valid item into another store (shared inbox → local library).
    /// Returns the items that were moved.
    @discardableResult
    public func moveAll(to destination: InboxStore) throws -> [InboxItem] {
        let fm = FileManager.default
        let pending = try items()
        guard !pending.isEmpty else { return [] }
        try destination.ensureRoot()
        var moved: [InboxItem] = []
        for item in pending {
            let source = directoryURL(for: item.id)
            let target = destination.directoryURL(for: item.id)
            if fm.fileExists(atPath: target.path(percentEncoded: false)) {
                // Already imported earlier (e.g. app was killed mid-move): drop the duplicate.
                try? fm.removeItem(at: source)
                continue
            }
            try fm.moveItem(at: source, to: target)
            moved.append(item)
        }
        return moved
    }

    // MARK: - Internals

    func ensureRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func writeNewItem(id: UUID, _ build: (URL) throws -> InboxItem) throws -> InboxItem {
        let fm = FileManager.default
        try ensureRoot()
        let staging = rootURL.appending(path: ".incoming-\(id.uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let item = try build(staging)
            try Self.writeManifest(item, in: staging)
            try fm.moveItem(at: staging, to: directoryURL(for: id))
            return item
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private static func writeManifest(_ item: InboxItem, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(item)
        try data.write(to: folder.appending(path: manifestFileName), options: .atomic)
    }

    private static func transfer(_ source: URL, to destination: URL, move: Bool) throws {
        let fm = FileManager.default
        if move {
            do {
                try fm.moveItem(at: source, to: destination)
                return
            } catch {
                // Moving can fail across volumes or for read-only sources; fall back to a copy.
            }
        }
        try fm.copyItem(at: source, to: destination)
    }

    private static func byteCount(of url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
