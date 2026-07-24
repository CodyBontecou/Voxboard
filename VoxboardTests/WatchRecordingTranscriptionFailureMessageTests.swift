import XCTest
import VoxboardShared
@testable import Voxboard

final class WatchRecordingTranscriptionFailureMessageTests: XCTestCase {
    func testRecognitionFailureIncludesActionableBackendReason() {
        let error = OnDeviceTranscriptionError.systemBackendFailed(
            "Speech Recognition access is off. Enable it in Settings, then try again."
        )

        XCTAssertEqual(
            WatchRecordingTranscriptionFailureMessage.recognition(for: error),
            "Transcription failed: Apple Speech could not start: Speech Recognition access is off. Enable it in Settings, then try again. The Watch recording is saved for retry."
        )
    }

    func testRecognitionFailureExplainsWhenSelectedModelIsUnavailable() {
        XCTAssertEqual(
            WatchRecordingTranscriptionFailureMessage.recognition(
                for: OnDeviceTranscriptionError.modelUnavailable
            ),
            "Transcription failed: Download the selected transcription model before generating a transcript. The Watch recording is saved for retry."
        )
    }

    func testNoSpeechFailureUsesPlainLanguage() {
        XCTAssertEqual(
            WatchRecordingTranscriptionFailureMessage.recognition(
                for: OnDeviceTranscriptionError.noSpeechDetected
            ),
            "No recognizable speech was found. The Watch recording is saved for retry."
        )
    }

    func testUnexpectedRecognitionFailurePreservesProvidedReason() {
        let error = NSError(
            domain: "WatchTranscriptionTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The language asset is still downloading"]
        )

        XCTAssertEqual(
            WatchRecordingTranscriptionFailureMessage.recognition(for: error),
            "Transcription failed: The language asset is still downloading. The Watch recording is saved for retry."
        )
    }

    func testAudioPreparationFailureExplainsEmptyAudio() {
        XCTAssertEqual(
            WatchRecordingTranscriptionFailureMessage.audioPreparation(
                for: AudioFileConverter.ConversionError.noAudioSamples
            ),
            "Transcription failed because the Watch recording contains no readable audio. The Watch recording is saved for retry."
        )
    }

    func testAudioPreparationFailureExplainsConversionProblem() {
        XCTAssertEqual(
            WatchRecordingTranscriptionFailureMessage.audioPreparation(
                for: AudioFileConverter.ConversionError.couldNotCreateConverter
            ),
            "Transcription failed because the Watch audio could not be converted to the required format. The Watch recording is saved for retry."
        )
    }
}
