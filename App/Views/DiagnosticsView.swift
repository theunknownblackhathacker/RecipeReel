import SwiftUI
import UIKit
import RecipeCore

/// Install facts + logs, with "Export log" through the share sheet.
/// This is how we debug without a Mac: export, then paste the text into the chat.
struct DiagnosticsView: View {
    @Environment(ImportModel.self) private var model
    @Environment(AppServices.self) private var services
    @State private var latestReport: AnalysisReport?
    @State private var appLog = ""
    @State private var extensionLog = ""
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section("Build") {
                row("App", "\(model.install.version) (\(model.install.build))")
                row("Bundle ID", model.install.appBundleID)
                row("iOS", UIDevice.current.systemVersion)
                row("Device", UIDevice.current.model)
            }

            Section("Apple Intelligence & data") {
                row("Apple Intelligence", services.aiAvailability.shortLabel)
                if !services.aiAvailability.isAvailable {
                    Text(services.aiAvailability.message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let problem = services.databaseProblem {
                    Text(problem).font(.footnote).foregroundStyle(.orange)
                } else {
                    row("Nutrition foods", services.databaseInfo["food_count"] ?? "?")
                    row("Foundation file", services.databaseInfo["foundation_file"] ?? "?")
                    row("SR Legacy file", services.databaseInfo["sr_legacy_file"] ?? "?")
                }
                row("Remembered matches", "\(services.rememberedMatches.count)")
                NavigationLink("AI self-test (recipe-test-cases)") {
                    SelfTestView()
                }
            }

            Section {
                if let report = latestReport {
                    row("When", report.createdAt.formatted(date: .abbreviated, time: .shortened))
                    ForEach(report.timings, id: \.stage) { timing in
                        row(timing.stage, "\(String(format: "%.1f", timing.seconds))s \(timing.note)")
                    }
                    ForEach(report.errors, id: \.self) { error in
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                    NavigationLink("Transcript, on-screen text & raw model output") {
                        ReportTextView(report: report)
                    }
                } else {
                    Text("No analysis yet. Open an import and tap Make recipe.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Last analysis")
            }

            Section {
                if let profile = model.install.appProfile {
                    ForEach(profile.summaryLines) { line in
                        row(line.title, line.value)
                    }
                } else {
                    Text("No embedded provisioning profile (unsigned build).")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Signing (app)")
            }

            Section {
                if let extID = model.install.shareExtensionBundleID {
                    row("Bundle ID", extID)
                    row("ID prefix OK", model.install.shareExtensionIDLooksValid ? "yes" : "NO — must start with \(model.install.appBundleID).")
                    row("Signed", model.install.shareExtensionSigned ? "yes" : "NO — signing tool skipped it")
                    if let profile = model.install.shareExtensionProfile {
                        row("Profile App ID", profile.bundleIDPattern ?? "?")
                        row("Profile App Groups", profile.appGroups.isEmpty ? "none" : profile.appGroups.joined(separator: ", "))
                    } else {
                        row("Profile", "none embedded")
                    }
                } else {
                    Text("Share extension is missing from the installed app.")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Share extension")
            }

            Section {
                row("Group ID", model.shared.groupIdentifier)
                row("Status", model.shared.isAvailable ? "available" : "unavailable")
                if let problem = model.shared.problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                row("Waiting in shared inbox", "\(model.pendingSharedCount())")
            } header: {
                Text("App Group handoff")
            }

            Section("Imports") {
                ForEach(InboxItem.Kind.allCases, id: \.self) { kind in
                    row(kind.displayName, "\(model.items.filter { $0.kind == kind }.count)")
                }
            }

            logSection("App log", text: appLog)
            logSection("Share extension log", text: extensionLog.isEmpty && !model.shared.isAvailable
                       ? "(not readable without the App Group)" : extensionLog)
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Export log", systemImage: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Clear logs", role: .destructive) {
                    model.log.clear()
                    if let url = model.shared.extensionLogURL {
                        DiagnosticsLog(fileURL: url).clear()
                    }
                    reload()
                }
            }
        }
        .onAppear(perform: reload)
        .refreshable { reload() }
    }

    // MARK: - Pieces

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func logSection(_ title: String, text: String) -> some View {
        Section(title) {
            ScrollView {
                Text(text.isEmpty ? "(empty)" : lastLines(of: text, count: 200))
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
        }
    }

    private func lastLines(of text: String, count: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
    }

    private func reload() {
        model.refresh()
        services.refreshAvailability()
        latestReport = model.latestReport()
        appLog = model.log.readAll()
        extensionLog = model.shared.extensionLogURL.map { DiagnosticsLog(fileURL: $0).readAll() } ?? ""
        exportURL = writeExport()
    }

    /// Writes a plain-text report for the share sheet.
    private func writeExport() -> URL? {
        let install = model.install
        var lines: [String] = []
        lines.append("RecipeReel diagnostics — \(Date().formatted(.iso8601))")
        lines.append("App \(install.version) (\(install.build)) · \(install.appBundleID) · iOS \(UIDevice.current.systemVersion)")
        lines.append("")
        lines.append("## Signing (app)")
        if let profile = install.appProfile {
            lines += profile.summaryLines.map(\.text)
        } else {
            lines.append("No embedded provisioning profile")
        }
        lines.append("")
        lines.append("## Share extension")
        lines.append("Bundle ID: \(install.shareExtensionBundleID ?? "MISSING")")
        lines.append("ID prefix OK: \(install.shareExtensionIDLooksValid)")
        lines.append("Signed: \(install.shareExtensionSigned)")
        if let profile = install.shareExtensionProfile {
            lines += profile.summaryLines.map(\.text)
        } else {
            lines.append("Profile: none embedded (uses the app's profile)")
        }
        lines.append("")
        lines.append("## App Group")
        lines.append("Group: \(model.shared.groupIdentifier) — \(model.shared.isAvailable ? "available" : "unavailable")")
        if let problem = model.shared.problem { lines.append("Problem: \(problem)") }
        lines.append("Waiting in shared inbox: \(model.pendingSharedCount())")
        lines.append("")
        lines.append("## Apple Intelligence & data")
        lines.append("Apple Intelligence: \(services.aiAvailability.shortLabel)")
        lines.append("Nutrition DB: \(services.databaseProblem ?? services.databaseInfo.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        lines.append("Remembered matches: \(services.rememberedMatches.count)")
        if !services.lastSelfTestLog.isEmpty {
            lines.append("")
            lines.append("## AI self-test")
            lines += services.lastSelfTestLog
        }
        lines.append("")
        lines.append("## Imports")
        for item in model.items {
            lines.append("- \(item.kind.rawValue) via \(item.origin.rawValue), \(item.sizeText ?? "-"), caption \(item.caption?.count ?? 0) chars, \(item.createdAt.formatted(.iso8601))")
        }
        if let report = latestReport {
            lines.append("")
            lines.append("## Last analysis")
            lines.append(report.textDump)
        }
        lines.append("")
        lines.append("## App log")
        lines.append(appLog.isEmpty ? "(empty)" : appLog)
        lines.append("")
        lines.append("## Share extension log")
        lines.append(extensionLog.isEmpty ? "(empty)" : extensionLog)

        let stamp = Int(Date().timeIntervalSince1970)
        let url = URL.temporaryDirectory.appending(path: "RecipeReel-diagnostics-\(stamp).txt")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            model.log.log("diagnostics", "Export failed: \(error.localizedDescription)")
            return nil
        }
    }
}
