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
}
