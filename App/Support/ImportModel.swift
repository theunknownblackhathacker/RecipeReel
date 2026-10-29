import Foundation
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import RecipeCore

/// App-side state for importing: the local library of imported items, plus the
/// App Group inbox the share extension writes into.
@MainActor
@Observable
final class ImportModel {
    private(set) var items: [InboxItem] = []
    private(set) var busyMessage: String?
    var errorMessage: String?

    /// Drives the error alert.
    var showingError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    let install: InstallInfo
    let shared: SharedContainer
    let log: DiagnosticsLog
    private let localStore: InboxStore

    init() {
        let install = InstallInfo.current()
        self.install = install
        self.log = AppLog.shared
        self.localStore = InboxStore(rootURL: AppPaths.importsRoot)
        self.shared = SharedContainer.resolve(profileGroups: install.appProfile?.appGroups ?? [])

        log.log("app", "Launch v\(install.version) (\(install.build)), bundle \(install.appBundleID)")
        if shared.isAvailable {
            log.log("appgroup", "Available: \(shared.groupIdentifier)")
        } else {
            log.log("appgroup", "Unavailable: \(shared.problem ?? "unknown reason")")
        }
        refresh()
    }

    // MARK: - Reading

    func refresh() {
        do {
            items = try localStore.items()
        } catch {
            log.log("library", "Failed to read imports: \(error.localizedDescription)")
            items = []
        }
    }

    func videoURL(for item: InboxItem) -> URL? {
        localStore.videoURL(for: item)
    }

    /// Number of items still waiting in the shared inbox (normally 0 after `collectSharedInbox`).
    func pendingSharedCount() -> Int {
        guard let inboxURL = shared.inboxURL else { return 0 }
        return (try? InboxStore(rootURL: inboxURL).items().count) ?? 0
    }

    // MARK: - Share extension handoff

    func collectSharedInbox() {
        guard let inboxURL = shared.inboxURL else { return }
        do {
            let moved = try InboxStore(rootURL: inboxURL).moveAll(to: localStore)
            for item in moved {
                log.log("import", "Collected from share extension: \(item.kind.rawValue) \(item.id.uuidString.prefix(8))")
            }
        } catch {
            log.log("import", "Collecting shared inbox failed: \(error.localizedDescription)")
            errorMessage = "Couldn't collect shared items: \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - Importing

    func importPicked(_ pickerItem: PhotosPickerItem) async {
        busyMessage = "Importing video…"
        defer { busyMessage = nil }
        let started = Date()
        do {
            guard let movie = try await pickerItem.loadTransferable(type: PickedMovie.self) else {
                throw ImportFailure.noVideo
            }
            let store = localStore
            let item = try await Task.detached {
                try store.addVideo(from: movie.url, origin: .photosPicker, moveFile: true)
            }.value
            log.log("import", "PhotosPicker video \(Self.describe(item)) in \(Self.seconds(since: started))")
            refresh()
        } catch {
            log.log("import", "PhotosPicker failed: \(error.localizedDescription)")
            errorMessage = "Couldn't import the video: \(error.localizedDescription)"
        }
    }

    func importOpenedFile(_ url: URL) async {
        log.log("import", "Open-in received: \(url.lastPathComponent)")
        let type = UTType(filenameExtension: url.pathExtension)
        guard type?.conforms(to: .movie) == true else {
            log.log("import", "Open-in rejected (not a video): \(url.pathExtension)")
            errorMessage = "RecipeReel can only open video files."
            return
        }
        busyMessage = "Importing video…"
        defer { busyMessage = nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let store = localStore
            let item = try await Task.detached {
                // iOS copies the file into our Documents/Inbox first, so moving it is safe.
                try store.addVideo(from: url, origin: .openIn, moveFile: true)
            }.value
            log.log("import", "Open-in video \(Self.describe(item))")
            refresh()
        } catch {
            log.log("import", "Open-in failed: \(error.localizedDescription)")
            errorMessage = "Couldn't import the file: \(error.localizedDescription)"
        }
    }

    func addCaptionOnly(_ text: String) {
        do {
            let item = try localStore.addCaption(text, origin: .captionPaste)
            log.log("import", "Caption pasted (\(item.caption?.count ?? 0) chars)")
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateCaption(_ text: String, for item: InboxItem) {
        do {
            try localStore.updateCaption(text, for: item.id)
            log.log("library", "Caption updated for \(item.id.uuidString.prefix(8))")
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ item: InboxItem) {
        do {
            try localStore.delete(id: item.id)
            log.log("library", "Deleted \(item.id.uuidString.prefix(8))")
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    // MARK: - Analysis reports (saved next to the item as analysis.json)

    func saveReport(_ report: AnalysisReport, for item: InboxItem) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try localStore.writeAttachment(try encoder.encode(report), named: AnalysisRunner.reportFileName, for: item.id)
        } catch {
            log.log("library", "Saving analysis failed: \(error.localizedDescription)")
        }
    }

    func report(for item: InboxItem) -> AnalysisReport? {
        guard let data = localStore.readAttachment(named: AnalysisRunner.reportFileName, for: item.id) else { return nil }
        return try? JSONDecoder().decode(AnalysisReport.self, from: data)
    }

    /// The most recent analysis across all items (for Diagnostics).
    func latestReport() -> AnalysisReport? {
        items.compactMap { report(for: $0) }.max { $0.createdAt < $1.createdAt }
    }

    func item(id: UUID?) -> InboxItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    // MARK: - Helpers

    private static func describe(_ item: InboxItem) -> String {
        let size = item.videoByteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
        return "\(item.videoFileName ?? "?") \(size)"
    }

    private static func seconds(since date: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(date))
    }
}

enum ImportFailure: LocalizedError {
    case noVideo

    var errorDescription: String? {
        switch self {
        case .noVideo: "The selected item didn't contain a video."
        }
    }
}

/// Receives a picked video as a file. The system's temporary copy is copied once into our
/// temp folder, then moved into the library (no in-memory loading of large videos).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = URL.temporaryDirectory.appending(path: "picked-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}
