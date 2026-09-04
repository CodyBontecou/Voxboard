import XCTest
import VoxboardShared
@testable import Voxboard

@MainActor
final class RecordingPauseResumeTests: XCTestCase {

    // MARK: - Paused-range extraction

    func testExtractionWithoutPausesMatchesContiguousRead() {
        let buffer = CircularAudioBuffer(capacity: 100)
        appendRamp(to: buffer, from: 1, count: 10)

        let contiguous = buffer.extract(from: 0, to: 10)
        let ranged = PersistentRecorder.extractSegmentSamples(
            from: buffer,
            startIndex: 0,
            endIndex: 10,
            pausedRanges: []
        )
        XCTAssertEqual(contiguous, ranged)
    }

    func testExtractionSkipsPausedRanges() {
        let buffer = CircularAudioBuffer(capacity: 100)
        // 0–9 recorded, 10–19 paused, 20–29 recorded, 30–39 paused, 40–49 recorded.
        appendRamp(to: buffer, from: 1, count: 50)

        let samples = PersistentRecorder.extractSegmentSamples(
            from: buffer,
            startIndex: 0,
            endIndex: 50,
            pausedRanges: [(10, 20), (30, 40)]
        )

        let expected = ([Int](1...10) + [Int](21...30) + [Int](41...50)).map(Float.init)
        XCTAssertEqual(samples, expected)
    }

    func testExtractionWithPreRollStartInsideFirstPausedRange() {
        let buffer = CircularAudioBuffer(capacity: 100)
        appendRamp(to: buffer, from: 1, count: 50)

        // Segment starts mid-pause (pause began before the segment start).
        let samples = PersistentRecorder.extractSegmentSamples(
            from: buffer,
            startIndex: 5,
            endIndex: 50,
            pausedRanges: [(2, 10), (30, 40)]
        )

        let expected = ([Int](11...30) + [Int](41...50)).map(Float.init)
        XCTAssertEqual(samples, expected)
    }

    func testExtractionIncludingOpenPauseTailClosesAtEndIndex() {
        let buffer = CircularAudioBuffer(capacity: 100)
        appendRamp(to: buffer, from: 1, count: 50)

        // Stop while paused: the closed range runs to the extraction end.
        let samples = PersistentRecorder.extractSegmentSamples(
            from: buffer,
            startIndex: 0,
            endIndex: 50,
            pausedRanges: [(20, 50)]
        )

        let expected = [Int](1...20).map(Float.init)
        XCTAssertEqual(samples, expected)
    }

    // MARK: - Live transcription coordinator

    func testLiveCoordinatorPauseSuspendsFeedingAndResumeSkipsPausedAudio() async throws {
        let buffer = CircularAudioBuffer(capacity: 100_000)
        let session = RecordingSystemLiveSession()
        let coordinator = LiveSegmentTranscriptionCoordinator(
            session: session,
            circularBuffer: buffer,
            startIndex: 0,
            sampleRate: 16_000,
            progress: LiveTranscriptionProgress()
        )
        await coordinator.start()

        // First spoken range 0–4_096.
        appendRamp(to: buffer, from: 1, count: 4_096)
        try await waitUntilPausedDrain(of: session, expectedChunks: 1)

        await coordinator.pause()
        // Ambient audio captured while paused.
        appendRamp(to: buffer, from: 100, count: 8_192)
        try await Task.sleep(for: .milliseconds(250))
        let chunkCountWhilePaused = await session.appendChunkCount
        XCTAssertEqual(chunkCountWhilePaused, 1, "paused audio must not be fed to the session")

        await coordinator.resume()
        appendRamp(to: buffer, from: 2, count: 4_096)
        let output = try await coordinator.finish(through: buffer.totalSamplesWritten)
        XCTAssertEqual(output.text, RecordingSystemLiveSession.finishedText)

        let appendedSamples = await session.appendedSampleCount
        // Paused 8_192 samples are skipped; both spoken ranges are fed.
        XCTAssertEqual(appendedSamples, 8_192)
    }

    // MARK: - Voice auto-stop coordinator

    func testAutoStopIgnoresSilenceWhilePaused() async throws {
        let buffer = CircularAudioBuffer(capacity: 100_000)
        let session = PausingVoiceActivitySession(events: [nil])
        var endCount = 0
        let coordinator = VoiceAutoStopCoordinator(
            requestID: "request",
            session: session,
            circularBuffer: buffer,
            startIndex: 0
        ) {
            endCount += 1
        }
        await coordinator.start()

        // Speech starts while recording.
        appendRamp(to: buffer, from: 0, count: 8_192)
        try await waitUntilVoiceStopFrames(of: session, expectedFrames: 2)
        XCTAssertEqual(endCount, 0)

        await coordinator.pause()
        // Long silence while paused must not be consumed as audio.
        appendRamp(to: buffer, from: 0, count: 32_768)
        try await Task.sleep(for: .milliseconds(250))
        let framesWhilePaused = await session.processedFrameCount
        XCTAssertEqual(framesWhilePaused, 2, "paused audio must not reach VAD")

        // Resume appends fresh audio that is processed again.
        await coordinator.resume()
        appendRamp(to: buffer, from: 0, count: 4_096)
        try await waitUntilVoiceStopFrames(of: session, expectedFrames: 3)
        await coordinator.cancel()
        XCTAssertEqual(endCount, 0)
    }

    // MARK: - Watch phase mapping

    func testWatchRecordingPhaseIncludesPaused() {
        XCTAssertEqual(WatchRecordingPhase.paused.rawValue, "paused")
    }

    // MARK: - Helpers

    private func appendRamp(to buffer: CircularAudioBuffer, from start: Int, count: Int) {
        let samples = (start..<(start + count)).map(Float.init)
        buffer.append(samples)
    }

    private func waitUntilPausedDrain(
        of session: RecordingSystemLiveSession,
        expectedChunks: Int
    ) async throws {
        for _ in 0..<50 {
            let count = await session.appendChunkCount
            if count >= expectedChunks { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitUntilVoiceStopFrames(
        of session: PausingVoiceActivitySession,
        expectedFrames: Int
    ) async throws {
        for _ in 0..<50 {
            let count = await session.processedFrameCount
            if count >= expectedFrames { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private actor RecordingSystemLiveSession: SystemLiveTranscriptionSession {
    static let finishedText = "finished"

    private(set) var appendChunkCount = 0
    private(set) var appendedSampleCount = 0

    func append(_ chunk: SystemTranscriptionAudioChunk) async throws {
        appendChunkCount += 1
        appendedSampleCount += chunk.samples.count
    }

    func finish() async throws -> SystemTranscriptionOutput {
        SystemTranscriptionOutput(text: Self.finishedText, language: "en-US")
    }

    func cancel() async {}
}

private actor PausingVoiceActivitySession: VoiceActivityStreamingSession {
    private var events: [VoiceActivityStreamEvent?]
    private(set) var processedFrameCount = 0

    init(events: [VoiceActivityStreamEvent?]) {
        self.events = events
    }

    func process(_ samples: [Float]) async throws -> VoiceActivityStreamEvent? {
        processedFrameCount += 1
        if events.isEmpty { return nil }
        if events.count > 1 { return events.removeFirst() }
        return events[0]
    }
}
