import Foundation
import XCTest
@testable import VoxboardShared

final class CaptureDeliveryUsageStoreTests: XCTestCase {
    func test_tenSuccessfulCapturesAreAllowedAndEleventhIsDenied() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        for index in 0..<10 {
            let request = makeRequest(index: index)
            let reservation = try await fixture.store.reserve(for: request)
            try await fixture.store.commit(reservation)
        }

        let snapshot = try await fixture.store.snapshot()
        XCTAssertEqual(snapshot.successfulCapturesUsed, 10)
        XCTAssertEqual(snapshot.capturesRemaining, 0)
        XCTAssertTrue(snapshot.isAtLimit)

        do {
            _ = try await fixture.store.reserve(for: makeRequest(index: 10))
            XCTFail("Expected the eleventh Capture delivery to be denied")
        } catch let error as CaptureDeliveryQuotaError {
            XCTAssertEqual(error, .limitReached(limit: 10))
        }
    }

    func test_releasedReservationDoesNotConsumeSuccessfulCapture() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let request = makeRequest(index: 0)

        let reservation = try await fixture.store.reserve(for: request)
        await fixture.store.release(reservation)

        let snapshot = try await fixture.store.snapshot()
        XCTAssertEqual(snapshot.successfulCapturesUsed, 0)
        XCTAssertEqual(snapshot.reservedCaptureSlots, 0)
    }

    func test_duplicateRequestIDCommitsExactlyOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let request = makeRequest(index: 0)

        let first = try await fixture.store.reserve(for: request)
        let duplicate = try await fixture.store.reserve(for: request)
        try await fixture.store.commit(first)
        try await fixture.store.commit(duplicate)
        let afterCommit = try await fixture.store.reserve(for: request)

        let snapshot = try await fixture.store.snapshot()
        XCTAssertEqual(snapshot.successfulCapturesUsed, 1)
        XCTAssertEqual(afterCommit, .alreadyCounted(requestID: request.id))
    }

    func test_voiceTranscriptsBypassExhaustedCaptureQuota() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        for index in 0..<10 {
            let reservation = try await fixture.store.reserve(for: makeRequest(index: index))
            try await fixture.store.commit(reservation)
        }
        let voice = CaptureRequest(
            source: .shortcut,
            deliveryKind: .meteredVoiceTranscript,
            destinationID: UUID(),
            payloads: [.text("Already metered by transcription time")]
        )

        let reservation = try await fixture.store.reserve(for: voice)
        try await fixture.store.commit(reservation)

        let snapshot = try await fixture.store.snapshot()
        XCTAssertEqual(reservation, .bypassed(requestID: voice.id))
        XCTAssertEqual(snapshot.successfulCapturesUsed, 10)
    }

    func test_unlockedUsersBypassCaptureAccounting() async throws {
        let fixture = try makeFixture(isUnlocked: true)
        defer { fixture.cleanup() }
        let request = makeRequest(index: 0)

        let reservation = try await fixture.store.reserve(for: request)
        try await fixture.store.commit(reservation)

        let snapshot = try await fixture.store.snapshot()
        XCTAssertEqual(reservation, .bypassed(requestID: request.id))
        XCTAssertEqual(snapshot.successfulCapturesUsed, 0)
    }

    func test_keychainHighWaterRestoresPartialCountAfterLedgerDeletion() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        for index in 0..<6 {
            let reservation = try await fixture.store.reserve(for: makeRequest(index: index))
            try await fixture.store.commit(reservation)
        }
        try FileManager.default.removeItem(at: fixture.ledgerURL)

        let reinstalledStore = CaptureDeliveryUsageStore(
            ledgerURL: fixture.ledgerURL,
            coordinator: fixture.coordinator,
            highWaterStore: fixture.highWater,
            isUnlocked: { false },
            mirrorSuccessfulCount: { _ in }
        )
        let restored = try await reinstalledStore.snapshot()

        XCTAssertEqual(restored.successfulCapturesUsed, 6)
        XCTAssertEqual(restored.capturesRemaining, 4)
    }

    func test_committedRequestDoesNotWriteDestinationAgainWhenMarkersAreDisabled() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let destinationRoot = fixture.root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md"),
            retryProtectionEnabled: false
        )
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.text("Exactly once")]
        )
        let pipeline = CapturePipeline(deliveryAccounting: fixture.store)

        _ = try await pipeline.capture(request, destination: destination, rootURL: destinationRoot)
        let retry = try await pipeline.capture(request, destination: destination, rootURL: destinationRoot)

        let markdown = try String(
            contentsOf: destinationRoot.appendingPathComponent("Inbox.md"),
            encoding: .utf8
        )
        XCTAssertEqual(markdown.components(separatedBy: "Exactly once").count - 1, 1)
        XCTAssertTrue(retry.writeReceipt.wasAlreadyApplied)
        let snapshot = try await fixture.store.snapshot()
        XCTAssertEqual(snapshot.successfulCapturesUsed, 1)
    }

    func test_keychainRequestIDPreventsDoubleCountAfterCommitCrashWindow() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let request = makeRequest(index: 0)
        _ = try await fixture.store.reserve(for: request)

        // Simulate process death after Keychain was raised for a verified write
        // but before the coordinated App Group ledger was persisted.
        try fixture.highWater.raise(to: CaptureUsageHighWaterMark(
            successfulCaptureCount: 1,
            committedRequestIDs: [request.id]
        ))
        let relaunchedStore = CaptureDeliveryUsageStore(
            ledgerURL: fixture.ledgerURL,
            coordinator: fixture.coordinator,
            highWaterStore: fixture.highWater,
            isUnlocked: { false },
            mirrorSuccessfulCount: { _ in }
        )

        let retryReservation = try await relaunchedStore.reserve(for: request)
        let snapshot = try await relaunchedStore.snapshot()

        XCTAssertEqual(retryReservation, .alreadyCounted(requestID: request.id))
        XCTAssertEqual(snapshot.successfulCapturesUsed, 1)
        XCTAssertEqual(snapshot.reservedCaptureSlots, 0)
    }

    func test_twoStoreInstancesCannotReserveMoreThanTenDistinctSlots() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let secondStore = CaptureDeliveryUsageStore(
            ledgerURL: fixture.ledgerURL,
            coordinator: fixture.coordinator,
            highWaterStore: fixture.highWater,
            isUnlocked: { false },
            mirrorSuccessfulCount: { _ in }
        )

        let allowedCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<12 {
                let request = makeRequest(index: index)
                let store = index.isMultiple(of: 2) ? fixture.store : secondStore
                group.addTask {
                    do {
                        _ = try await store.reserve(for: request)
                        return true
                    } catch CaptureDeliveryQuotaError.limitReached {
                        return false
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await allowed in group where allowed { count += 1 }
            return count
        }

        let snapshot = try await fixture.store.snapshot()
        XCTAssertEqual(allowedCount, 10)
        XCTAssertEqual(snapshot.successfulCapturesUsed, 0)
        XCTAssertEqual(snapshot.reservedCaptureSlots, 10)
    }

    private func makeRequest(index: Int) -> CaptureRequest {
        let suffix = String(format: "%012d", index + 1)
        return CaptureRequest(
            id: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-\(suffix)")!,
            source: .app,
            destinationID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            payloads: [.text("Capture \(index)")]
        )
    }

    private func makeFixture(isUnlocked: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CaptureDeliveryUsageStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledgerURL = root.appendingPathComponent("capture-usage-v1.json")
        let highWater = InMemoryCaptureUsageHighWaterMarkStore()
        let coordinator = ProcessLocalCaptureFileCoordinator()
        let store = CaptureDeliveryUsageStore(
            ledgerURL: ledgerURL,
            coordinator: coordinator,
            highWaterStore: highWater,
            isUnlocked: { isUnlocked },
            mirrorSuccessfulCount: { _ in }
        )
        return Fixture(
            root: root,
            ledgerURL: ledgerURL,
            highWater: highWater,
            coordinator: coordinator,
            store: store
        )
    }
}

private struct Fixture {
    let root: URL
    let ledgerURL: URL
    let highWater: InMemoryCaptureUsageHighWaterMarkStore
    let coordinator: ProcessLocalCaptureFileCoordinator
    let store: CaptureDeliveryUsageStore

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class InMemoryCaptureUsageHighWaterMarkStore: CaptureUsageHighWaterMarkStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var highWaterMark = CaptureUsageHighWaterMark(successfulCaptureCount: 0)

    func load() throws -> CaptureUsageHighWaterMark {
        lock.lock()
        defer { lock.unlock() }
        return highWaterMark
    }

    func raise(to candidate: CaptureUsageHighWaterMark) throws {
        lock.lock()
        defer { lock.unlock() }
        let mergedIDs = highWaterMark.committedRequestIDs.union(candidate.committedRequestIDs)
        highWaterMark = CaptureUsageHighWaterMark(
            successfulCaptureCount: max(
                highWaterMark.successfulCaptureCount,
                candidate.successfulCaptureCount,
                mergedIDs.count
            ),
            committedRequestIDs: mergedIDs
        )
    }
}
