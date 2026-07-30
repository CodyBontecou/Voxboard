import XCTest
@testable import VoxboardShared

#if os(iOS) || os(macOS)
final class VoiceActivityDetectionTests: XCTestCase {
    func testAssetRequiresCompleteCompiledModel() throws {
        let modelsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: modelsDirectory) }

        let modelDirectory = VoiceActivityModelAsset.modelURL(in: modelsDirectory)
        try FileManager.default.createDirectory(
            at: modelDirectory.appendingPathComponent("weights", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: modelDirectory.appendingPathComponent("coremldata.bin"))
        try Data().write(to: modelDirectory.appendingPathComponent("model.mil"))

        XCTAssertFalse(VoiceActivityModelAsset.isInstalled(in: modelsDirectory))

        try Data().write(to: modelDirectory.appendingPathComponent("weights/weight.bin"))
        XCTAssertTrue(VoiceActivityModelAsset.isInstalled(in: modelsDirectory))
    }

    func testPauseDurationIsClampedToSupportedRange() {
        XCTAssertEqual(AppConstants.clampedVoiceAutoStopPauseDuration(0.1), 0.5)
        XCTAssertEqual(AppConstants.clampedVoiceAutoStopPauseDuration(0.75), 0.75)
        XCTAssertEqual(AppConstants.clampedVoiceAutoStopPauseDuration(5), 2.0)
    }

    func testVadSilenceDurationCompensatesForFirstQuietFrame() {
        XCTAssertEqual(
            VoiceActivityModelAsset.stateMachineSilenceDuration(forRequestedPause: 0.75),
            0.494,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            VoiceActivityModelAsset.stateMachineSilenceDuration(forRequestedPause: 0.5),
            0.244,
            accuracy: 0.000_001
        )
    }

    func testLiveSegmentOriginsResolveToIndependentCapturePaths() {
        let cases: [(RecordingCommand.Origin, VoiceAutoStopCapturePath)] = [
            (.keyboardExtension, .keyboard),
            (.inAppDraft, .inAppDraft),
            (.inAppImmediate, .inAppImmediate),
            (.quickRecord, .quickRecord),
            (.liveActivity, .liveActivity),
            (.watch, .watch),
        ]

        for (origin, expectedPath) in cases {
            let command = RecordingCommand(
                requestId: origin.rawValue,
                action: .startSegment,
                modelId: origin == .keyboardExtension
                    ? "parakeet-v3"
                    : TranscriptionBackendID.automatic,
                origin: origin
            )

            XCTAssertEqual(
                VoiceAutoStopPolicy.capturePath(for: command),
                expectedPath
            )
        }
    }

    func testUnidentifiedAndStopCommandsDoNotResolveAutoStopPath() {
        let unidentifiedStart = RecordingCommand(
            requestId: "unidentified",
            action: .startSegment,
            modelId: "ggml-base"
        )
        let stop = RecordingCommand(
            requestId: "stop",
            action: .stopSegment,
            modelId: TranscriptionBackendID.automatic,
            origin: .keyboardExtension
        )

        XCTAssertNil(VoiceAutoStopPolicy.capturePath(for: unidentifiedStart))
        XCTAssertNil(VoiceAutoStopPolicy.capturePath(for: stop))
    }
}
#endif
