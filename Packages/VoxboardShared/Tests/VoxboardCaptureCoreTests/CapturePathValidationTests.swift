import XCTest
@testable import VoxboardCaptureCore

final class CapturePathValidationTests: XCTestCase {
    func testRelativePathAcceptsDirectChild() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("Vault", isDirectory: true)
        let template = root.appendingPathComponent("Templates/Capture.md")
        try createFile(at: template)

        XCTAssertEqual(
            try CapturePathValidation.relativePath(for: template, containedIn: root),
            "Templates/Capture.md"
        )
    }

    func testRelativePathAcceptsCanonicalChildFromSymlinkedRootBookmark() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("Vault", isDirectory: true)
        let template = root.appendingPathComponent("Templates/Capture.md")
        try createFile(at: template)
        let bookmarkedAlias = container.appendingPathComponent("Vault Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: bookmarkedAlias, withDestinationURL: root)

        XCTAssertEqual(
            try CapturePathValidation.relativePath(for: template, containedIn: bookmarkedAlias),
            "Templates/Capture.md"
        )
    }

    func testRelativePathAcceptsAliasedPickerURLForCanonicalRoot() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("Vault", isDirectory: true)
        let template = root.appendingPathComponent("Templates/Capture.md")
        try createFile(at: template)
        let pickerAlias = container.appendingPathComponent("Picker Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: pickerAlias, withDestinationURL: root)
        let pickedTemplate = pickerAlias.appendingPathComponent("Templates/Capture.md")

        XCTAssertEqual(
            try CapturePathValidation.relativePath(for: pickedTemplate, containedIn: root),
            "Templates/Capture.md"
        )
    }

    func testRelativePathRejectsFileOutsideRoot() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = container.appendingPathComponent("Outside.md")
        try createFile(at: outside)

        XCTAssertThrowsError(
            try CapturePathValidation.relativePath(for: outside, containedIn: root)
        )
    }

    func testRelativePathRejectsSymlinkThatEscapesRoot() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("Vault", isDirectory: true)
        let outside = container.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideTemplate = outside.appendingPathComponent("Capture.md")
        try createFile(at: outsideTemplate)
        let linkedFolder = root.appendingPathComponent("Templates", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: outside)
        let pickedTemplate = linkedFolder.appendingPathComponent("Capture.md")

        XCTAssertThrowsError(
            try CapturePathValidation.relativePath(for: pickedTemplate, containedIn: root)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createFile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "template".write(to: url, atomically: true, encoding: .utf8)
    }
}
