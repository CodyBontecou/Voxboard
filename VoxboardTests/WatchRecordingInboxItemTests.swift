import XCTest
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
        statusMessage: String? = nil
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
            capturesRecordingWithoutTranscript: capturesRecordingWithoutTranscript,
            statusMessage: statusMessage
        )
    }
}
