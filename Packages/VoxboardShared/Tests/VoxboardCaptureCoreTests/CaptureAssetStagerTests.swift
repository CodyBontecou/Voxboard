import XCTest
@testable import VoxboardCaptureCore

final class CaptureAssetStagerTests: XCTestCase {
    func test_stageDataWritesDurableUniqueAssetReferences() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let stager = CaptureAssetStager(directoryURL: root)

        let first = try await stager.stage(
            data: Data("one".utf8),
            preferredFilename: "photo.jpg",
            contentTypeIdentifier: "public.jpeg"
        )
        let second = try await stager.stage(
            data: Data("two".utf8),
            preferredFilename: "photo.jpg",
            contentTypeIdentifier: "public.jpeg"
        )

        XCTAssertEqual(first.relativePath, "photo.jpg")
        XCTAssertEqual(first.originalFilename, "photo.jpg")
        XCTAssertEqual(first.byteCount, 3)
        XCTAssertEqual(second.relativePath, "photo-2.jpg")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(first.relativePath)), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(second.relativePath)), Data("two".utf8))
    }

    func test_stageCopySanitizesUntrustedFilenameAndPreservesExtension() async throws {
        let root = try temporaryFolder()
        let sourceRoot = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let source = sourceRoot.appendingPathComponent("source.pdf")
        try Data("pdf".utf8).write(to: source)
        let stager = CaptureAssetStager(directoryURL: root)

        let asset = try await stager.stageCopy(
            from: source,
            preferredFilename: "../../trip:notes.pdf",
            contentTypeIdentifier: "com.adobe.pdf"
        )

        XCTAssertEqual(asset.relativePath, "trip-notes.pdf")
        XCTAssertEqual(asset.originalFilename, "trip-notes.pdf")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(asset.relativePath)), Data("pdf".utf8))
    }

    func test_sharedFilenameSanitizerRejectsDotTraversalAndRestoresKnownExtension() {
        let traversal = CaptureAssetStager.sanitizedFilename("..", fallbackExtension: "pdf")
        let hidden = CaptureAssetStager.sanitizedFilename(".env", fallbackExtension: "")
        let extensionless = CaptureAssetStager.sanitizedFilename("scan", fallbackExtension: "pdf")

        XCTAssertNotEqual(traversal, ".")
        XCTAssertNotEqual(traversal, "..")
        XCTAssertTrue(traversal.hasSuffix(".pdf"))
        XCTAssertEqual(hidden, "env")
        XCTAssertEqual(extensionless, "scan.pdf")
        XCTAssertFalse(traversal.contains("/"))
    }

    func test_oversizedAssetIsRejectedBeforeWritingPartialFile() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let stager = CaptureAssetStager(directoryURL: root, maximumByteCount: 3)

        do {
            _ = try await stager.stage(
                data: Data("four".utf8),
                preferredFilename: "large.txt",
                contentTypeIdentifier: "public.plain-text"
            )
            XCTFail("Expected oversized asset to fail")
        } catch CaptureAssetStagerError.assetTooLarge(let filename, let byteCount, let limit) {
            XCTAssertEqual(filename, "large.txt")
            XCTAssertEqual(byteCount, 4)
            XCTAssertEqual(limit, 3)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("large.txt").path))
    }

    func test_stageCopyRejectsDirectoriesWithoutCreatingPartialTree() async throws {
        let root = try temporaryFolder()
        let sourceRoot = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let directory = sourceRoot.appendingPathComponent("Huge Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: directory.appendingPathComponent("nested.txt"))
        let stager = CaptureAssetStager(directoryURL: root, maximumByteCount: 3)

        do {
            _ = try await stager.stageCopy(
                from: directory,
                contentTypeIdentifier: "public.folder"
            )
            XCTFail("Expected directories to be rejected")
        } catch CaptureAssetStagerError.sourceIsDirectory(let path) {
            XCTAssertEqual(path, directory.path)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Huge Folder").path))
    }

    func test_removeRefusesPathsOutsideStagingRoot() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let stager = CaptureAssetStager(directoryURL: root)
        let unsafe = try CaptureAssetReference(
            relativePath: "safe/file.txt",
            originalFilename: "file.txt",
            contentTypeIdentifier: "public.plain-text"
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("safe"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("safe/file.txt"))

        try await stager.remove(unsafe)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("safe/file.txt").path))
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureAssetStagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
