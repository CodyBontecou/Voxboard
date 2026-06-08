import XCTest
@testable import VoxboardShared

final class VoxboardLiveActivityStateTests: XCTestCase {

    func test_defaultState_isIdleAndNotRecording() {
        let state = VoxboardLiveActivityState()
        XCTAssertFalse(state.isSegmentActive)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertNil(state.segmentStartedAt)
    }

    func test_recordingState_carriesStartTime() {
        let now = Date().timeIntervalSince1970
        let state = VoxboardLiveActivityState(isSegmentActive: true, segmentStartedAt: now)
        XCTAssertTrue(state.isSegmentActive)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertEqual(state.segmentStartedAt, now)
    }

    func test_transcribingState_isNotRecording() {
        let state = VoxboardLiveActivityState(isTranscribing: true)
        XCTAssertFalse(state.isSegmentActive)
        XCTAssertTrue(state.isTranscribing)
        XCTAssertNil(state.segmentStartedAt)
    }

    func test_state_isCodable() throws {
        let original = VoxboardLiveActivityState(
            isSegmentActive: true,
            isTranscribing: false,
            segmentStartedAt: 12_345
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
    }
}
