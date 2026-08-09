import XCTest
@testable import VoxboardShared

final class VoxboardLiveActivityStateTests: XCTestCase {

    func test_defaultState_isIdleAndNotRecording() {
        let state = VoxboardLiveActivityState()
        XCTAssertFalse(state.isSegmentActive)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertNil(state.segmentStartedAt)
        XCTAssertNil(state.segmentRequestId)
        XCTAssertNil(state.transcriptionProgress)
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
        XCTAssertNil(state.transcriptionProgress)
    }

    func test_transcribingState_isNotRecording() {
        let state = VoxboardLiveActivityState(
            isTranscribing: true,
            transcriptionProgress: 0.42
        )
        XCTAssertFalse(state.isSegmentActive)
        XCTAssertTrue(state.isTranscribing)
        XCTAssertNil(state.segmentStartedAt)
        XCTAssertNil(state.segmentRequestId)
        XCTAssertEqual(state.transcriptionProgress, 0.42)
    }

    func test_state_isCodable() throws {
        let original = VoxboardLiveActivityState(
            isSegmentActive: false,
            isTranscribing: true,
            segmentStartedAt: nil,
            segmentRequestId: nil,
            transcriptionProgress: 0.42
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
        XCTAssertNil(state.transcriptionProgress)
    }

    func test_legacyState_decodesWithoutRequestIdOrProgress() throws {
        let data = Data(#"{"isSegmentActive":true,"isTranscribing":false,"segmentStartedAt":12345}"#.utf8)
        let state = try JSONDecoder().decode(VoxboardLiveActivityState.self, from: data)

        XCTAssertTrue(state.isSegmentActive)
        XCTAssertEqual(state.segmentStartedAt, 12_345)
        XCTAssertNil(state.segmentRequestId)
        XCTAssertNil(state.transcriptionProgress)
    }

    func test_transcriptionProgressClampsInInitializer() {
        XCTAssertEqual(
            VoxboardLiveActivityState(
                isTranscribing: true,
                transcriptionProgress: 4
            ).transcriptionProgress,
            1
        )
        XCTAssertNil(
            VoxboardLiveActivityState(
                isTranscribing: true,
                transcriptionProgress: .infinity
            ).transcriptionProgress
        )
    }
}
