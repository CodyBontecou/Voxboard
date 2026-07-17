import XCTest
@testable import VoxboardCaptureCore

final class CaptureVoiceLifecycleTests: XCTestCase {
    func test_finishRejectsMissingShortOrEmptyAudio() {
        let invalidSamples: [(duration: TimeInterval, exists: Bool, bytes: Int64)] = [
            (0.29, true, 200),
            (1, false, 200),
            (1, true, 0),
        ]

        for sample in invalidSamples {
            var lifecycle = CaptureVoiceLifecycle()
            let generation = lifecycle.beginAttempt()
            XCTAssertTrue(lifecycle.recordingStarted(generation: generation))

            XCTAssertEqual(
                lifecycle.finishRecording(
                    generation: generation,
                    duration: sample.duration,
                    fileExists: sample.exists,
                    fileByteCount: sample.bytes,
                    wantsTranscript: false,
                    modelAvailable: false
                ),
                .rejectAudio
            )
            XCTAssertEqual(lifecycle.phase, .failed(.noUsableAudio))
        }
    }

    func test_finishRoutesUsableAudioToReviewWithoutModel() {
        var lifecycle = CaptureVoiceLifecycle()
        let generation = lifecycle.beginAttempt()
        XCTAssertTrue(lifecycle.recordingStarted(generation: generation))

        let action = lifecycle.finishRecording(
            generation: generation,
            duration: 2,
            fileExists: true,
            fileByteCount: 512,
            wantsTranscript: true,
            modelAvailable: false
        )

        XCTAssertEqual(action, .reviewAudio)
        XCTAssertEqual(lifecycle.phase, .review)
    }

    func test_transcriptionFailureStillLeavesUsableAudioInReview() {
        var lifecycle = CaptureVoiceLifecycle()
        let generation = lifecycle.beginAttempt()
        XCTAssertTrue(lifecycle.recordingStarted(generation: generation))
        XCTAssertEqual(
            lifecycle.finishRecording(
                generation: generation,
                duration: 2,
                fileExists: true,
                fileByteCount: 512,
                wantsTranscript: true,
                modelAvailable: true
            ),
            .transcribeAudio
        )
        XCTAssertEqual(lifecycle.phase, .transcribing)

        XCTAssertTrue(lifecycle.transcriptionFinished(generation: generation))
        XCTAssertEqual(lifecycle.phase, .review)
    }

    func test_backgroundingFinalizesUsableRecordingForReview() {
        var lifecycle = CaptureVoiceLifecycle()
        let generation = lifecycle.beginAttempt()
        XCTAssertTrue(lifecycle.recordingStarted(generation: generation))

        XCTAssertEqual(
            lifecycle.backgrounded(
                generation: generation,
                duration: 1.5,
                fileExists: true,
                fileByteCount: 300
            ),
            .reviewAudio
        )
        XCTAssertEqual(lifecycle.phase, .review)
    }

    func test_backgroundingRejectsUnusableRecording() {
        var lifecycle = CaptureVoiceLifecycle()
        let generation = lifecycle.beginAttempt()
        XCTAssertTrue(lifecycle.recordingStarted(generation: generation))

        XCTAssertEqual(
            lifecycle.backgrounded(
                generation: generation,
                duration: 0.1,
                fileExists: true,
                fileByteCount: 100
            ),
            .rejectAudio
        )
        XCTAssertEqual(lifecycle.phase, .failed(.noUsableAudio))
    }

    func test_cancelInvalidatesLateTranscriptionCompletion() {
        var lifecycle = CaptureVoiceLifecycle()
        let generation = lifecycle.beginAttempt()
        XCTAssertTrue(lifecycle.recordingStarted(generation: generation))
        XCTAssertEqual(
            lifecycle.finishRecording(
                generation: generation,
                duration: 2,
                fileExists: true,
                fileByteCount: 512,
                wantsTranscript: true,
                modelAvailable: true
            ),
            .transcribeAudio
        )

        lifecycle.cancel()

        XCTAssertFalse(lifecycle.transcriptionFinished(generation: generation))
        XCTAssertEqual(lifecycle.phase, .idle)
    }

    func test_microphoneConflictFailsBeforeRecordingAndRetryCanStartFresh() {
        var lifecycle = CaptureVoiceLifecycle()
        let blocked = lifecycle.beginAttempt()

        XCTAssertTrue(lifecycle.fail(generation: blocked, with: .microphoneBusy))
        XCTAssertEqual(lifecycle.phase, .failed(.microphoneBusy))

        let retry = lifecycle.beginAttempt()
        XCTAssertTrue(lifecycle.recordingStarted(generation: retry))
        XCTAssertEqual(lifecycle.phase, .recording)
    }

    func test_retryGenerationIgnoresEventsFromPreviousAttempt() {
        var lifecycle = CaptureVoiceLifecycle()
        let first = lifecycle.beginAttempt()
        XCTAssertTrue(lifecycle.recordingStarted(generation: first))
        let second = lifecycle.beginAttempt()

        XCTAssertFalse(lifecycle.recordingStarted(generation: first))
        XCTAssertTrue(lifecycle.recordingStarted(generation: second))
        XCTAssertEqual(lifecycle.phase, .recording)
    }

    func test_lateEncodingFailureCannotReplaceReviewOrNewerRecordingState() {
        var lifecycle = CaptureVoiceLifecycle()
        let first = lifecycle.beginAttempt()
        XCTAssertTrue(lifecycle.recordingStarted(generation: first))
        XCTAssertEqual(
            lifecycle.finishRecording(
                generation: first,
                duration: 2,
                fileExists: true,
                fileByteCount: 512,
                wantsTranscript: false,
                modelAvailable: false
            ),
            .reviewAudio
        )
        XCTAssertFalse(lifecycle.fail(generation: first, with: .encoding))
        XCTAssertEqual(lifecycle.phase, .review)

        let second = lifecycle.beginAttempt()
        XCTAssertTrue(lifecycle.recordingStarted(generation: second))
        XCTAssertFalse(lifecycle.fail(generation: first, with: .encoding))
        XCTAssertEqual(lifecycle.phase, .recording)
    }

    func test_insertResetsLifecycleAndInvalidatesGeneration() {
        var lifecycle = CaptureVoiceLifecycle()
        let generation = lifecycle.beginAttempt()
        XCTAssertTrue(lifecycle.recordingStarted(generation: generation))
        XCTAssertEqual(
            lifecycle.finishRecording(
                generation: generation,
                duration: 2,
                fileExists: true,
                fileByteCount: 512,
                wantsTranscript: false,
                modelAvailable: false
            ),
            .reviewAudio
        )

        lifecycle.inserted()

        XCTAssertEqual(lifecycle.phase, .idle)
        XCTAssertFalse(lifecycle.fail(generation: generation, with: .encoding))
    }
}
