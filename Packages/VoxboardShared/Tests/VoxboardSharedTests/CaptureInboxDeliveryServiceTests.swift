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

    func test_drainAppliesPendingVoxOnceAndRecordsWorkflowIdentity() async throws {
        let captureRoot = try temporaryFolder("vox-capture")
        let destinationRoot = try temporaryFolder("vox-destination")
        defer {
            try? FileManager.default.removeItem(at: captureRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        let destination = CaptureDestination(
            name: "Tasks",
            rootBookmark: try destinationRoot.bookmarkData(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Tasks.md")
        )
        try await CaptureLibraryStore(
            fileURL: captureRoot.appendingPathComponent(CaptureLibraryStore.defaultFilename),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).save(CaptureLibraryEnvelope(destinations: [destination], defaultDestinationID: destination.id))
        let profile = CaptureVoxProfile(
            id: "tasks",
            name: "Tasks",
            symbolName: "checklist",
            staticFrontmatter: ["type": "task"],
            postProcessingMode: .todoList,
            captureProcessingEnabled: true,
            captureDestinationID: destination.id
        )
        let request = CaptureRequest(
            source: .shareExtension,
            destinationID: destination.id,
            payloads: [.text("buy milk. email sam")],
            frontmatter: profile.staticFrontmatter,
            voxProfile: profile,
            voxProcessingState: .pending
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
            requestProcessor: CaptureVoxRequestProcessor(),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )

        XCTAssertEqual(result.receipts.map(\.requestID), [request.id])
        let markdown = try String(
            contentsOf: destinationRoot.appendingPathComponent("Tasks.md"),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("type: \"task\""))
        XCTAssertTrue(markdown.contains("- [ ] Buy milk"))
        XCTAssertTrue(markdown.contains("- [ ] Email sam"))
        let history = try await CaptureHistoryStore(
            fileURL: captureRoot.appendingPathComponent(AppConstants.captureHistoryFilename),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).list()
        XCTAssertEqual(history.first?.voxID, "tasks")
        XCTAssertEqual(history.first?.voxName, "Tasks")
    }

    func test_drainPreservesOneCaptureRouteOverrides() async throws {
        let captureRoot = try temporaryFolder("override-capture")
        let destinationRoot = try temporaryFolder("override-destination")
        defer {
            try? FileManager.default.removeItem(at: captureRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        try "Older".write(
            to: destinationRoot.appendingPathComponent("Custom.md"),
            atomically: true,
            encoding: .utf8
        )
        let template = CaptureEntryTemplate(name: "Task", entryPrefix: "TASK: ")
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: try destinationRoot.bookmarkData(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Default.md"),
            placement: .append
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
            source: .app,
            destinationID: destination.id,
            payloads: [.text("New")],
            relativeNotePathOverride: "Custom.md",
            placementOverride: .prepend,
            entryTemplateIDOverride: template.id
        )
        let inbox = CaptureInbox(
            rootDirectoryURL: captureRoot,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        try await inbox.enqueue(request)

        _ = await CaptureInboxDeliveryService.drain(
            captureRootURL: captureRoot,
            pipeline: CapturePipeline(
                writer: CoordinatedCaptureWriter(coordinator: ProcessLocalCaptureFileCoordinator.shared)
            ),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )

        let markdown = try String(
            contentsOf: destinationRoot.appendingPathComponent("Custom.md"),
            encoding: .utf8
        )
        XCTAssertLessThan(try XCTUnwrap(markdown.range(of: "TASK: New")?.lowerBound),
                          try XCTUnwrap(markdown.range(of: "Older")?.lowerBound))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationRoot.appendingPathComponent("Default.md").path
        ))
    }

    func test_quotaBlockedRequestReturnsToPendingWithoutFailedHistory() async throws {
        let captureRoot = try temporaryFolder("quota-capture")
        let destinationRoot = try temporaryFolder("quota-destination")
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
        let request = CaptureRequest(
            source: .shareExtension,
            destinationID: destination.id,
            payloads: [.text("Keep this queued")]
        )
        let voiceRequest = CaptureRequest(
            createdAt: request.createdAt.addingTimeInterval(1),
            source: .voice,
            destinationID: destination.id,
            payloads: [.text("Voice must not be starved")]
        )
        let inbox = CaptureInbox(
            rootDirectoryURL: captureRoot,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        try await inbox.enqueue(request)
        try await inbox.enqueue(voiceRequest)

        let blocked = await CaptureInboxDeliveryService.drain(
            captureRootURL: captureRoot,
            pipeline: CapturePipeline(
                writer: CoordinatedCaptureWriter(coordinator: ProcessLocalCaptureFileCoordinator.shared),
                deliveryAccounting: DenyingInboxCaptureDeliveryAccounting()
            ),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )

        let blockedState = try await inbox.state(of: request.id)
        let blockedHistory = try await CaptureHistoryStore(
            fileURL: captureRoot.appendingPathComponent(AppConstants.captureHistoryFilename),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).list()
        XCTAssertEqual(blocked.quotaBlockedRequestIDs, [request.id])
        XCTAssertEqual(blocked.receipts.map(\.requestID), [voiceRequest.id])
        XCTAssertEqual(blocked.failedRequestIDs, [])
        XCTAssertEqual(blockedState, .pending)
        XCTAssertEqual(blockedHistory.map(\.requestID), [voiceRequest.id])
        let voiceMarkdown = try String(
            contentsOf: destinationRoot.appendingPathComponent("Inbox.md"),
            encoding: .utf8
        )
        XCTAssertTrue(voiceMarkdown.contains("Voice must not be starved"))
        XCTAssertFalse(voiceMarkdown.contains("Keep this queued"))

        let retried = await CaptureInboxDeliveryService.drain(
            captureRootURL: captureRoot,
            pipeline: CapturePipeline(
                writer: CoordinatedCaptureWriter(coordinator: ProcessLocalCaptureFileCoordinator.shared)
            ),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let completedState = try await inbox.state(of: request.id)
        XCTAssertEqual(retried.receipts.map(\.requestID), [request.id])
        XCTAssertEqual(completedState, .completed)
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

private struct DenyingInboxCaptureDeliveryAccounting: CaptureDeliveryAccounting {
    func reserve(for request: CaptureRequest) async throws -> CaptureDeliveryReservation {
        if request.deliveryKind == .meteredVoiceTranscript {
            return .bypassed(requestID: request.id)
        }
        throw CaptureDeliveryQuotaError.limitReached(limit: 10)
    }

    func commit(_ reservation: CaptureDeliveryReservation) async throws {}
    func release(_ reservation: CaptureDeliveryReservation) async {}
}
