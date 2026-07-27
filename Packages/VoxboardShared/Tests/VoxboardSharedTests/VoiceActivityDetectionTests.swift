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
        XCTAssertEqual(AppConstants.clampedParakeetKeyboardPauseDuration(0.1), 0.5)
        XCTAssertEqual(AppConstants.clampedParakeetKeyboardPauseDuration(0.75), 0.75)
        XCTAssertEqual(AppConstants.clampedParakeetKeyboardPauseDuration(5), 2.0)
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

    func testOnlyExplicitKeyboardParakeetIsEligible() {
        let parakeet = RecordingCommand(
            requestId: "parakeet",
            action: .startSegment,
            modelId: "parakeet-v3",
            origin: .keyboardExtension
        )
        XCTAssertTrue(ParakeetKeyboardEndOfSpeechPolicy.isEligible(command: parakeet))

        let automatic = RecordingCommand(
            requestId: "automatic",
            action: .startSegment,
            modelId: TranscriptionBackendID.automatic,
            origin: .keyboardExtension
        )
        XCTAssertFalse(ParakeetKeyboardEndOfSpeechPolicy.isEligible(command: automatic))

        let whisper = RecordingCommand(
            requestId: "whisper",
            action: .startSegment,
            modelId: "ggml-base",
            origin: .keyboardExtension
        )
        XCTAssertFalse(ParakeetKeyboardEndOfSpeechPolicy.isEligible(command: whisper))

        let inAppParakeet = RecordingCommand(
            requestId: "inapp",
            action: .startSegment,
            modelId: "parakeet-v2"
        )
        XCTAssertFalse(ParakeetKeyboardEndOfSpeechPolicy.isEligible(command: inAppParakeet))
    }
}
#endif
