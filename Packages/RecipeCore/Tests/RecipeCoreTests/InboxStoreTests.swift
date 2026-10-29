import Foundation
import Testing
@testable import RecipeCore

@Suite("InboxStore")
struct InboxStoreTests {

    /// A fresh temporary folder per test.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "RecipeCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFakeVideo(in dir: URL, ext: String = "mp4", bytes: Int = 1024) throws -> URL {
        let url = dir.appending(path: "source.\(ext)")
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    @Test func addVideoCopiesFileAndWritesManifest() throws {
        let tmp = try makeTempDir()
        let store = InboxStore(rootURL: tmp.appending(path: "Inbox"))
        let source = try makeFakeVideo(in: tmp, ext: "MP4", bytes: 2048)

        let item = try store.addVideo(from: source, caption: "  200g oats \n", origin: .photosPicker)

        #expect(item.kind == .video)
        #expect(item.videoFileName == "video.mp4")
        #expect(item.videoByteCount == 2048)
        #expect(item.caption == "200g oats")
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)), "copy must keep the source")
        let stored = try #require(store.videoURL(for: item))
        #expect(FileManager.default.fileExists(atPath: stored.path(percentEncoded: false)))
        #expect(try store.items().map(\.id) == [item.id])
    }

    @Test func addVideoCanMoveTheSource() throws {
        let tmp = try makeTempDir()
        let store = InboxStore(rootURL: tmp.appending(path: "Inbox"))
        let source = try makeFakeVideo(in: tmp, ext: "mov")

        let item = try store.addVideo(from: source, origin: .openIn, moveFile: true)

        #expect(!FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        #expect(item.videoFileName == "video.mov")
    }

    @Test func linkAndCaptionItems() throws {
        let tmp = try makeTempDir()
        let store = InboxStore(rootURL: tmp)
        let link = try #require(URL(string: "https://www.instagram.com/reel/abc123/"))

        let linkItem = try store.addLink(link, caption: nil, origin: .shareExtension,
                                         now: Date(timeIntervalSince1970: 100))
        let captionItem = try store.addCaption("80g rolled oats", origin: .captionPaste,
                                               now: Date(timeIntervalSince1970: 200))

        #expect(linkItem.kind == .linkOnly)
        #expect(linkItem.sourceLink == link)
        #expect(captionItem.kind == .captionOnly)
        // Newest first.
        #expect(try store.items().map(\.id) == [captionItem.id, linkItem.id])
    }

    @Test func emptyCaptionIsRejected() throws {
        let store = InboxStore(rootURL: try makeTempDir())
        #expect(throws: InboxError.emptyCaption) {
            try store.addCaption("   \n ", origin: .captionPaste)
        }
    }

    @Test func updateCaptionAndDelete() throws {
        let tmp = try makeTempDir()
        let store = InboxStore(rootURL: tmp)
        let item = try store.addCaption("old", origin: .captionPaste)

        let updated = try store.updateCaption("new caption", for: item.id)
        #expect(updated.caption == "new caption")
        #expect(try store.item(id: item.id).caption == "new caption")

        try store.delete(id: item.id)
        #expect(try store.items().isEmpty)
        #expect(throws: InboxError.itemNotFound(item.id)) {
            try store.delete(id: item.id)
        }
    }

    @Test func moveAllTransfersItemsBetweenStores() throws {
        let tmp = try makeTempDir()
        let shared = InboxStore(rootURL: tmp.appending(path: "Shared"))
        let local = InboxStore(rootURL: tmp.appending(path: "Local"))
        let video = try shared.addVideo(from: try makeFakeVideo(in: tmp), origin: .shareExtension)
        let caption = try shared.addCaption("caption", origin: .shareExtension)

        let moved = try shared.moveAll(to: local)

        #expect(Set(moved.map(\.id)) == [video.id, caption.id])
        #expect(try shared.items().isEmpty)
        #expect(Set(try local.items().map(\.id)) == [video.id, caption.id])
        let movedVideo = try #require(local.videoURL(for: video))
        #expect(FileManager.default.fileExists(atPath: movedVideo.path(percentEncoded: false)))
        // Nothing left to move.
        #expect(try shared.moveAll(to: local).isEmpty)
    }

    @Test func halfWrittenStagingFoldersAreIgnored() throws {
        let tmp = try makeTempDir()
        let store = InboxStore(rootURL: tmp)
        try FileManager.default.createDirectory(
            at: tmp.appending(path: ".incoming-\(UUID().uuidString)"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: tmp.appending(path: "not-an-item"),
            withIntermediateDirectories: true
        )
        #expect(try store.items().isEmpty)
    }

    @Test func missingRootMeansNoItems() throws {
        let store = InboxStore(rootURL: try makeTempDir().appending(path: "does-not-exist"))
        #expect(try store.items().isEmpty)
    }
}
