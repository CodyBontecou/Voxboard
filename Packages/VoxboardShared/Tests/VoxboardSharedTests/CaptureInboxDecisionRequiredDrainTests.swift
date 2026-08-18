import XCTest
@testable import VoxboardShared

/// Location-decision semantics of the shared drain: a capture whose Preset
/// requires a location decision must stay pending with its processed payload
/// preserved — never failed — and be reported in `decisionsRequired`.
final class CaptureInboxDecisionRequiredDrainTests: XCTestCase {
    func test_drainKeepsLocationDecisionRequestPendingWithoutFailing() async throws {
        let captureRoot = try temporaryFolder("decision-capture")
        let destinationRoot = try temporaryFolder("decision-destination")
        defer {
            try? FileManager.default.removeItem(at: captureRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: try destinationRoot.bookmarkData(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        try await CaptureLibraryStore(
            fileURL: captureRoot.appendingPathComponent(CaptureLibraryStore.defaultFilename),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).save(CaptureLibraryEnvelope(destinations: [destination], defaultDestinationID: destination.id))
        let profile = CapturePresetProfile(
            id: "location-preset",
            name: "Location Preset",
            symbolName: "mappin",
            locationPolicy: CapturePresetLocationPolicy(isEnabled: true, unavailableBehavior: .ask)
        )
        // Enabled location policy with no resolved outcome → the pipeline
        // throws locationDecisionRequired before any delivery work.
        let request = CaptureRequest(
            source: .voice,
            destinationID: destination.id,
            payloads: [.text("decision pending")],
            voxProfile: profile
        )
        let inbox = CaptureInbox(
            rootDirectoryURL: captureRoot,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        try await inbox.enqueue(request)

        let result = await CaptureInboxDeliveryService.drain(
            captureRootURL: captureRoot,
            defaults: nil,
            pipeline: CapturePipeline(
                writer: CoordinatedCaptureWriter(coordinator: ProcessLocalCaptureFileCoordinator.shared)
            ),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )

        XCTAssertEqual(result.decisionsRequired.map(\.requestID), [request.id])
        XCTAssertEqual(result.decisionsRequired.first?.presetID, "location-preset")
        XCTAssertEqual(result.failedRequestIDs, [])
        XCTAssertEqual(result.receipts, [])
        let finalState = try await inbox.state(of: request.id)
        XCTAssertEqual(finalState, .pending)
        // A decision is not a delivery failure: no failed history record.
        let history = try await CaptureHistoryStore(
            fileURL: captureRoot.appendingPathComponent(AppConstants.captureHistoryFilename),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).list()
        XCTAssertEqual(history.count, 0)
        // The destination note was never touched.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destinationRoot.appendingPathComponent("Inbox.md").path)
        )
    }

    private func temporaryFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureInboxDecisionRequiredDrainTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
