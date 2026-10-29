import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers
import RecipeCore

@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case inspecting
        case ready
        case saving
        case saved
        case noAppGroup
        case failed(String)
    }

    private(set) var phase: Phase = .inspecting
    private(set) var hasVideo = false
    private(set) var link: URL?
    var caption = ""

    private let context: NSExtensionContext?
    private let shared: SharedContainer
    private let log: DiagnosticsLog
    private var videoProvider: NSItemProvider?

    init(context: NSExtensionContext?) {
        self.context = context
        let profile = ProvisioningInfo.embedded(inBundleAt: Bundle.main.bundleURL)
        let shared = SharedContainer.resolve(profile: profile)
        self.shared = shared
        self.log = DiagnosticsLog(
            fileURL: shared.extensionLogURL
                ?? URL.temporaryDirectory.appending(path: "extension.log")
        )
        log.log("share", "Opened. bundle \(Bundle.main.bundleIdentifier ?? "?"), profile app ID \(profile?.bundleIDPattern ?? "none"), App Group \(shared.isAvailable ? shared.groupIdentifier : "unavailable")")
    }

    var canSave: Bool {
        phase == .ready && (hasVideo || link != nil || !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Inspect what was shared

    func inspect() async {
        let items = (context?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
        let providers = items.flatMap { $0.attachments ?? [] }
        log.log("share", "Received \(providers.count) attachment(s): " +
                providers.map { $0.registeredTypeIdentifiers.joined(separator: "|") }.joined(separator: ", "))

        var captionParts: [String] = []
        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty {
                captionParts.append(text)
            }
        }

        videoProvider = providers.first { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }
        hasVideo = videoProvider != nil

        for provider in providers where provider !== videoProvider {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = await loadURL(from: provider), !url.isFileURL {
                if link == nil { link = url }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = await loadText(from: provider) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed), let scheme = url.scheme, scheme.hasPrefix("http") {
                    if link == nil { link = url }
                } else if !trimmed.isEmpty {
                    captionParts.append(trimmed)
                }
            }
        }

        // Avoid duplicating the link inside the caption.
        caption = captionParts
            .filter { $0 != link?.absoluteString }
            .joined(separator: "\n\n")

        log.log("share", "Inspected: video=\(hasVideo), link=\(link?.host() ?? "none"), caption=\(caption.count) chars")

        if !shared.isAvailable {
            phase = .noAppGroup
        } else if hasVideo || link != nil || !caption.isEmpty {
            phase = .ready
        } else {
            phase = .failed("Nothing RecipeReel can use was shared. Share a video or a link.")
        }
    }

    // MARK: - Save into the App Group inbox

    func save() async {
        guard let inboxURL = shared.inboxURL else {
            phase = .noAppGroup
            return
        }
        phase = .saving
        let store = InboxStore(rootURL: inboxURL)
        let caption = self.caption
        let link = self.link
        let started = Date()
        do {
            let item: InboxItem
            if let provider = videoProvider {
                item = try await copyVideo(from: provider, into: store, caption: caption, link: link)
            } else if let link {
                item = try store.addLink(link, caption: caption, origin: .shareExtension)
            } else {
                item = try store.addCaption(caption, origin: .shareExtension)
            }
            let size = item.videoByteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "-"
            log.log("share", "Saved \(item.kind.rawValue) \(item.id.uuidString.prefix(8)), \(size), in \(String(format: "%.1fs", Date().timeIntervalSince(started)))")
            phase = .saved
            try? await Task.sleep(for: .milliseconds(900))
            context?.completeRequest(returningItems: nil)
        } catch {
            log.log("share", "Save failed: \(error.localizedDescription)")
            phase = .failed("Couldn't save: \(error.localizedDescription)")
        }
    }

    func cancel() {
        log.log("share", "Cancelled")
        context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    func done() {
        context?.completeRequest(returningItems: nil)
    }

    /// Fallback when there's no App Group: put link + caption on the clipboard.
    func copyToClipboard() {
        let text = [link?.absoluteString, caption.isEmpty ? nil : caption]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        UIPasteboard.general.string = text
        log.log("share", "Copied link/caption to clipboard (no App Group)")
    }

    // MARK: - Item provider helpers

    private func copyVideo(from provider: NSItemProvider, into store: InboxStore,
                           caption: String, link: URL?) async throws -> InboxItem {
        let typeID = provider.registeredContentTypes.first { $0.conforms(to: .movie) }?.identifier
            ?? UTType.movie.identifier
        return try await withCheckedThrowingContinuation { continuation in
            // The temporary file is only valid inside this handler, so copy it here (streamed, low memory).
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    let item = try store.addVideo(from: url, caption: caption, sourceLink: link,
                                                  origin: .shareExtension)
                    continuation.resume(returning: item)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                continuation.resume(returning: text)
            }
        }
    }
}
