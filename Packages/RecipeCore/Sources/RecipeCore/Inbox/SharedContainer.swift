import Foundation

/// App Group identifier handling.
public enum AppGroup {
    /// The App Group this project is designed for.
    public static let preferredIdentifier = "group.com.kevin.recipereel"

    /// Picks the App Group to use.
    ///
    /// Signing tools (e.g. Feather) take entitlements from the provisioning profile, which may list
    /// a different group than ours. Rule: our preferred ID if the profile has it; otherwise a group
    /// whose name contains "recipereel"; otherwise the only/first concrete group; otherwise the preferred ID
    /// (which then simply won't resolve, and the app reports "App Group unavailable").
    public static func resolveIdentifier(
        preferred: String = preferredIdentifier,
        profileGroups: [String]
    ) -> String {
        let concrete = profileGroups.filter { !$0.contains("*") }.sorted()
        if concrete.contains(preferred) { return preferred }
        if let named = concrete.first(where: { $0.localizedCaseInsensitiveContains("recipereel") }) { return named }
        return concrete.first ?? preferred
    }
}

/// The App Group container shared by the app and the share extension, if this install has one.
public struct SharedContainer: Sendable {
    public let groupIdentifier: String
    /// Nil when iOS didn't grant the App Group (e.g. wildcard provisioning profile).
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
    /// Note: on iOS, `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil when the
    /// running binary isn't entitled to the group.
    public static func resolve(profile: ProvisioningInfo?) -> SharedContainer {
        let identifier = AppGroup.resolveIdentifier(profileGroups: profile?.appGroups ?? [])
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            return SharedContainer(
                groupIdentifier: identifier,
                url: nil,
                problem: "iOS returned no container for \(identifier). The App Group entitlement is missing from this install."
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: url.appending(path: "Inbox", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        } catch {
            return SharedContainer(
                groupIdentifier: identifier,
                url: nil,
                problem: "App Group container exists but isn't writable: \(error.localizedDescription)"
            )
        }
        return SharedContainer(groupIdentifier: identifier, url: url, problem: nil)
    }
}
