import XCTest
@testable import VoxboardCaptureCore

final class CaptureAttachmentWriterTests: XCTestCase {
    func test_rollbackDoesNotDeleteAttachmentReplacedByAnotherWriter() throws {
        let root = try temporaryFolder("destination")
        let staging = try temporaryFolder("staging")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        try Data("ours".utf8).write(to: staging.appendingPathComponent("photo.jpg"))
        let asset = try CaptureAssetReference(
            relativePath: "photo.jpg",
            originalFilename: "photo.jpg",
            contentTypeIdentifier: "public.jpeg"
        )
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.image(asset, altText: nil)]
        )
        let transaction = try CaptureAttachmentWriter().copyAttachments(
            for: request,
            destination: destination,
            destinationRootURL: root,
            assetRootURL: staging
        )
        let copied = try XCTUnwrap(transaction.attachmentURLs.first)
        try Data("external replacement".utf8).write(to: copied, options: .atomic)

        transaction.rollback()

        XCTAssertEqual(try Data(contentsOf: copied), Data("external replacement".utf8))
    }

    func test_rollbackDeletesAttachmentWhenCopiedBytesAreStillOurs() throws {
        let root = try temporaryFolder("owned-destination")
        let staging = try temporaryFolder("owned-staging")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        try Data("ours".utf8).write(to: staging.appendingPathComponent("photo.jpg"))
        let asset = try CaptureAssetReference(
            relativePath: "photo.jpg",
            originalFilename: "photo.jpg",
            contentTypeIdentifier: "public.jpeg"
        )
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        let transaction = try CaptureAttachmentWriter().copyAttachments(
            for: CaptureRequest(
                source: .app,
                destinationID: destination.id,
                payloads: [.image(asset, altText: nil)]
            ),
            destination: destination,
            destinationRootURL: root,
            assetRootURL: staging
        )
        let copied = try XCTUnwrap(transaction.attachmentURLs.first)

        transaction.rollback()

        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
    }

    private func temporaryFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureAttachmentWriterTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
