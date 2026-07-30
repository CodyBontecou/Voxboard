import XCTest
@testable import Voxboard

final class RecordingCompletionModeTests: XCTestCase {
    func testInAppCompletionModesResolveDistinctAutoStopOrigins() {
        XCTAssertEqual(
            RecordingCompletionMode.captureDraft(attachAudio: false).defaultCommandOrigin,
            .inAppDraft
        )
        XCTAssertEqual(
            RecordingCompletionMode.runVox(flowID: "general").defaultCommandOrigin,
            .inAppImmediate
        )
    }

    func testExternalCapturePathOverridesInAppCompletionOrigin() {
        let completionMode = RecordingCompletionMode.runVox(flowID: "general")

        XCTAssertEqual(completionMode.commandOrigin(overriding: .quickRecord), .quickRecord)
        XCTAssertEqual(completionMode.commandOrigin(overriding: .watch), .watch)
    }
}
