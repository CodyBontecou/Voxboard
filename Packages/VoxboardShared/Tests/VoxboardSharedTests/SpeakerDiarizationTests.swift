import Foundation
import XCTest
@testable import VoxboardShared

private actor FakeOfflineSpeakerDiarizationEngine: OfflineSpeakerDiarizationEngine {
    enum Behavior: Sendable {
        case segments([SpeakerDiarizationSegment])
        case prepareFailure
        case processingFailure
        case cancellation
        case cancellationAsOtherError
        case prepareCancellationAsOtherError
    }

    let behavior: Behavior
    private(set) var prepared = false
    private(set) var processedURLs: [URL] = []

    init(behavior: Behavior) { self.behavior = behavior }

    func prepareModels(directory: URL) async throws {
        switch behavior {
        case .prepareFailure:
            throw NSError(domain: "test", code: 1)
        case .prepareCancellationAsOtherError:
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            }
        default:
            break
        }
        prepared = true
    }

    func process(_ url: URL) async throws -> [SpeakerDiarizationSegment] {
        processedURLs.append(url)
        switch behavior {
        case .segments(let segments): return segments
        case .prepareFailure, .processingFailure, .prepareCancellationAsOtherError:
            throw NSError(domain: "test", code: 2)
        case .cancellation: throw CancellationError()
        case .cancellationAsOtherError:
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            }
            return []
        }
    }
}

private actor BlockingOfflineSpeakerDiarizationEngine: OfflineSpeakerDiarizationEngine {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var processCountWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var processCount = 0

    func prepareModels(directory: URL) async throws {}

    func process(_ url: URL) async throws -> [SpeakerDiarizationSegment] {
        processCount += 1
        let countWaiters = processCountWaiters
        processCountWaiters.removeAll()
        countWaiters.forEach { $0.resume() }
        if !isReleased {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        return [SpeakerDiarizationSegment(speakerID: "a", startTime: 0, endTime: 2)]
    }

    func waitForProcessingToStart() async {
        guard processCount == 0 else { return }
        await withCheckedContinuation { continuation in
            processCountWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class SpeakerDiarizationTests: XCTestCase {
    private func transcription(
        text: String = "Hello there Hi back",
        segments: [TimedTranscriptionSegment]? = nil
    ) -> OnDeviceTranscriptionResult {
        OnDeviceTranscriptionResult(
            text: text,
            backendID: "test",
            backendName: "Test",
            backendKind: .whisper,
            language: "en",
            segments: segments ?? [
                TimedTranscriptionSegment(text: "Hello there", startTime: 0, endTime: 1),
                TimedTranscriptionSegment(text: "Hi back", startTime: 1, endTime: 2),
            ]
        )
    }

    private func service(
        behavior: FakeOfflineSpeakerDiarizationEngine.Behavior
    ) -> (SpeakerDiarizationService, FakeOfflineSpeakerDiarizationEngine) {
        let engine = FakeOfflineSpeakerDiarizationEngine(behavior: behavior)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-tests-\(UUID().uuidString)")
        return (
            SpeakerDiarizationService(
                engine: engine,
                modelsDirectoryProvider: { directory }
            ),
            engine
        )
    }

    private let enabled = RecordingVoiceProcessingConfiguration(
        presetID: "meeting",
        speakerDiarizationEnabled: true
    )

    func testResolverEnabledSuccessProducesSpeakerLabelsAndTurns() async throws {
        let (service, engine) = service(behavior: .segments([
            SpeakerDiarizationSegment(speakerID: "a", startTime: 0, endTime: 1),
            SpeakerDiarizationSegment(speakerID: "b", startTime: 1, endTime: 2),
        ]))

        let resolution = try await service.resolve(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
            transcription: transcription(),
            configuration: enabled
        )

        XCTAssertEqual(resolution.turns?.map(\.speaker), [0, 1])
        XCTAssertTrue(resolution.text.contains("Speaker 1:"))
        XCTAssertNil(resolution.skipReason)
        let prepared = await engine.prepared
        XCTAssertTrue(prepared)
    }

    func testResolverDisabledDoesNotInvokeEngine() async throws {
        let (service, engine) = service(behavior: .processingFailure)
        let input = transcription()
        let resolution = try await service.resolve(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
            transcription: input,
            configuration: RecordingVoiceProcessingConfiguration(
                presetID: "plain",
                speakerDiarizationEnabled: false
            )
        )
        XCTAssertEqual(resolution.text, input.text)
        XCTAssertNil(resolution.skipReason)
        let processedURLs = await engine.processedURLs
        XCTAssertTrue(processedURLs.isEmpty)
    }

    func testResolverReturnsTypedKnownAndUnknownFailuresWithoutLosingText() async throws {
        let input = transcription()
        let (prepareService, _) = service(behavior: .prepareFailure)
        let prepare = try await prepareService.resolve(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
            transcription: input,
            configuration: enabled
        )
        XCTAssertEqual(prepare.text, input.text)
        XCTAssertEqual(prepare.skipReason, .modelPreparationFailed)

        let (processingService, _) = service(behavior: .processingFailure)
        let processing = try await processingService.resolve(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
            transcription: input,
            configuration: enabled
        )
        XCTAssertEqual(processing.text, input.text)
        XCTAssertEqual(processing.skipReason, .processingFailed)
    }

    func testResolverPropagatesCancellation() async {
        let (service, _) = service(behavior: .cancellation)
        do {
            _ = try await service.resolve(
                audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
                transcription: transcription(),
                configuration: enabled
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResolverPropagatesCancellationWhenEngineThrowsDifferentError() async {
        let (service, _) = service(behavior: .cancellationAsOtherError)
        let task = Task {
            try await service.resolve(
                audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
                transcription: transcription(),
                configuration: enabled
            )
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResolverPropagatesCancellationWhenModelPreparationThrowsDifferentError() async {
        let (service, _) = service(behavior: .prepareCancellationAsOtherError)
        let task = Task {
            try await service.resolve(
                audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
                transcription: transcription(),
                configuration: enabled
            )
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testQueuedResolverCancellationDoesNotWaitForActiveProcessing() async throws {
        let engine = BlockingOfflineSpeakerDiarizationEngine()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-tests-\(UUID().uuidString)")
        let service = SpeakerDiarizationService(
            engine: engine,
            modelsDirectoryProvider: { directory }
        )
        let first = Task {
            try await service.resolve(
                audioURL: URL(fileURLWithPath: "/tmp/first.wav"),
                transcription: transcription(),
                configuration: enabled
            )
        }
        await engine.waitForProcessingToStart()
        let processCountAfterFirst = await engine.processCount
        XCTAssertEqual(processCountAfterFirst, 1)

        let second = Task {
            try await service.resolve(
                audioURL: URL(fileURLWithPath: "/tmp/second.wav"),
                transcription: transcription(),
                configuration: enabled
            )
        }
        await Task.yield()
        second.cancel()

        do {
            _ = try await second.value
            XCTFail("Expected queued request cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let processCountAfterCancellation = await engine.processCount
        XCTAssertEqual(processCountAfterCancellation, 1)
        await engine.release()
        _ = try await first.value
    }

    func testResolverReturnsTypedTimestampReasons() async throws {
        let (service, engine) = service(behavior: .segments([]))
        let missing = try await service.resolve(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
            transcription: transcription(segments: []),
            configuration: enabled
        )
        XCTAssertEqual(missing.skipReason, .timestampsUnavailable)

        let incomplete = try await service.resolve(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
            transcription: transcription(
                segments: [TimedTranscriptionSegment(text: "Hello", startTime: 0, endTime: 1)]
            ),
            configuration: enabled
        )
        XCTAssertEqual(incomplete.skipReason, .incompleteTimestamps)
        let processedURLs = await engine.processedURLs
        XCTAssertTrue(processedURLs.isEmpty)
    }

    func testFormerSizeBoundaryForwardsSparseFileURLToDiskBackedAdapter() async throws {
        let (service, engine) = service(behavior: .segments([
            SpeakerDiarizationSegment(speakerID: "a", startTime: 0, endTime: 2),
        ]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-large-\(UUID().uuidString).wav")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 121 * 1024 * 1024)
        try handle.close()

        let resolution = try await service.resolve(
            audioURL: url,
            transcription: transcription(),
            configuration: enabled
        )
        XCTAssertNotNil(resolution.turns)
        let processedURLs = await engine.processedURLs
        XCTAssertEqual(processedURLs, [url])
    }

    func testInvalidTimestampPreservesCompleteRawTranscript() async throws {
        let input = transcription(segments: [
            TimedTranscriptionSegment(text: "Hello there", startTime: 0, endTime: 1),
            TimedTranscriptionSegment(text: "Hi back", startTime: 1, endTime: 1),
        ])
        let (service, engine) = service(behavior: .segments([
            SpeakerDiarizationSegment(speakerID: "a", startTime: 0, endTime: 2),
        ]))

        let resolution = try await service.resolve(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
            transcription: input,
            configuration: enabled
        )

        XCTAssertEqual(resolution.text, input.text)
        XCTAssertNil(resolution.turns)
        XCTAssertEqual(resolution.skipReason, .incompleteTimestamps)
        let processedURLs = await engine.processedURLs
        XCTAssertTrue(processedURLs.isEmpty)
    }

    func testTimestampCoverageRejectsPartialRecognizedText() {
        XCTAssertTrue(SpeakerDiarizationAttribution.hasCompleteTimestampCoverage(
            transcriptText: "Hello, world!",
            transcriptionSegments: [
                TimedTranscriptionSegment(text: "Hello", startTime: 0, endTime: 0.5),
                TimedTranscriptionSegment(text: "world", startTime: 0.5, endTime: 1),
            ]
        ))
        XCTAssertFalse(SpeakerDiarizationAttribution.hasCompleteTimestampCoverage(
            transcriptText: "Hello, missing world!",
            transcriptionSegments: [
                TimedTranscriptionSegment(text: "Hello", startTime: 0, endTime: 0.5),
                TimedTranscriptionSegment(text: "world", startTime: 0.5, endTime: 1),
            ]
        ))
    }

    func testAttributionUsesOverlapAndGroupsContiguousTurns() {
        let words = [
            TimedTranscriptionSegment(text: "Hello", startTime: 0.1, endTime: 0.5),
            TimedTranscriptionSegment(text: "there", startTime: 0.5, endTime: 0.9),
            TimedTranscriptionSegment(text: "Hi", startTime: 1.2, endTime: 1.5),
            TimedTranscriptionSegment(text: "back.", startTime: 1.5, endTime: 1.9),
        ]
        let speakers = [
            SpeakerDiarizationSegment(speakerID: "voice-a", startTime: 0, endTime: 1),
            SpeakerDiarizationSegment(speakerID: "voice-b", startTime: 1.1, endTime: 2),
        ]
        let turns = SpeakerDiarizationAttribution.turns(
            transcriptionSegments: words,
            speakerSegments: speakers
        )
        XCTAssertEqual(turns.map(\.speaker), [0, 1])
        XCTAssertEqual(turns.map(\.text), ["Hello there", "Hi back."])
        XCTAssertEqual(SpeakerDiarizationOutput(turns: turns).renderedText, """
        Speaker 1:
        Hello there

        Speaker 2:
        Hi back.
        """)
    }

    func testAttributionUsesNearestSpeakerWhenAWordFallsInAGap() {
        let turns = SpeakerDiarizationAttribution.turns(
            transcriptionSegments: [
                TimedTranscriptionSegment(text: "first", startTime: 0.4, endTime: 0.7),
                TimedTranscriptionSegment(text: "near second", startTime: 2.7, endTime: 2.9),
            ],
            speakerSegments: [
                SpeakerDiarizationSegment(speakerID: "first", startTime: 0, endTime: 1),
                SpeakerDiarizationSegment(speakerID: "second", startTime: 3, endTime: 4),
            ]
        )
        XCTAssertEqual(turns.map(\.speaker), [0, 1])
        XCTAssertEqual(turns.map(\.text), ["first", "near second"])
    }

    func testTranscriptPreservesDiarizationMetadataThroughEnrichmentAndClearsItAfterRawEdit() throws {
        let turns = [TranscriptSpeakerTurn(speaker: 0, text: "Hello", startTime: 0, endTime: 1)]
        let transcript = Transcript(
            id: UUID(),
            text: "Speaker 1:\nHello",
            date: Date(),
            duration: 1,
            modelUsed: "Test",
            language: "en",
            speakerTurns: turns,
            speakerDiarizationSkipReason: .processingFailed
        )
        let enriched = transcript.withEnrichment(
            title: "Greeting", tags: nil, category: nil, cleanedText: transcript.text
        )
        XCTAssertEqual(enriched.speakerTurns, turns)
        XCTAssertEqual(enriched.speakerDiarizationSkipReason, .processingFailed)
        let unchanged = transcript.withEdits(
            text: transcript.text, title: nil, tags: nil, category: nil, cleanedText: nil
        )
        XCTAssertEqual(unchanged.speakerDiarizationSkipReason, .processingFailed)
        let edited = transcript.withEdits(
            text: "Edited", title: nil, tags: nil, category: nil, cleanedText: nil
        )
        XCTAssertNil(edited.speakerTurns)
        XCTAssertNil(edited.speakerDiarizationSkipReason)

        let encoded = try JSONEncoder().encode(transcript)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "speakerTurns")
        object.removeValue(forKey: "speakerDiarizationSkipReason")
        let legacy = try JSONDecoder().decode(
            Transcript.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.speakerTurns)
        XCTAssertNil(legacy.speakerDiarizationSkipReason)
    }
}
