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

    func testKeyboardCommandRunsItsExplicitPreset() {
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
            .runVox(flowID: "custom")
        )
    }

    func testKeyboardCommandWithoutPresetIsTranscriptionOnly() {
        let command = RecordingCommand(
            requestId: "keyboard",
            action: .startSegment,
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

    func testPresetSnapshotRemainsImmutableWhenLivePresetChanges() {
        let original = CapturePreset(
            id: "custom",
            name: "Original",
            symbolName: "location",
            locationPolicy: CapturePresetLocationPolicy(isEnabled: true, precision: .exact)
        )
        var live = original
        let snapshot = RecordingCompletionMode.presetSnapshot(
            for: .runVox(flowID: original.id),
            lookup: { $0 == live.id ? live : nil },
            fallback: { live }
        )

        live.name = "Edited Later"
        live.locationPolicy.precision = .city

        XCTAssertEqual(snapshot, original)
        XCTAssertEqual(snapshot?.locationPolicy.precision, .exact)
        XCTAssertEqual(snapshot?.name, "Original")
        XCTAssertNil(RecordingCompletionMode.presetSnapshot(
            for: .captureDraft(attachAudio: false),
            lookup: { _ in live },
            fallback: { live }
        ))

        let draftVoicePolicy = RecordingCompletionMode.voiceProcessingConfiguration(
            for: .captureDraft(attachAudio: false),
            selectedPreset: original
        )
        live.speakerDiarizationEnabled = true
        XCTAssertEqual(
            draftVoicePolicy,
            RecordingVoiceProcessingConfiguration(
                presetID: "custom",
                speakerDiarizationEnabled: false
            )
        )
        XCTAssertNil(RecordingCompletionMode.voiceProcessingConfiguration(
            for: .keyboardTranscription,
            selectedPreset: original
        ))
    }

    func testSegmentHandoffSnapshotPreservesDraftSessionAndPresetIdentity() {
        let draftID = UUID()
        let sessionID = UUID()
        let preset = CapturePreset(id: "snapshot", name: "Snapshot", symbolName: "mic")

        let snapshot = PersistentRecorder.handoffSnapshot(
            draftRequestID: draftID,
            liveSessionID: sessionID,
            presetSnapshot: preset,
            voiceProcessingConfiguration: RecordingVoiceProcessingConfiguration(
                presetID: preset.id,
                speakerDiarizationEnabled: true
            )
        )

        XCTAssertEqual(snapshot.draftRequestID, draftID)
        XCTAssertEqual(snapshot.liveSessionID, sessionID)
        XCTAssertEqual(snapshot.presetSnapshot, preset)
        XCTAssertEqual(snapshot.voiceProcessingConfiguration?.presetID, preset.id)
        XCTAssertEqual(snapshot.voiceProcessingConfiguration?.speakerDiarizationEnabled, true)
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
