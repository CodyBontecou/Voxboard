import VoxboardShared
import XCTest
@testable import Voxboard

final class RecordingCompletionModeTests: XCTestCase {
    func testCompletionModesResolveDistinctAutoStopOrigins() {
        XCTAssertEqual(
            RecordingCompletionMode.keyboardTranscription.defaultCommandOrigin,
            .keyboardExtension
        )
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

    func testKeyboardCommandIsTranscriptionOnly() {
        let command = RecordingCommand(
            requestId: "keyboard",
            action: .startSegment,
            flowId: "custom",
            origin: .keyboardExtension
        )

        XCTAssertEqual(
            RecordingCompletionMode.completionMode(
                forExternalCommand: command,
                fallbackFlowID: "general"
            ),
            .keyboardTranscription
        )
    }

    func testLegacyKeyboardCommandWithoutOriginIsTranscriptionOnly() {
        let command = RecordingCommand(
            requestId: "legacy-keyboard",
            action: .startSegment,
            flowId: "custom"
        )

        XCTAssertEqual(
            RecordingCompletionMode.completionMode(
                forExternalCommand: command,
                fallbackFlowID: "general"
            ),
            .keyboardTranscription
        )
    }

    func testNonKeyboardExternalCommandStillRunsItsPreset() {
        let command = RecordingCommand(
            requestId: "live-activity",
            action: .startSegment,
            flowId: "custom",
            origin: .liveActivity
        )

        XCTAssertEqual(
            RecordingCompletionMode.completionMode(
                forExternalCommand: command,
                fallbackFlowID: "general"
            ),
            .runVox(flowID: "custom")
        )
    }
}
