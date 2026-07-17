import XCTest
@testable import VoxboardCaptureCore

final class CaptureInboxTests: XCTestCase {
    func test_claimIsAtomicAcrossTwoConsumers() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstInbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let secondInbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let request = makeRequest()
        try await firstInbox.enqueue(request)

        async let first = firstInbox.claimNext()
        async let second = secondInbox.claimNext()
        let claimed = try await [first, second].compactMap { $0 }

        XCTAssertEqual(claimed, [request])
    }

    func test_claimNextUsesRequestCreationOrderInsteadOfRandomUUIDFilenameOrder() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let newer = CaptureRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 200),
            source: .shareExtension,
            destinationID: UUID(),
            payloads: [.text("newer")]
        )
        let older = CaptureRequest(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            createdAt: Date(timeIntervalSince1970: 100),
            source: .shareExtension,
            destinationID: newer.destinationID,
            payloads: [.text("older")]
        )
        try await inbox.enqueue(newer)
        try await inbox.enqueue(older)

        let claimed = try await inbox.claimNext()

        XCTAssertEqual(claimed, older)
    }

    func test_corruptPendingFileIsQuarantinedWithoutBlockingValidCapture() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let valid = makeRequest()
        try await inbox.enqueue(valid)
        let corruptID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let corruptURL = inbox.itemURL(for: corruptID, state: .pending)
        try Data("not-json".utf8).write(to: corruptURL)

        let claimed = try await inbox.claimNext()
        let afterValid = try await inbox.claimNext()

        XCTAssertEqual(claimed, valid)
        XCTAssertNil(afterValid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.itemURL(for: corruptID, state: .failed).path))
    }

    func test_claimSpecificRequestDoesNotConsumeAnotherPendingItem() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let first = makeRequest()
        var second = makeRequest()
        second.id = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        second.payloads = [.text("Second item")]
        try await inbox.enqueue(first)
        try await inbox.enqueue(second)

        let claimedSecond = try await inbox.claim(requestID: second.id)
        let claimedFirst = try await inbox.claimNext()

        XCTAssertEqual(claimedSecond, second)
        XCTAssertEqual(claimedFirst, first)
    }

    func test_claimRefreshesProcessingLeaseForOldPendingRequest() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let request = makeRequest()
        try await inbox.enqueue(request)
        let pendingURL = inbox.itemURL(for: request.id, state: .pending)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: pendingURL.path
        )

        _ = try await inbox.claimNext()
        let recovered = try await inbox.recoverStaleProcessing(
            olderThan: 60,
            now: Date()
        )

        let finalState = try await inbox.state(of: request.id)
        XCTAssertEqual(recovered, [])
        XCTAssertEqual(finalState, .processing)
    }

    func test_crashedProcessingJobIsRecovered() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let request = makeRequest()
        try await inbox.enqueue(request)
        let initialClaim = try await inbox.claimNext()
        XCTAssertEqual(initialClaim, request)
        let processingURL = inbox.itemURL(for: request.id, state: .processing)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: processingURL.path
        )

        let recovered = try await inbox.recoverStaleProcessing(
            olderThan: 60,
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(recovered, [request.id])
        let reclaimed = try await inbox.claimNext()
        XCTAssertEqual(reclaimed, request)
    }

    func test_failedRequestCanBeReturnedToPendingForExplicitRetry() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let request = makeRequest()
        try await inbox.enqueue(request)
        _ = try await inbox.claimNext()
        try await inbox.fail(requestID: request.id)

        let failedIDs = try await inbox.requestIDs(in: .failed)
        let retried = try await inbox.retryFailed(requestID: request.id)
        let reclaimed = try await inbox.claimNext()

        XCTAssertEqual(failedIDs, [request.id])
        XCTAssertTrue(retried)
        XCTAssertEqual(reclaimed, request)
    }

    func test_reroutePendingAndFailedRequestsPreservesRecoverableCaptures() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let deletedDestination = UUID()
        let replacementDestination = UUID()
        var pending = makeRequest()
        pending.destinationID = deletedDestination
        var failed = makeRequest()
        failed.id = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        failed.destinationID = deletedDestination
        try await inbox.enqueue(pending)
        try await inbox.enqueue(failed)
        _ = try await inbox.claim(requestID: failed.id)
        try await inbox.fail(requestID: failed.id)

        let affectedBefore = try await inbox.requestIDs(
            referencingDestination: deletedDestination,
            states: [.pending, .failed]
        )
        let rerouted = try await inbox.rerouteRequests(
            from: deletedDestination,
            to: replacementDestination,
            states: [.pending, .failed]
        )
        let claimedPending = try await inbox.claim(requestID: pending.id)
        _ = try await inbox.retryFailed(requestID: failed.id)
        let claimedFailed = try await inbox.claim(requestID: failed.id)

        XCTAssertEqual(Set(affectedBefore), Set([pending.id, failed.id]))
        XCTAssertEqual(Set(rerouted), Set([pending.id, failed.id]))
        XCTAssertEqual(claimedPending?.destinationID, replacementDestination)
        XCTAssertEqual(claimedFailed?.destinationID, replacementDestination)
    }

    func test_rerouteOrphanedFailedRequestsLeavesValidRoutesUntouched() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let validDestination = UUID()
        let orphanedDestination = UUID()
        let replacement = UUID()
        var valid = makeRequest()
        valid.destinationID = validDestination
        var orphaned = makeRequest()
        orphaned.id = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        orphaned.destinationID = orphanedDestination
        for request in [valid, orphaned] {
            try await inbox.enqueue(request)
            _ = try await inbox.claim(requestID: request.id)
            try await inbox.fail(requestID: request.id)
        }

        let rerouted = try await inbox.rerouteOrphanedRequests(
            validDestinationIDs: [validDestination, replacement],
            to: replacement,
            states: [.failed]
        )
        _ = try await inbox.retryAllFailed()
        let first = try await inbox.claimNext()
        let second = try await inbox.claimNext()
        let destinations = Dictionary(uniqueKeysWithValues: [first, second].compactMap { request in
            request.map { ($0.id, $0.destinationID) }
        })

        XCTAssertEqual(rerouted, [orphaned.id])
        XCTAssertEqual(destinations[valid.id], validDestination)
        XCTAssertEqual(destinations[orphaned.id], replacement)
    }

    func test_retryAllFailedDoesNotTouchCompletedRequests() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let failed = makeRequest()
        var completed = makeRequest()
        completed.id = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        try await inbox.enqueue(failed)
        _ = try await inbox.claimNext()
        try await inbox.fail(requestID: failed.id)
        try await inbox.enqueue(completed)
        _ = try await inbox.claimNext()
        try await inbox.complete(requestID: completed.id)

        let retried = try await inbox.retryAllFailed()
        let completedIDs = try await inbox.requestIDs(in: .completed)

        XCTAssertEqual(retried, [failed.id])
        XCTAssertEqual(completedIDs, [completed.id])
    }

    func test_stateReportsLifecycleWithoutConsumingRequest() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let request = makeRequest()

        let missingState = try await inbox.state(of: request.id)
        XCTAssertNil(missingState)
        try await inbox.enqueue(request)
        let pendingState = try await inbox.state(of: request.id)
        XCTAssertEqual(pendingState, .pending)
        _ = try await inbox.claimNext()
        let processingState = try await inbox.state(of: request.id)
        XCTAssertEqual(processingState, .processing)
        try await inbox.complete(requestID: request.id)
        let completedState = try await inbox.state(of: request.id)
        XCTAssertEqual(completedState, .completed)
    }

    func test_purgeOrphanedStagingKeepsReferencedRequestsAndRemovesOnlyOldOrphans() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let referenced = makeRequest()
        try await inbox.enqueue(referenced)
        let stagingRoot = root.appendingPathComponent("inbox-staging", isDirectory: true)
        let referencedDirectory = stagingRoot.appendingPathComponent(referenced.id.uuidString.lowercased(), isDirectory: true)
        let orphanID = UUID()
        let orphanDirectory = stagingRoot.appendingPathComponent(orphanID.uuidString.lowercased(), isDirectory: true)
        let recentID = UUID()
        let recentDirectory = stagingRoot.appendingPathComponent(recentID.uuidString.lowercased(), isDirectory: true)
        for directory in [referencedDirectory, orphanDirectory, recentDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("asset".utf8).write(to: directory.appendingPathComponent("file.bin"))
        }
        let now = Date()
        for directory in [orphanDirectory, referencedDirectory] {
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-48 * 60 * 60)],
                ofItemAtPath: directory.path
            )
        }

        let purged = try await inbox.purgeOrphanedStaging(olderThan: 24 * 60 * 60, now: now)

        XCTAssertEqual(purged, [orphanID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: referencedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDirectory.path))
    }

    func test_purgeOldCompletedRemovesOnlyExpiredReceipts() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let request = makeRequest()
        try await inbox.enqueue(request)
        _ = try await inbox.claimNext()
        try await inbox.complete(requestID: request.id)
        let completedURL = inbox.itemURL(for: request.id, state: .completed)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: completedURL.path
        )

        let purged = try await inbox.purgeCompleted(
            olderThan: 60,
            now: Date(timeIntervalSince1970: 1_000)
        )

        let finalState = try await inbox.state(of: request.id)
        XCTAssertEqual(purged, [request.id])
        XCTAssertNil(finalState)
    }

    func test_completedRequestCannotBeClaimedAgain() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        let request = makeRequest()
        try await inbox.enqueue(request)
        _ = try await inbox.claimNext()
        let staging = root
            .appendingPathComponent("inbox-staging")
            .appendingPathComponent(request.id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("staged".utf8).write(to: staging.appendingPathComponent("asset.bin"))

        try await inbox.complete(requestID: request.id)

        let next = try await inbox.claimNext()
        let completedURL = inbox.itemURL(for: request.id, state: .completed)
        XCTAssertNil(next)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func test_completedReceiptReplacesPrivateRequestContentWithMetadataOnlyTombstone() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        var request = makeRequest()
        request.payloads = [
            .text("TOP SECRET NOTE BODY"),
            .url(URL(string: "https://private.example/client")!, title: "Private client"),
        ]
        try await inbox.enqueue(request)
        _ = try await inbox.claim(requestID: request.id)

        try await inbox.complete(requestID: request.id)

        let completedURL = inbox.itemURL(for: request.id, state: .completed)
        let data = try Data(contentsOf: completedURL)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(encoded.lowercased().contains(request.id.uuidString.lowercased()))
        XCTAssertFalse(encoded.contains("TOP SECRET"))
        XCTAssertFalse(encoded.contains("private.example"))
        XCTAssertFalse(encoded.contains("Private client"))
        XCTAssertFalse(encoded.lowercased().contains(request.destinationID.uuidString.lowercased()))
        XCTAssertThrowsError(try JSONDecoder().decode(CaptureRequest.self, from: data))
        let completedIDs = try await inbox.requestIDs(in: .completed)
        XCTAssertEqual(completedIDs, [request.id])
    }

    func test_existingLegacyCompletedRequestIsSanitizedOnNextInboxAccess() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(rootDirectoryURL: root, coordinator: ProcessLocalCaptureFileCoordinator.shared)
        var request = makeRequest()
        request.payloads = [.text("LEGACY PRIVATE BODY")]
        try await inbox.enqueue(request)
        _ = try await inbox.claim(requestID: request.id)
        let processingURL = inbox.itemURL(for: request.id, state: .processing)
        let completedURL = inbox.itemURL(for: request.id, state: .completed)
        try FileManager.default.moveItem(at: processingURL, to: completedURL)

        XCTAssertTrue(try String(contentsOf: completedURL, encoding: .utf8).contains("LEGACY PRIVATE BODY"))
        let completedState = try await inbox.state(of: request.id)
        XCTAssertEqual(completedState, .completed)

        let sanitized = try String(contentsOf: completedURL, encoding: .utf8)
        XCTAssertFalse(sanitized.contains("LEGACY PRIVATE BODY"))
        XCTAssertThrowsError(try JSONDecoder().decode(CaptureRequest.self, from: Data(sanitized.utf8)))
        let completedIDs = try await inbox.requestIDs(in: .completed)
        XCTAssertEqual(completedIDs, [request.id])
    }

    private func makeRequest() -> CaptureRequest {
        CaptureRequest(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            createdAt: Date(timeIntervalSince1970: 500),
            source: .shareExtension,
            destinationID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            payloads: [.text("Inbox item")]
        )
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureInboxTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
