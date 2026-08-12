import XCTest
import VoxboardShared
@testable import Voxboard

final class WatchRecordingInboxItemTests: XCTestCase {
    func testRecordingWithoutTranscriptIntentRoundTrips() throws {
        let item = makeItem(capturesRecordingWithoutTranscript: true)

        let decoded = try JSONDecoder().decode(
            WatchRecordingInboxItem.self,
            from: JSONEncoder().encode(item)
        )

        XCTAssertTrue(decoded.capturesRecordingWithoutTranscript)
    }

    func testLegacyQueueItemDefaultsToIncludingTranscript() throws {
        let encoded = try JSONEncoder().encode(
            makeItem(capturesRecordingWithoutTranscript: true)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "capturesRecordingWithoutTranscript")

        let decoded = try JSONDecoder().decode(
            WatchRecordingInboxItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertFalse(decoded.capturesRecordingWithoutTranscript)
    }

    func testWatchLocationOutcomeRoundTripsWithoutReacquisitionState() throws {
        let attemptedAt = Date(timeIntervalSince1970: 1_700_000_005)
        let item = makeItem(
            capturesRecordingWithoutTranscript: false,
            locationOutcome: .unavailable(.permissionDenied, attemptedAt: attemptedAt)
        )

        let decoded = try JSONDecoder().decode(
            WatchRecordingInboxItem.self,
            from: JSONEncoder().encode(item)
        )

        XCTAssertEqual(
            decoded.locationOutcome,
            .unavailable(.permissionDenied, attemptedAt: attemptedAt)
        )
    }

    func testInterruptedStopPlaceholderRoundTripsForEnabledPreset() throws {
        var flow = CapturePresetStore.makeCustomFlow()
        flow.locationPolicy = CapturePresetLocationPolicy(isEnabled: true, unavailableBehavior: .ask)
        let stoppedAt = Date(timeIntervalSince1970: 1_700_000_006)
        let item = WatchRecordingInboxItem(
            id: UUID().uuidString,
            requestID: UUID(),
            filename: "watch-interrupted.m4a",
            originalFilename: "watch-interrupted.m4a",
            createdAt: stoppedAt.addingTimeInterval(-10),
            receivedAt: stoppedAt,
            duration: 10,
            flowSnapshot: flow,
            flowSnapshotPayload: try JSONEncoder().encode(flow),
            locationOutcome: .unavailable(.unavailable, attemptedAt: stoppedAt)
        )

        let recovered = try JSONDecoder().decode(
            WatchRecordingInboxItem.self,
            from: JSONEncoder().encode(item)
        )
        XCTAssertEqual(
            recovered.locationOutcome,
            .unavailable(.unavailable, attemptedAt: stoppedAt)
        )
        XCTAssertEqual(recovered.flowSnapshot?.locationPolicy.unavailableBehavior, .ask)
    }

    func testTransferredLocationOutcomeDecodesFromOpaqueWatchMetadata() throws {
        let outcome = CaptureLocationOutcome.available(CaptureLocationSnapshot(
            latitude: 45.50,
            longitude: -73.57,
            timestamp: Date(timeIntervalSince1970: 1_700_000_010),
            source: .watch,
            precision: .city,
            label: CaptureLocationLabel(city: "Montréal")
        ))
        let metadata: [String: Any] = [
            WatchRecordingFileMetadataKey.locationOutcome: try JSONEncoder().encode(outcome)
        ]

        XCTAssertEqual(
            WatchRecordingFileMetadataKey.decodeLocationOutcome(from: metadata),
            outcome
        )
        let malformed = [
            WatchRecordingFileMetadataKey.locationOutcome: Data("invalid".utf8)
        ]
        XCTAssertNil(WatchRecordingFileMetadataKey.decodeLocationOutcome(from: malformed))
        XCTAssertTrue(WatchRecordingFileMetadataKey.containsIncompatibleLocationOutcome(in: malformed))
        XCTAssertFalse(WatchRecordingFileMetadataKey.containsIncompatibleLocationOutcome(in: [:]))
        XCTAssertFalse(WatchRecordingFileMetadataKey.containsIncompatibleLocationOutcome(in: metadata))
    }

    func testLegacyQueueItemDefaultsToNoWatchLocationOutcome() throws {
        let encoded = try JSONEncoder().encode(
            makeItem(
                capturesRecordingWithoutTranscript: false,
                locationOutcome: .unavailable(.timeout, attemptedAt: Date())
            )
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "locationOutcome")

        let decoded = try JSONDecoder().decode(
            WatchRecordingInboxItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.locationOutcome)
    }

    func testCancelPolicyTerminatesUnavailableOrMissingOutcomeButNotAvailable() {
        var flow = CapturePresetStore.makeCustomFlow()
        flow.locationPolicy = CapturePresetLocationPolicy(
            isEnabled: true,
            unavailableBehavior: .cancel
        )
        func item(_ outcome: CaptureLocationOutcome?) -> WatchRecordingInboxItem {
            WatchRecordingInboxItem(
                id: UUID().uuidString,
                requestID: UUID(),
                filename: "watch-cancel.m4a",
                originalFilename: "watch-cancel.m4a",
                createdAt: Date(),
                receivedAt: Date(),
                duration: 1,
                flowSnapshot: flow,
                locationOutcome: outcome
            )
        }

        XCTAssertTrue(item(nil).shouldCancelForUnavailableLocation)
        XCTAssertTrue(item(.unavailable(.timeout, attemptedAt: Date())).shouldCancelForUnavailableLocation)
        XCTAssertFalse(item(.available(CaptureLocationSnapshot(
            latitude: 1,
            longitude: 2,
            timestamp: Date(),
            source: .watch,
            precision: .exact
        ))).shouldCancelForUnavailableLocation)
    }

    func testTerminalTombstoneStripsLocationAndPresetTemplatePayload() throws {
        var flow = CapturePresetStore.makeCustomFlow()
        flow.locationPolicy = CapturePresetLocationPolicy(
            isEnabled: true,
            advancedTemplate: "secret: {{coordinates}}"
        )
        var item = WatchRecordingInboxItem(
            id: UUID().uuidString,
            requestID: UUID(),
            filename: "watch-private.m4a",
            originalFilename: "watch-private.m4a",
            createdAt: Date(),
            receivedAt: Date(),
            duration: 2,
            flowSnapshot: flow,
            flowSnapshotPayload: try JSONEncoder().encode(flow),
            locationOutcome: .available(CaptureLocationSnapshot(
                latitude: 12.345678,
                longitude: -98.765432,
                timestamp: Date(),
                source: .watch,
                precision: .exact
            )),
            reservedOutputFolderBookmark: Data("private-folder".utf8),
            phase: .delivered
        )

        item.scrubSensitivePayloadForTombstone()
        let encoded = try JSONEncoder().encode(item)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertNil(item.locationOutcome)
        XCTAssertNil(item.flowSnapshot)
        XCTAssertNil(item.flowSnapshotPayload)
        XCTAssertNil(item.reservedOutputFolderBookmark)
        XCTAssertFalse(json.contains("12.345678"))
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("private-folder"))
    }

    func testTranscriptionLimitStatusOffersUpgrade() {
        let item = makeItem(
            capturesRecordingWithoutTranscript: false,
            statusMessage: WatchRecordingStatusMessage.transcriptionLimitReached
        )

        XCTAssertTrue(item.isWaitingForTranscriptionUpgrade)
    }

    func testOrdinaryQueuedStatusDoesNotOfferUpgrade() {
        let item = makeItem(
            capturesRecordingWithoutTranscript: false,
            statusMessage: "Received from Apple Watch"
        )

        XCTAssertFalse(item.isWaitingForTranscriptionUpgrade)
    }

    private func makeItem(
        capturesRecordingWithoutTranscript: Bool,
        statusMessage: String? = nil,
        locationOutcome: CaptureLocationOutcome? = nil
    ) -> WatchRecordingInboxItem {
        WatchRecordingInboxItem(
            id: UUID().uuidString,
            requestID: UUID(),
            filename: "watch-recording.m4a",
            originalFilename: "recording.m4a",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_001),
            duration: 8,
            flowSnapshot: nil,
            locationOutcome: locationOutcome,
            capturesRecordingWithoutTranscript: capturesRecordingWithoutTranscript,
            statusMessage: statusMessage
        )
    }
}
