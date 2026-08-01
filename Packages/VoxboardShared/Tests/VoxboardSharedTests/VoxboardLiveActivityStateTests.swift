import XCTest
@testable import VoxboardShared

final class VoxboardLiveActivityStateTests: XCTestCase {

    func test_defaultState_isIdleAndNotRecording() {
        let state = VoxboardLiveActivityState()
        XCTAssertFalse(state.isSegmentActive)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertNil(state.segmentStartedAt)
        XCTAssertNil(state.segmentRequestId)
    }

    func test_recordingState_carriesStartTimeAndRequestId() {
        let now = Date().timeIntervalSince1970
        let state = VoxboardLiveActivityState(
            isSegmentActive: true,
            segmentStartedAt: now,
            segmentRequestId: "request-1"
        )
        XCTAssertTrue(state.isSegmentActive)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertEqual(state.segmentStartedAt, now)
        XCTAssertEqual(state.segmentRequestId, "request-1")
    }

    func test_transcribingState_isNotRecording() {
        let state = VoxboardLiveActivityState(isTranscribing: true)
        XCTAssertFalse(state.isSegmentActive)
        XCTAssertTrue(state.isTranscribing)
        XCTAssertNil(state.segmentStartedAt)
        XCTAssertNil(state.segmentRequestId)
    }

    func test_state_isCodable() throws {
        let original = VoxboardLiveActivityState(
            isSegmentActive: true,
            isTranscribing: false,
            segmentStartedAt: 12_345,
            segmentRequestId: "request-1"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VoxboardLiveActivityState.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_idle_factory_isNotActive() {
        let state = VoxboardLiveActivityState.idle
        XCTAssertFalse(state.isSegmentActive)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertNil(state.segmentStartedAt)
        XCTAssertNil(state.segmentRequestId)
    }

    func test_legacyState_decodesWithoutRequestId() throws {
        let data = Data(#"{"isSegmentActive":true,"isTranscribing":false,"segmentStartedAt":12345}"#.utf8)
        let state = try JSONDecoder().decode(VoxboardLiveActivityState.self, from: data)

        XCTAssertTrue(state.isSegmentActive)
        XCTAssertEqual(state.segmentStartedAt, 12_345)
        XCTAssertNil(state.segmentRequestId)
    }
}
