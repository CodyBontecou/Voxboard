import XCTest
@testable import VoxboardShared

final class CaptureInboxDeliveryServiceTests: XCTestCase {
    func test_drainDeliversPendingRequestAndCompletesReceipt() async throws {
        let captureRoot = try temporaryFolder("capture")
        let destinationRoot = try temporaryFolder("destination")
        defer {
            try? FileManager.default.removeItem(at: captureRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        let templateID = UUID()
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: try destinationRoot.bookmarkData(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md"),
            entryPrefix: "stale snapshot",
            entryTemplateID: templateID
        )
        let template = CaptureEntryTemplate(
            id: templateID,
            name: "Live",
            entryPrefix: "CURRENT TEMPLATE: "
        )
        try await CaptureLibraryStore(
            fileURL: captureRoot.appendingPathComponent(CaptureLibraryStore.defaultFilename),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).save(CaptureLibraryEnvelope(
            destinations: [destination],
            defaultDestinationID: destination.id,
            entryTemplates: [template]
        ))
        let request = CaptureRequest(
            source: .voice,
            destinationID: destination.id,
            payloads: [.text("Mac retry survived")]
        )
        let inbox = CaptureInbox(
            rootDirectoryURL: captureRoot,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        try await inbox.enqueue(request)

        let result = await CaptureInboxDeliveryService.drain(
            captureRootURL: captureRoot,
            pipeline: CapturePipeline(
                writer: CoordinatedCaptureWriter(coordinator: ProcessLocalCaptureFileCoordinator.shared)
            ),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )

        let finalState = try await inbox.state(of: request.id)
        XCTAssertEqual(result.receipts.map(\.requestID), [request.id])
        XCTAssertEqual(result.failedRequestIDs, [])
        XCTAssertEqual(finalState, .completed)
        let markdown = try String(
            contentsOf: destinationRoot.appendingPathComponent("Inbox.md"),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("Mac retry survived"))
        XCTAssertTrue(markdown.contains("CURRENT TEMPLATE:"))
        XCTAssertFalse(markdown.contains("stale snapshot"))
        let history = try await CaptureHistoryStore(
            fileURL: captureRoot.appendingPathComponent(AppConstants.captureHistoryFilename),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).list()
        XCTAssertEqual(history.map(\.requestID), [request.id])
        XCTAssertEqual(history.first?.source, .voice)
        XCTAssertEqual(history.first?.destinationName, "Inbox")
        XCTAssertEqual(history.first?.outcome, .delivered)
    }

    func test_retryFailedReroutesOrphanToDefaultDestination() async throws {
        let captureRoot = try temporaryFolder("orphan-capture")
        let destinationRoot = try temporaryFolder("orphan-destination")
        defer {
            try? FileManager.default.removeItem(at: captureRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        let destination = CaptureDestination(
            name: "Replacement",
            rootBookmark: try destinationRoot.bookmarkData(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Recovered.md")
        )
        try await CaptureLibraryStore(
            fileURL: captureRoot.appendingPathComponent(CaptureLibraryStore.defaultFilename),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).save(CaptureLibraryEnvelope(destinations: [destination], defaultDestinationID: destination.id))
        let request = CaptureRequest(source: .voice, destinationID: UUID(), payloads: [.text("Recovered")])
        let inbox = CaptureInbox(rootDirectoryURL: captureRoot, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        try await inbox.enqueue(request)
        _ = try await inbox.claim(requestID: request.id)
        try await inbox.fail(requestID: request.id)

        let result = await CaptureInboxDeliveryService.drain(
            captureRootURL: captureRoot,
            retryFailed: true,
            pipeline: CapturePipeline(
                writer: CoordinatedCaptureWriter(coordinator: ProcessLocalCaptureFileCoordinator.shared)
            ),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )

        let finalState = try await inbox.state(of: request.id)
        XCTAssertEqual(result.receipts.map(\.requestID), [request.id])
        XCTAssertEqual(finalState, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationRoot.appendingPathComponent("Recovered.md").path))
    }

    private func temporaryFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureInboxDeliveryServiceTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
