import Foundation
import Testing
@testable import RecipeCore

@Suite("ProvisioningInfo")
struct ProvisioningInfoTests {

    private func profileBlob(appID: String, groups: [String]?) -> Data {
        let groupsXML = groups.map { list in
            "<key>com.apple.security.application-groups</key><array>"
                + list.map { "<string>\($0)</string>" }.joined()
                + "</array>"
        } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key><string>Test Profile</string>
            <key>TeamName</key><string>Kevin Test</string>
            <key>ExpirationDate</key><date>2027-01-01T00:00:00Z</date>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key><string>\(appID)</string>
                <key>get-task-allow</key><false/>
                \(groupsXML)
            </dict>
        </dict>
        </plist>
        """
        // Real profiles wrap the plist in binary CMS data: simulate junk on both sides.
        return Data([0x30, 0x82, 0x1F, 0x00, 0xFF]) + Data(xml.utf8) + Data([0x00, 0xA0, 0x82])
    }

    @Test func parsesExplicitProfileWithAppGroups() throws {
        let info = try #require(ProvisioningInfo.parse(
            profileBlob(appID: "ABCDE12345.com.kevin.recipereel", groups: ["group.com.kevin.recipereel"])
        ))
        #expect(info.name == "Test Profile")
        #expect(info.teamName == "Kevin Test")
        #expect(info.applicationIdentifier == "ABCDE12345.com.kevin.recipereel")
        #expect(info.bundleIDPattern == "com.kevin.recipereel")
        #expect(info.isWildcard == false)
        #expect(info.appGroups == ["group.com.kevin.recipereel"])
        #expect(info.getTaskAllow == false)
        #expect(info.expirationDate == Date(timeIntervalSince1970: 1_798_761_600))
    }

    @Test func detectsWildcardProfile() throws {
        let info = try #require(ProvisioningInfo.parse(profileBlob(appID: "ABCDE12345.*", groups: nil)))
        #expect(info.isWildcard)
        #expect(info.bundleIDPattern == "*")
        #expect(info.appGroups.isEmpty)
    }

    @Test func garbageReturnsNil() {
        #expect(ProvisioningInfo.parse(Data("no plist here".utf8)) == nil)
    }
}

@Suite("AppGroup")
struct AppGroupTests {
    let preferred = "group.com.kevin.recipereel"

    @Test func preferredComesFirstWhenProfileHasIt() {
        #expect(AppGroup.candidates(preferred: preferred, profileGroups: ["group.other", preferred])
                == [preferred, "group.other"])
    }

    @Test func recipeReelNamedGroupsBeforeOthers() {
        #expect(AppGroup.candidates(preferred: preferred, profileGroups: ["group.zzz", "group.x.RecipeReel"])
                == ["group.x.RecipeReel", "group.zzz", preferred])
    }

    @Test func signingServiceGroupsAreSortedAndWildcardsDropped() {
        // Shape of Kevin's real profile (Feather): numbered groups, none of ours.
        let groups = ["group.1ee36df74cba27f7.5", "group.1ee36df74cba27f7.1", "group.1ee36df74cba27f7.3", "group.*"]
        #expect(AppGroup.candidates(preferred: preferred, profileGroups: groups)
                == ["group.1ee36df74cba27f7.1", "group.1ee36df74cba27f7.3", "group.1ee36df74cba27f7.5", preferred])
    }

    @Test func noProfileGroupsMeansPreferredOnly() {
        #expect(AppGroup.candidates(preferred: preferred, profileGroups: []) == [preferred])
    }
}

@Suite("SharedContainer")
struct SharedContainerTests {

    @Test func usesFirstGroupIOSGrants() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "RecipeCoreTests-\(UUID().uuidString)")
        let container = SharedContainer.resolve(candidates: ["group.a", "group.b", "group.c"]) { id in
            id == "group.a" ? nil : base.appending(path: id)
        }
        #expect(container.isAvailable)
        #expect(container.groupIdentifier == "group.b")
        let inbox = try #require(container.inboxURL)
        #expect(inbox.path().contains("group.b/RecipeReel/Inbox"))
        #expect(FileManager.default.fileExists(atPath: inbox.path(percentEncoded: false)))
    }

    @Test func reportsWhenNoGroupIsGranted() {
        let container = SharedContainer.resolve(candidates: ["group.a", "group.b"]) { _ in nil }
        #expect(!container.isAvailable)
        #expect(container.inboxURL == nil)
        #expect(container.problem?.contains("group.a, group.b") == true)
    }
}

@Suite("DiagnosticsLog")
struct DiagnosticsLogTests {

    private func tempLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "RecipeCoreTests-\(UUID().uuidString)/test.log")
    }

    @Test func appendsAndReadsLines() {
        let log = DiagnosticsLog(fileURL: tempLogURL())
        log.log("import", "first")
        log.log("import", "second")
        let lines = log.readAll().split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("[import] first"))
        #expect(lines[1].hasSuffix("[import] second"))
    }

    @Test func clearRemovesEverything() {
        let log = DiagnosticsLog(fileURL: tempLogURL())
        log.log("x", "y")
        log.clear()
        #expect(log.readAll().isEmpty)
    }

    @Test func trimsWhenTooLarge() throws {
        let url = tempLogURL()
        let log = DiagnosticsLog(fileURL: url, maxBytes: 2_000)
        for i in 0..<200 {
            log.log("spam", "line number \(i)")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let size = try #require(attributes[.size] as? NSNumber).intValue
        #expect(size <= 2_000)
        #expect(log.readAll().contains("line number 199"))
        #expect(!log.readAll().contains("line number 0\n"))
    }

    @Test func concurrentWritesAreAllKept() async {
        let log = DiagnosticsLog(fileURL: tempLogURL())
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { log.log("task", "write \(i)") }
            }
        }
        #expect(log.readAll().split(separator: "\n").count == 50)
    }
}
