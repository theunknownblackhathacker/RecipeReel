import Foundation

/// App Group identifier handling.
public enum AppGroup {
    /// The App Group this project is designed for.
    public static let preferredIdentifier = "group.com.kevin.recipereel"

    /// App Groups to try, in order. The app and the share extension use the same rule, so they
    /// agree on the group as long as they see the same profile groups.
    ///
    /// Signing tools (e.g. Feather) take entitlements from the provisioning profile, which may list
    /// groups unrelated to our ID (e.g. `group.1ee36df74cba27f7.1`). Order: our preferred ID, then
    /// groups whose name contains "recipereel", then the remaining concrete groups sorted.
    /// The preferred ID is always included last as a fallback.
    public static func candidates(
        preferred: String = preferredIdentifier,
        profileGroups: [String]
    ) -> [String] {
        let concrete = Set(profileGroups.filter { !$0.contains("*") }).sorted()
        var ordered: [String] = []
        if concrete.contains(preferred) { ordered.append(preferred) }
        ordered += concrete.filter { $0 != preferred && $0.localizedCaseInsensitiveContains("recipereel") }
        ordered += concrete.filter { !ordered.contains($0) }
        if !ordered.contains(preferred) { ordered.append(preferred) }
        return ordered
    }
}

/// The App Group container shared by the app and the share extension, if this install has one.
public struct SharedContainer: Sendable {
    /// Our folder inside the group container. Signing services often reuse the same groups for
    /// many apps, so everything of ours lives under one clearly named folder.
    public static let folderName = "RecipeReel"

    public let groupIdentifier: String
    /// Root of our folder inside the group container. Nil when iOS didn't grant any App Group.
    public let url: URL?
    /// Human-readable reason when `url` is nil.
    public let problem: String?

    public init(groupIdentifier: String, url: URL?, problem: String?) {
        self.groupIdentifier = groupIdentifier
        self.url = url
        self.problem = problem
    }

    public var isAvailable: Bool { url != nil }
    public var inboxURL: URL? { url?.appending(path: "Inbox", directoryHint: .isDirectory) }
    public var extensionLogURL: URL? { url?.appending(path: "Diagnostics/extension.log") }

    /// Resolves the container for the current process (app or extension).
    ///
    /// Tries each candidate group and uses the first one iOS grants. On iOS,
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil for groups the running
    /// binary isn't entitled to, so this also works when a bundle has no embedded profile.
    public static func resolve(profileGroups: [String]) -> SharedContainer {
        resolve(candidates: AppGroup.candidates(profileGroups: profileGroups)) { identifier in
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        }
    }

    /// Testable core of `resolve(profileGroups:)`.
    static func resolve(candidates: [String], containerURL: (String) -> URL?) -> SharedContainer {
        var tried: [String] = []
        for identifier in candidates {
            tried.append(identifier)
            guard let groupURL = containerURL(identifier) else { continue }
            let root = groupURL.appending(path: folderName, directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(
                    at: root.appending(path: "Inbox", directoryHint: .isDirectory),
                    withIntermediateDirectories: true
                )
                return SharedContainer(groupIdentifier: identifier, url: root, problem: nil)
            } catch {
                continue
            }
        }
        return SharedContainer(
            groupIdentifier: candidates.first ?? AppGroup.preferredIdentifier,
            url: nil,
            problem: "No usable App Group. Tried: \(tried.joined(separator: ", ")). The App Group entitlement is missing from this install."
        )
    }
}
