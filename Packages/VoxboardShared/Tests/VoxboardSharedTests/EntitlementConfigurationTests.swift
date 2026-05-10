import Foundation
import XCTest
@testable import VoxboardShared

final class EntitlementConfigurationTests: XCTestCase {
    private let staleAppGroupIdentifier = "group.bontecou.Vox" + "Vault"

    func test_voxboardEntitlements_allUseSharedAppGroup() throws {
        let root = try repositoryRoot()
        let entitlementPaths = [
            "Voxboard/Voxboard.entitlements",
            "Voxboard Keyboard/VoxboardKeyboard.entitlements",
            "Voxboard WidgetExtension.entitlements",
            "Voxboard Widget/VoxboardWidget.entitlements",
        ]

        for path in entitlementPaths {
            let url = root.appendingPathComponent(path)
            let groups = try appGroups(in: url)
            XCTAssertEqual(groups, [AppConstants.appGroupIdentifier], path)
            XCTAssertFalse(groups.contains(staleAppGroupIdentifier), path)
        }
    }

    func test_debugAndReleaseBuildSettings_pointAtEntitlementFiles() throws {
        let root = try repositoryRoot()
        let project = root.appendingPathComponent("Voxboard.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: project, encoding: .utf8)

        XCTAssertEqual(text.matches(of: #"CODE_SIGN_ENTITLEMENTS = Voxboard/Voxboard.entitlements;"#), 2)
        XCTAssertEqual(text.matches(of: #"CODE_SIGN_ENTITLEMENTS = "Voxboard Keyboard/VoxboardKeyboard.entitlements";"#), 2)
        XCTAssertEqual(text.matches(of: #"CODE_SIGN_ENTITLEMENTS = "Voxboard WidgetExtension.entitlements";"#), 2)
        XCTAssertFalse(text.contains(staleAppGroupIdentifier))
    }

    private func appGroups(in url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return plist?["com.apple.security.application-groups"] as? [String] ?? []
    }

    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Voxboard.xcodeproj").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "EntitlementConfigurationTests", code: 1)
    }
}

private extension String {
    func matches(of literal: String) -> Int {
        components(separatedBy: literal).count - 1
    }
}
