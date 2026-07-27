import XCTest
@testable import VoxboardShared

final class TranscriptionIPCTests: XCTestCase {
    func testLiveSnapshotRoundTrip() throws {
        let snapshot = LiveTranscriptionSnapshot(
            requestId: "request",
            revision: 3,
            finalizedText: "Stable text",
            volatileText: "tentative",
            updatedAt: 42
        )

        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(LiveTranscriptionSnapshot.self, from: data), snapshot)
    }

    func testLegacyResponseDecodesWithoutLiveMetadata() throws {
        let data = Data(#"{"requestId":"request","text":"Done","error":null}"#.utf8)
        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)

        XCTAssertEqual(response.text, "Done")
        XCTAssertNil(response.usesLiveTranscription)
    }

    func testLegacyRecordingCommandDecodesWithoutOrigin() throws {
        let data = Data(#"{"requestId":"request","action":"startSegment","modelId":"automatic","language":"auto","flowId":null}"#.utf8)
        let command = try JSONDecoder().decode(RecordingCommand.self, from: data)

        XCTAssertEqual(command.requestId, "request")
        XCTAssertNil(command.origin)
    }

    func testLegacyRecordingStatusDecodesWithoutStoppedTimestamp() throws {
        let data = Data(#"{"requestId":"request","phase":"transcribing","message":null,"recordingStartedAt":40}"#.utf8)
        let status = try JSONDecoder().decode(RecordingStatus.self, from: data)

        XCTAssertEqual(status.recordingStartedAt, 40)
        XCTAssertNil(status.recordingStoppedAt)
    }

    func testRecordingStatusRoundTripsStoppedTimestamp() throws {
        let status = RecordingStatus(
            requestId: "request",
            phase: .transcribing,
            recordingStartedAt: 40,
            recordingStoppedAt: 45
        )

        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(RecordingStatus.self, from: data)

        XCTAssertEqual(decoded.recordingStartedAt, 40)
        XCTAssertEqual(decoded.recordingStoppedAt, 45)
    }
}
