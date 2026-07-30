import XCTest
import VoxboardShared
@testable import Voxboard

@MainActor
final class VoiceAutoStopCoordinatorTests: XCTestCase {
    func testAccumulatesArbitraryAudioIntoExactVadFrames() async throws {
        let buffer = CircularAudioBuffer(capacity: 20_000)
        let session = FakeVoiceActivitySession(events: [nil])
        var endCount = 0
        let coordinator = VoiceAutoStopCoordinator(
            requestID: "request",
            session: session,
            circularBuffer: buffer,
            startIndex: 0
        ) {
            endCount += 1
        }

        buffer.append([Float](repeating: 0, count: 2_000))
        try await coordinator.processAvailableAudio()
        let partialFrameSizes = await session.receivedFrameSizes()
        XCTAssertEqual(partialFrameSizes, [])

        buffer.append([Float](repeating: 0, count: 2_096))
        try await coordinator.processAvailableAudio()
        let completeFrameSizes = await session.receivedFrameSizes()
        XCTAssertEqual(completeFrameSizes, [4_096])
        XCTAssertEqual(endCount, 0)
    }

    func testInitialSilenceDoesNotStopBeforeSpeech() async throws {
        let buffer = CircularAudioBuffer(capacity: 20_000)
        let session = FakeVoiceActivitySession(events: [
            nil,
            .speechStarted(sampleIndex: 4_096),
            .speechEnded(sampleIndex: 10_000),
        ])
        var endCount = 0
        let coordinator = VoiceAutoStopCoordinator(
            requestID: "request",
            session: session,
            circularBuffer: buffer,
            startIndex: 0
        ) {
            endCount += 1
        }

        buffer.append([Float](repeating: 0, count: 4_096))
        try await coordinator.processAvailableAudio()
        XCTAssertEqual(endCount, 0)

        buffer.append([Float](repeating: 0, count: 8_192))
        try await coordinator.processAvailableAudio()
        XCTAssertEqual(endCount, 1)
    }

    func testShortNoiseCanRearmForLaterValidSpeech() async throws {
        let buffer = CircularAudioBuffer(capacity: 30_000)
        let session = FakeVoiceActivitySession(events: [
            .speechStarted(sampleIndex: 0),
            .speechEnded(sampleIndex: 2_000),
            .speechStarted(sampleIndex: 8_192),
            .speechEnded(sampleIndex: 14_000),
        ])
        var endCount = 0
        let coordinator = VoiceAutoStopCoordinator(
            requestID: "request",
            session: session,
            circularBuffer: buffer,
            startIndex: 0
        ) {
            endCount += 1
        }

        buffer.append([Float](repeating: 0, count: 8_192))
        try await coordinator.processAvailableAudio()
        XCTAssertEqual(endCount, 0)

        buffer.append([Float](repeating: 0, count: 8_192))
        try await coordinator.processAvailableAudio()
        XCTAssertEqual(endCount, 1)
    }

    func testCancellationSuppressesLaterEndEvent() async throws {
        let buffer = CircularAudioBuffer(capacity: 20_000)
        let session = FakeVoiceActivitySession(events: [
            .speechStarted(sampleIndex: 0),
            .speechEnded(sampleIndex: 8_000),
        ])
        var endCount = 0
        let coordinator = VoiceAutoStopCoordinator(
            requestID: "request",
            session: session,
            circularBuffer: buffer,
            startIndex: 0
        ) {
            endCount += 1
        }

        buffer.append([Float](repeating: 0, count: 4_096))
        try await coordinator.processAvailableAudio()
        await coordinator.cancel()
        buffer.append([Float](repeating: 0, count: 4_096))
        try await coordinator.processAvailableAudio()

        XCTAssertEqual(endCount, 0)
    }
}

private actor FakeVoiceActivitySession: VoiceActivityStreamingSession {
    private var events: [VoiceActivityStreamEvent?]
    private var frameSizes: [Int] = []

    init(events: [VoiceActivityStreamEvent?]) {
        self.events = events
    }

    func process(_ samples: [Float]) async throws -> VoiceActivityStreamEvent? {
        frameSizes.append(samples.count)
        guard !events.isEmpty else { return nil }
        return events.removeFirst()
    }

    func receivedFrameSizes() -> [Int] {
        frameSizes
    }
}
