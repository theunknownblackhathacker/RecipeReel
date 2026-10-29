import Foundation
import Synchronization

/// Append-only text log used by the Diagnostics screen and "Export log".
/// Thread-safe and usable from any isolation domain. Each process (app, share extension)
/// writes its own file; the extension's file lives in the App Group so the app can show it.
public final class DiagnosticsLog: Sendable {
    public let fileURL: URL
    private let maxBytes: Int
    private let lock = Mutex<Void>(())

    public init(fileURL: URL, maxBytes: Int = 1_000_000) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    /// Writes one line: `2026-10-29T16:50:01.123+02:00 [category] message`.
    public func log(_ category: String, _ message: String, date: Date = Date()) {
        let line = "\(Self.timestamp(date)) [\(category)] \(message)\n"
        lock.withLock { _ in
            appendUnlocked(Data(line.utf8))
        }
    }

    /// The whole log as text ("" if empty or missing).
    public func readAll() -> String {
        lock.withLock { _ in
            (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
    }

    public func clear() {
        lock.withLock { _ in
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Internals (call only while holding the lock)

    private func appendUnlocked(_ data: Data) {
        let fm = FileManager.default
        let path = fileURL.path(percentEncoded: false)
        if !fm.fileExists(atPath: path) {
            try? data.write(to: fileURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        // Size comes from the handle, not URL.resourceValues (which caches stale sizes).
        let newSize: UInt64
        do {
            let end = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            newSize = end + UInt64(data.count)
        } catch {
            try? handle.close()
            return
        }
        try? handle.close()
        if newSize > UInt64(maxBytes) {
            trimUnlocked()
        }
    }

    /// Keeps roughly the newest half of `maxBytes`, starting at a line boundary.
    private func trimUnlocked() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        var keep = data.suffix(maxBytes / 2)
        if let newline = keep.firstIndex(of: UInt8(ascii: "\n")) {
            keep = keep[keep.index(after: newline)...]
        }
        try? Data(keep).write(to: fileURL, options: .atomic)
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current))
    }
}
