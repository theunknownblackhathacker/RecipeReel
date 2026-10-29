import Foundation

/// What the installed provisioning profile says. Read from `embedded.mobileprovision`,
/// which the signing tool (e.g. Feather) puts inside the app and each extension.
/// This answers "is my profile wildcard? does it have App Groups?" on the device itself.
public struct ProvisioningInfo: Sendable, Equatable {
    public let name: String?
    public let teamName: String?
    /// e.g. `ABCDE12345.com.kevin.recipereel` or `ABCDE12345.*`
    public let applicationIdentifier: String?
    public let appGroups: [String]
    public let expirationDate: Date?
    public let getTaskAllow: Bool?

    public init(name: String?, teamName: String?, applicationIdentifier: String?,
                appGroups: [String], expirationDate: Date?, getTaskAllow: Bool?) {
        self.name = name
        self.teamName = teamName
        self.applicationIdentifier = applicationIdentifier
        self.appGroups = appGroups
        self.expirationDate = expirationDate
        self.getTaskAllow = getTaskAllow
    }

    public var isWildcard: Bool { applicationIdentifier?.hasSuffix("*") ?? false }

    /// The bundle ID pattern without the team prefix, e.g. `com.kevin.recipereel` or `*`.
    public var bundleIDPattern: String? {
        guard let id = applicationIdentifier, let dot = id.firstIndex(of: ".") else { return applicationIdentifier }
        return String(id[id.index(after: dot)...])
    }

    /// Extracts the XML plist embedded in the CMS-signed profile blob.
    public static func parse(_ data: Data) -> ProvisioningInfo? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil),
              let dict = plist as? [String: Any]
        else { return nil }
        let entitlements = dict["Entitlements"] as? [String: Any] ?? [:]
        return ProvisioningInfo(
            name: dict["Name"] as? String,
            teamName: dict["TeamName"] as? String,
            applicationIdentifier: entitlements["application-identifier"] as? String,
            appGroups: entitlements["com.apple.security.application-groups"] as? [String] ?? [],
            expirationDate: dict["ExpirationDate"] as? Date,
            getTaskAllow: entitlements["get-task-allow"] as? Bool
        )
    }

    /// The profile embedded in a bundle (the app, or an `.appex`). Nil for unsigned builds.
    public static func embedded(inBundleAt bundleURL: URL) -> ProvisioningInfo? {
        let url = bundleURL.appending(path: "embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }
}
