import Foundation
import RecipeCore

/// File locations inside the app's own sandbox.
enum AppPaths {
    static var importsRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Imports", directoryHint: .isDirectory)
    }

    static var appLogURL: URL {
        URL.applicationSupportDirectory.appending(path: "Diagnostics/app.log")
    }
}

/// The app process's diagnostics log.
enum AppLog {
    static let shared = DiagnosticsLog(fileURL: AppPaths.appLogURL)
}

/// Facts about this install, shown on the Diagnostics screen and in exported logs.
struct InstallInfo: Sendable {
    let appBundleID: String
    let version: String
    let build: String
    let appProfile: ProvisioningInfo?
    let shareExtensionBundleID: String?
    let shareExtensionProfile: ProvisioningInfo?
    let shareExtensionSigned: Bool

    static func current() -> InstallInfo {
        let main = Bundle.main
        let appex = main.builtInPlugInsURL?.appending(path: "RecipeReelShare.appex", directoryHint: .isDirectory)
        let appexBundle = appex.flatMap { Bundle(url: $0) }
        let appexSigned = appex.map {
            FileManager.default.fileExists(atPath: $0.appending(path: "_CodeSignature").path(percentEncoded: false))
        } ?? false
        return InstallInfo(
            appBundleID: main.bundleIdentifier ?? "?",
            version: main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            appProfile: ProvisioningInfo.embedded(inBundleAt: main.bundleURL),
            shareExtensionBundleID: appexBundle?.bundleIdentifier,
            shareExtensionProfile: appex.flatMap { ProvisioningInfo.embedded(inBundleAt: $0) },
            shareExtensionSigned: appexSigned
        )
    }

    /// True when the extension's bundle ID is correctly prefixed by the app's.
    var shareExtensionIDLooksValid: Bool {
        guard let ext = shareExtensionBundleID else { return false }
        return ext.hasPrefix(appBundleID + ".")
    }
}

/// One "title: value" line on the Diagnostics screen.
struct SummaryLine: Identifiable, Sendable {
    let title: String
    let value: String
    var id: String { title }
    var text: String { "\(title): \(value)" }
}

extension ProvisioningInfo {
    /// Short summary for the Diagnostics screen and exports.
    var summaryLines: [SummaryLine] {
        var lines: [SummaryLine] = [
            SummaryLine(title: "Profile", value: name ?? "?"),
            SummaryLine(title: "Team", value: teamName ?? "?"),
            SummaryLine(title: "App ID", value: bundleIDPattern ?? "?"),
            SummaryLine(title: "Wildcard", value: isWildcard ? "yes (App Groups impossible)" : "no"),
            SummaryLine(title: "App Groups", value: appGroups.isEmpty ? "none" : appGroups.joined(separator: ", "))
        ]
        if let expirationDate {
            lines.append(SummaryLine(title: "Expires", value: expirationDate.formatted(date: .abbreviated, time: .omitted)))
        }
        return lines
    }
}
