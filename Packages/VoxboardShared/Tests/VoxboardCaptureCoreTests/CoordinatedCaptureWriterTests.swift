import XCTest
@testable import VoxboardCaptureCore

final class CoordinatedCaptureWriterTests: XCTestCase {
    func test_concurrentAppends_preserveBothEntries() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Inbox.md")
        try "# Inbox".write(to: file, atomically: true, encoding: .utf8)
        let writer = CoordinatedCaptureWriter(coordinator: ProcessLocalCaptureFileCoordinator.shared)

        async let first = writer.write(
            mutation(id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", entry: "First"),
            to: file
        )
        async let second = writer.write(
            mutation(id: "11111111-2222-3333-4444-555555555555", entry: "Second"),
            to: file
        )
        _ = try await (first, second)

        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(content.contains("First"))
        XCTAssertTrue(content.contains("Second"))
    }

    func test_externalChangeBetweenPlanningAndWrite_isPreserved() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Inbox.md")
        try "Original".write(to: file, atomically: true, encoding: .utf8)
        let coordinator = MutatingCoordinator {
            try "Original\n\nExternal edit".write(to: file, atomically: true, encoding: .utf8)
        }
        let writer = CoordinatedCaptureWriter(coordinator: coordinator)

        _ = try await writer.write(
            mutation(id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", entry: "Captured"),
            to: file
        )

        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(content.contains("External edit"))
        XCTAssertTrue(content.contains("Captured"))
    }

    func test_secureWriteRefusesParentSymlinkSwapAfterPlanning() async throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let lexicalFile = notes.appendingPathComponent("Inbox.md")
        let mutation = MarkdownCaptureMutation(
            requestID: UUID(),
            entry: "Must stay contained",
            placement: .append,
            destinationRootURL: root,
            relativeNotePath: "notes/Inbox.md"
        )
        let coordinator = MutatingCoordinator {
            try FileManager.default.removeItem(at: notes)
            try FileManager.default.createSymbolicLink(at: notes, withDestinationURL: outside)
        }
        let writer = CoordinatedCaptureWriter(coordinator: coordinator)

        do {
            _ = try await writer.write(mutation, to: lexicalFile)
            XCTFail("Expected swapped symlink parent to be rejected")
        } catch {
            // Expected: secure relative traversal refuses the symlink.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Inbox.md").path))
    }

    func test_retryDoesNotDuplicateEntry() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Inbox.md")
        let writer = CoordinatedCaptureWriter(coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let capture = mutation(id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", entry: "Once")

        let first = try await writer.write(capture, to: file)
        let second = try await writer.write(capture, to: file)

        XCTAssertFalse(first.wasAlreadyApplied)
        XCTAssertTrue(second.wasAlreadyApplied)
        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(content.components(separatedBy: "Once").count - 1, 1)
    }

    private func mutation(id: String, entry: String) -> MarkdownCaptureMutation {
        MarkdownCaptureMutation(
            requestID: UUID(uuidString: id)!,
            entry: entry,
            placement: .append
        )
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatedCaptureWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class MutatingCoordinator: CaptureFileCoordinating, @unchecked Sendable {
    private let mutate: () throws -> Void

    init(mutate: @escaping () throws -> Void) {
        self.mutate = mutate
    }

    func coordinateWriting<T>(at url: URL, _ accessor: (URL) throws -> T) throws -> T {
        try mutate()
        return try accessor(url)
    }
}
