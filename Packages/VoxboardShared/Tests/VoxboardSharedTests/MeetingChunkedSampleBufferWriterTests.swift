import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import VoxboardShared

/// Direct tests for the queue-confined chunked writer's rollover/drain/stop
/// interleavings, driven through the `MeetingChunkAssetWriting` seam with
/// deferred-completion fakes so every race is deterministically ordered by
/// the test instead of by AVFoundation timing.
final class MeetingChunkedSampleBufferWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingChunkWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fakes

    private final class FakeChunkSession: MeetingChunkAssetWriting, @unchecked Sendable {
        let url: URL
        let lock = NSLock()
        private(set) var appendCount = 0
        private(set) var markAsFinishedCount = 0
        private var finishCompletions: [@Sendable () -> Void] = []
        var appendOutcome: MeetingChunkAppendOutcome = .appended
        var injectedError: Error?
        var completedSuccessfully = true

        var error: Error? { lock.withLock { injectedError } }
        var isReadyForMoreMediaData: Bool { true }

        init(url: URL) { self.url = url }

        func append(_ buffer: CMSampleBuffer) -> MeetingChunkAppendOutcome {
            lock.withLock {
                appendCount += 1
                return appendOutcome
            }
        }

        func markAsFinished() {
            lock.withLock { markAsFinishedCount += 1 }
        }

        func finishWriting(_ completion: @escaping @Sendable () -> Void) {
            lock.withLock { finishCompletions.append(completion) }
        }

        /// Simulates AVAssetWriter completing the chunk: writes real bytes at
        /// the chunk URL (so the writer's size verification succeeds) and then
        /// fires the deferred completion.
        func complete(fileSize: Int) {
            try? Data(repeating: 0xAB, count: fileSize).write(to: url)
            let completions = lock.withLock {
                let values = finishCompletions
                finishCompletions.removeAll()
                return values
            }
            for completion in completions { completion() }
        }

        var recordedAppendCount: Int { lock.withLock { appendCount } }
        var recordedMarkAsFinishedCount: Int { lock.withLock { markAsFinishedCount } }
    }

    private final class RecordingFinalized: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [MeetingWriterFinalizationResult] = []
        var count: Int { lock.withLock { results.count } }
        var all: [MeetingWriterFinalizationResult] { lock.withLock { results } }
        func record(_ chunk: MeetingCaptureChunk, _ events: [MeetingTimelineEvent], _ warnings: [String]) {
            lock.withLock { results.append(.init(chunk: chunk, events: events, warnings: warnings)) }
        }
    }

    /// Lock-guarded box so `@Sendable` stop completions can deliver their
    /// result back to the test without Swift-6 capture diagnostics.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: MeetingWriterFinalizationResult?
        var value: MeetingWriterFinalizationResult? { lock.withLock { stored } }
        func store(_ result: MeetingWriterFinalizationResult?) { lock.withLock { stored = result } }
    }

    private final class SessionLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var sessions: [FakeChunkSession] = []
        var failNextCreation = false

        func factory(url: URL, format: CMFormatDescription?, startTime: CMTime) throws -> any MeetingChunkAssetWriting {
            if failNextCreation {
                failNextCreation = false
                throw NSError(domain: "VoxMeetingWriterTests", code: 99)
            }
            let session = FakeChunkSession(url: url)
            lock.withLock { sessions.append(session) }
            return session
        }

        var recordedSessions: [FakeChunkSession] { lock.withLock { sessions } }
    }

    // MARK: - Sample buffer construction

    /// Pointers handed to CMBlockBuffer are intentionally never deallocated:
    /// nothing in these tests reads audio bytes after creation, and keeping
    /// the allocation alive forever is safer than freeing memory a retained
    /// sample buffer may still reference. The leak is a few KB per test run.
    private var keepAlive: [UnsafeMutableRawPointer] = []

    private func makeBuffer(rate: Double, samples: Int = 4_800, ptsSeconds: Double) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var optionalFormat: CMFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &optionalFormat
        )
        let format = try XCTUnwrap(optionalFormat)
        let byteCount = samples * 2
        let memory = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        memset(memory, 0, byteCount)
        keepAlive.append(memory)
        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: memory,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            kCMBlockBufferNoErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(samples), timescale: CMTimeScale(rate)),
            presentationTimeStamp: CMTime(seconds: ptsSeconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sampleSize = 2
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: try XCTUnwrap(blockBuffer),
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: format,
                sampleCount: CMItemCount(samples),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }

    private let timelineOrigin = CMTime(seconds: 100, preferredTimescale: 600)

    /// Bundles the writer under test with its fakes and the callback queue it
    /// serializes on, so tests can join pending queue hops before asserting.
    private final class WriterFixture: @unchecked Sendable {
        let sessions = SessionLog()
        let finalized = RecordingFinalized()
        let queue: DispatchQueue
        let writer: ChunkedSampleBufferWriter

        init(directory: URL, timelineOrigin: CMTime) {
            queue = DispatchQueue(label: "VoxMeetingTests.writer")
            writer = ChunkedSampleBufferWriter(
                source: .system,
                directoryURL: directory,
                callbackQueue: queue,
                timelineOrigin: { timelineOrigin },
                finalized: { [finalized] chunk, events, warnings in
                    finalized.record(chunk, events, warnings)
                },
                assetWriterFactory: { [sessions] url, format, startTime in
                    try sessions.factory(url: url, format: format, startTime: startTime)
                }
            )
        }

        /// Runs `callback` once the writer's queue has drained every hop that
        /// pending fake completions enqueued, making assertions deterministic.
        func afterPendingHops(
            _ file: StaticString = #filePath,
            line: UInt = #line,
            _ callback: () -> Void
        ) {
            let done = DispatchSemaphore(value: 0)
            queue.async { done.signal() }
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "writer callback queue stalled", file: file, line: line)
            callback()
        }
    }

    private func makeFixture() -> WriterFixture {
        WriterFixture(directory: directory, timelineOrigin: timelineOrigin)
    }

    // MARK: - Stop during rotation

    func testStopDuringRotationDrainsBufferedAudioAndCompletesStop() throws {
        let fixture = makeFixture()
        let writer = fixture.writer
        let sessions = fixture.sessions
        let finalized = fixture.finalized

        // Chunk 1 opens with 48 kHz; a 44.1 kHz buffer forces a rotation and
        // buffers itself while chunk 1 is still finalizing.
        try writer.append(makeBuffer(rate: 48_000, ptsSeconds: 100.1))
        try writer.append(makeBuffer(rate: 44_100, ptsSeconds: 100.3))

        // Stop races the in-flight rotation: it must wait, not drop audio.
        let stopDone = expectation(description: "stop completion")
        let stopResult = ResultBox()
        writer.finish { result in
            stopResult.store(result)
            stopDone.fulfill()
        }

        sessions.recordedSessions[0].complete(fileSize: 120)
        fixture.afterPendingHops {
            XCTAssertEqual(sessions.recordedSessions.count, 2, "buffered audio must open a second chunk after the rotation settles")
        }
        sessions.recordedSessions[1].complete(fileSize: 240)

        wait(for: [stopDone], timeout: 5)
        let result = try XCTUnwrap(stopResult.value)
        XCTAssertEqual(result.chunk.byteCount, 240, "stop reports the drained chunk")
        XCTAssertTrue(result.chunk.filename.hasSuffix("-0001.m4a"))
        XCTAssertEqual(finalized.count, 1, "chunk 1 publishes while rotating; the drained chunk is delivered via stop only")
        XCTAssertEqual(finalized.all[0].chunk.byteCount, 120)
        XCTAssertEqual(sessions.recordedSessions[0].recordedAppendCount, 1)
        XCTAssertEqual(sessions.recordedSessions[1].recordedAppendCount, 1)

        // Both chunks leave durable recovery receipts.
        for filename in [finalized.all[0].chunk.filename, result.chunk.filename] {
            let receiptURL = directory.appendingPathComponent(filename).appendingPathExtension("chunk.json")
            let receipt = try JSONDecoder().decode(MeetingCaptureChunkReceipt.self, from: Data(contentsOf: receiptURL))
            XCTAssertEqual(receipt.chunk.filename, filename)
            XCTAssertGreaterThan(receipt.chunk.byteCount, 0)
        }
    }

    // MARK: - Drain while rollover buffering

    func testRolloverBoundDropsOverflowAndRecordsTimelineEvent() throws {
        let fixture = makeFixture()
        let writer = fixture.writer
        let sessions = fixture.sessions

        try writer.append(makeBuffer(rate: 48_000, ptsSeconds: 100.1))
        // 513 differing-format buffers: 512 fill the bounded rollover, the
        // 513th is dropped with accounting.
        for index in 0..<513 {
            try writer.append(makeBuffer(rate: 44_100, samples: 480, ptsSeconds: 100.3 + Double(index) * 0.01))
        }

        sessions.recordedSessions[0].complete(fileSize: 80)

        // Rotation drains into a fresh chunk and ends accepting again.
        fixture.afterPendingHops {
            XCTAssertEqual(sessions.recordedSessions.count, 2)
            XCTAssertEqual(sessions.recordedSessions[1].recordedAppendCount, 512, "all 512 buffered buffers drain into the next chunk")
        }

        let stopDone = expectation(description: "stop completion")
        let stopResult = ResultBox()
        writer.finish { result in
            stopResult.store(result)
            stopDone.fulfill()
        }
        sessions.recordedSessions[1].complete(fileSize: 400)
        wait(for: [stopDone], timeout: 5)

        let result = try XCTUnwrap(stopResult.value)
        XCTAssertTrue(
            result.warnings.contains { $0.contains("exceeded the bounded rollover buffer") },
            "overflow must surface a warning: \(result.warnings)"
        )
        XCTAssertTrue(
            result.events.contains { $0.kind == .dropped && ($0.duration ?? 0) > 0 },
            "overflow must surface a dropped timeline event"
        )
    }

    // MARK: - Plain stop finalizes exactly the open chunk

    func testStopWithoutRotationFinalizesCurrentChunkOnce() throws {
        let fixture = makeFixture()
        let writer = fixture.writer
        let sessions = fixture.sessions
        let finalized = fixture.finalized

        try writer.append(makeBuffer(rate: 48_000, ptsSeconds: 100.1))
        try writer.append(makeBuffer(rate: 48_000, ptsSeconds: 100.3))

        let stopDone = expectation(description: "stop completion")
        let stopResult = ResultBox()
        writer.finish { result in
            stopResult.store(result)
            stopDone.fulfill()
        }
        XCTAssertEqual(sessions.recordedSessions.count, 1)
        sessions.recordedSessions[0].complete(fileSize: 90)
        wait(for: [stopDone], timeout: 5)

        let result = try XCTUnwrap(stopResult.value)
        XCTAssertEqual(result.chunk.byteCount, 90)
        XCTAssertEqual(result.chunk.filename, sessions.recordedSessions[0].url.lastPathComponent)
        XCTAssertEqual(sessions.recordedSessions[0].recordedMarkAsFinishedCount, 1)
        XCTAssertEqual(finalized.count, 0, "the stop path owns delivery; no duplicate publish")

        // Buffers arriving after stop are discarded without side effects.
        XCTAssertNoThrow(try writer.append(makeBuffer(rate: 48_000, ptsSeconds: 101)))
        XCTAssertEqual(sessions.recordedSessions.count, 1)
    }

    // MARK: - Writer failure propagation

    func testAppendFailurePropagatesToCaller() throws {
        let fixture = makeFixture()
        let writer = fixture.writer
        let sessions = fixture.sessions

        try writer.append(makeBuffer(rate: 48_000, ptsSeconds: 100.1))
        sessions.recordedSessions[0].appendOutcome = .failed
        sessions.recordedSessions[0].injectedError = NSError(domain: "VoxMeetingWriterTests", code: 7)

        XCTAssertThrowsError(try writer.append(makeBuffer(rate: 48_000, ptsSeconds: 100.3))) { error in
            XCTAssertEqual((error as NSError).code, 7, "the session's underlying error must surface")
        }
    }

    func testDrainFailureWhileStoppingCompletesWithFailedResult() throws {
        let fixture = makeFixture()
        let writer = fixture.writer
        let sessions = fixture.sessions

        try writer.append(makeBuffer(rate: 48_000, ptsSeconds: 100.1))
        try writer.append(makeBuffer(rate: 44_100, ptsSeconds: 100.3))

        let stopDone = expectation(description: "stop completion")
        let stopResult = ResultBox()
        writer.finish { result in
            stopResult.store(result)
            stopDone.fulfill()
        }

        // The drained chunk cannot even be opened; stop must still complete
        // (never hang) and surface the failure.
        sessions.failNextCreation = true
        sessions.recordedSessions[0].complete(fileSize: 64)
        wait(for: [stopDone], timeout: 5)

        let result = try XCTUnwrap(stopResult.value)
        XCTAssertEqual(result.chunk.byteCount, 0)
        XCTAssertTrue(
            result.warnings.contains { $0.contains("could not start its next chunk") },
            "drain failure must surface a warning: \(result.warnings)"
        )
        XCTAssertEqual(sessions.recordedSessions.count, 1)
    }

    // MARK: - Chunk-duration rotation with consistent format

    func testChunkDurationRotationDrainsIntoNextChunk() throws {
        let fixture = makeFixture()
        let writer = fixture.writer
        let sessions = fixture.sessions
        let finalized = fixture.finalized

        try writer.append(makeBuffer(rate: 48_000, ptsSeconds: 100.1))
        // Same format, 31 s later: crosses the 30 s chunk duration boundary.
        try writer.append(makeBuffer(rate: 48_000, ptsSeconds: 131.2))

        XCTAssertEqual(sessions.recordedSessions.count, 1)
        sessions.recordedSessions[0].complete(fileSize: 70)
        fixture.afterPendingHops {
            XCTAssertEqual(sessions.recordedSessions.count, 2, "the rotated buffer opens the next chunk")
            XCTAssertEqual(sessions.recordedSessions[1].recordedAppendCount, 1)
        }

        let stopDone = expectation(description: "stop completion")
        writer.finish { _ in stopDone.fulfill() }
        sessions.recordedSessions[1].complete(fileSize: 50)
        wait(for: [stopDone], timeout: 5)
        XCTAssertEqual(finalized.count, 1, "the first chunk published during rotation")
    }

    // MARK: - Finalization mailbox dedup

    func testFinalizationMailboxSuppressesDuplicateTakesAndDrainsUndelivered() {
        let mailbox = MeetingWriterFinalizationMailbox()
        let chunk = MeetingCaptureChunk(source: .system, filename: "a.m4a", startTime: 0, endTime: 1, byteCount: 10)
        let first = MeetingWriterFinalizationResult(chunk: chunk, events: [], warnings: [])
        let second = MeetingWriterFinalizationResult(
            chunk: MeetingCaptureChunk(source: .microphone, filename: "b.m4a", startTime: 0, endTime: 1, byteCount: 20),
            events: [],
            warnings: []
        )

        let firstID = mailbox.enqueue(first)
        _ = mailbox.enqueue(second)

        XCTAssertEqual(mailbox.take(firstID)?.chunk.filename, "a.m4a")
        XCTAssertNil(mailbox.take(firstID), "a duplicate take must not deliver the same chunk twice")
        XCTAssertNil(mailbox.take(UUID()), "unknown identifiers deliver nothing")

        let drained = mailbox.drain()
        XCTAssertEqual(drained.map(\.chunk.filename), ["b.m4a"], "undelivered entries survive until stop drains them")
        XCTAssertTrue(mailbox.drain().isEmpty, "drain clears the mailbox")

        mailbox.reset()
        let id = mailbox.enqueue(first)
        mailbox.reset()
        XCTAssertNil(mailbox.take(id), "reset clears entries even with live identifiers")
    }
}
