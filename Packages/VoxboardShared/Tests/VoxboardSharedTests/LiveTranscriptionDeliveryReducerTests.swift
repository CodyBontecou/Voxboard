import XCTest
@testable import VoxboardShared

final class LiveTranscriptionDeliveryReducerTests: XCTestCase {
    func testCheckpointPersistsBeforeDeltaIsReturned() {
        let snapshot = LiveTranscriptionSnapshot(
            requestId: "request",
            revision: 2,
            finalizedText: "hello world",
            updatedAt: 42
        )
        var persisted: LiveTranscriptionDeliveryCheckpoint?
        let outcome = LiveTranscriptionDeliveryReducer.apply(
            snapshot,
            requestID: "request",
            state: LiveTranscriptionDeliveryState(deliveredText: "hello", revision: 1)
        ) { checkpoint in
            persisted = checkpoint
            return true
        }

        XCTAssertEqual(persisted?.deliveredText, "hello world")
        XCTAssertEqual(
            outcome,
            .committed(
                state: LiveTranscriptionDeliveryState(deliveredText: "hello world", revision: 2),
                delta: " world"
            )
        )
    }

    func testFailedCheckpointWriteReturnsNoInsertableDelta() {
        let snapshot = LiveTranscriptionSnapshot(
            requestId: "request",
            revision: 2,
            finalizedText: "hello world",
            updatedAt: 42
        )
        XCTAssertEqual(
            LiveTranscriptionDeliveryReducer.apply(
                snapshot,
                requestID: "request",
                state: LiveTranscriptionDeliveryState(deliveredText: "hello", revision: 1),
                persistCheckpoint: { _ in false }
            ),
            .persistenceFailed
        )
    }

    func testRestartRestorationSuppressesDuplicateSnapshotReplay() {
        let checkpoint = LiveTranscriptionDeliveryCheckpoint(
            requestId: "request",
            revision: 2,
            deliveredText: "hello world"
        )
        let restored = LiveTranscriptionDeliveryReducer.restoredState(
            from: checkpoint,
            requestID: "request"
        )
        let snapshot = LiveTranscriptionSnapshot(
            requestId: "request",
            revision: 2,
            finalizedText: "hello world",
            updatedAt: 42
        )
        var persisted = false
        let outcome = LiveTranscriptionDeliveryReducer.apply(
            snapshot,
            requestID: "request",
            state: restored
        ) { _ in
            persisted = true
            return true
        }

        XCTAssertEqual(outcome, .ignoredStale)
        XCTAssertFalse(persisted)
    }

    func testTornCheckpointRestoresEmptyAndNonMonotonicSnapshotFailsClosed() throws {
        let torn = Data("{synthetic torn delivery checkpoint".utf8)
        let decoded = try? JSONDecoder().decode(LiveTranscriptionDeliveryCheckpoint.self, from: torn)
        let restored = LiveTranscriptionDeliveryReducer.restoredState(
            from: decoded,
            requestID: "request"
        )
        XCTAssertEqual(restored, LiveTranscriptionDeliveryState())

        let nonMonotonic = LiveTranscriptionSnapshot(
            requestId: "request",
            revision: 3,
            finalizedText: "different",
            updatedAt: 42
        )
        XCTAssertEqual(
            LiveTranscriptionDeliveryReducer.apply(
                nonMonotonic,
                requestID: "request",
                state: LiveTranscriptionDeliveryState(deliveredText: "hello", revision: 2),
                persistCheckpoint: { _ in true }
            ),
            .ignoredNonMonotonic
        )
    }
}
