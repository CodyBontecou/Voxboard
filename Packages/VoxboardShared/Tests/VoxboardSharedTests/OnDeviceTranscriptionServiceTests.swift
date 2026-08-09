import Foundation
import XCTest
@testable import VoxboardShared

final class OnDeviceTranscriptionServiceTests: XCTestCase {
    func testAutomaticUsesAvailableSystemBackendAndReportsActualBackend() async throws {
        let timedSegment = TimedTranscriptionSegment(
            text: "Native transcript",
            startTime: 0,
            endTime: 1
        )
        let backend = FakeSystemTranscriptionBackend(
            availability: .ready,
            result: .success(SystemTranscriptionOutput(
                text: "Native transcript",
                language: "en-US",
                segments: [timedSegment]
            ))
        )
        let service = OnDeviceTranscriptionService(
            systemBackend: backend,
            usesDownloadedLocalFallbacks: false
        )

        let result = try await service.transcribeResult(
            audioURL: URL(fileURLWithPath: "/tmp/ignored.wav"),
            modelID: TranscriptionBackendID.automatic,
            language: "auto"
        )

        XCTAssertEqual(result.text, "Native transcript")
        XCTAssertEqual(result.backendID, TranscriptionBackendID.appleSpeech)
        XCTAssertEqual(result.backendName, "Apple Speech")
        XCTAssertEqual(result.backendKind, .appleSpeech)
        XCTAssertEqual(result.language, "en-US")
        XCTAssertEqual(result.segments, [timedSegment])
        let callCount = await backend.transcriptionCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testSystemBackendReportsActiveButNeverFabricatesExactProgress() async throws {
        let backend = FakeSystemTranscriptionBackend(
            availability: .ready,
            result: .success(SystemTranscriptionOutput(text: "Native", language: "en-US"))
        )
        let service = OnDeviceTranscriptionService(
            systemBackend: backend,
            usesDownloadedLocalFallbacks: false
        )
        let progress = LockedProgressRecorder()

        _ = try await service.transcribeResult(
            audioURL: URL(fileURLWithPath: "/tmp/ignored.wav"),
            modelID: TranscriptionBackendID.automatic,
            onProgress: { progress.append($0) }
        )

        XCTAssertEqual(progress.values, [.preparing])
        XCTAssertTrue(progress.values.allSatisfy { $0.exactFractionCompleted == nil })
    }

    func testSupportedButUninstalledSystemAssetIsNotReportedReady() async {
        let backend = FakeSystemTranscriptionBackend(
            availability: .supported,
            result: .failure(FakeError.failed)
        )
        let service = OnDeviceTranscriptionService(
            systemBackend: backend,
            usesDownloadedLocalFallbacks: false
        )

        let ready = await service.canTranscribe(
            modelID: TranscriptionBackendID.automatic,
            language: "en"
        )

        XCTAssertFalse(ready)
    }

    func testPrepareSurfacesSystemAssetFailureWhenNoFallbackExists() async {
        let backend = FakeSystemTranscriptionBackend(
            availability: .supported,
            result: .failure(FakeError.failed),
            preparationFails: true
        )
        let service = OnDeviceTranscriptionService(
            systemBackend: backend,
            usesDownloadedLocalFallbacks: false
        )

        do {
            try await service.prepare(
                modelID: TranscriptionBackendID.automatic,
                language: "en-US"
            )
            XCTFail("Expected systemBackendFailed")
        } catch {
            XCTAssertEqual(
                error as? OnDeviceTranscriptionError,
                .systemBackendFailed("The Apple Speech asset operation failed.")
            )
        }
    }

    func testTranscriptionSurfacesSystemFailureWhenNoFallbackExists() async {
        let backend = FakeSystemTranscriptionBackend(
            availability: .ready,
            result: .failure(FakeError.failed)
        )
        let service = OnDeviceTranscriptionService(
            systemBackend: backend,
            usesDownloadedLocalFallbacks: false
        )

        do {
            _ = try await service.transcribeResult(
                audioURL: URL(fileURLWithPath: "/tmp/ignored.wav"),
                modelID: TranscriptionBackendID.automatic
            )
            XCTFail("Expected systemBackendFailed")
        } catch {
            XCTAssertEqual(
                error as? OnDeviceTranscriptionError,
                .systemBackendFailed("The Apple Speech asset operation failed.")
            )
        }
    }

    func testAutomaticWithoutSystemOrDownloadedFallbackIsActionable() async {
        let backend = FakeSystemTranscriptionBackend(
            availability: .unavailable,
            result: .failure(FakeError.failed)
        )
        let service = OnDeviceTranscriptionService(
            systemBackend: backend,
            usesDownloadedLocalFallbacks: false
        )

        do {
            _ = try await service.transcribeResult(
                audioURL: URL(fileURLWithPath: "/tmp/ignored.wav"),
                modelID: TranscriptionBackendID.automatic
            )
            XCTFail("Expected noAvailableBackend")
        } catch {
            XCTAssertEqual(error as? OnDeviceTranscriptionError, .noAvailableBackend)
        }
        let callCount = await backend.transcriptionCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testNoSpeechDoesNotRetryAnotherBackend() async {
        let backend = FakeSystemTranscriptionBackend(
            availability: .ready,
            result: .failure(OnDeviceTranscriptionError.noSpeechDetected)
        )
        let service = OnDeviceTranscriptionService(
            systemBackend: backend,
            usesDownloadedLocalFallbacks: false
        )

        do {
            _ = try await service.transcribeResult(
                audioURL: URL(fileURLWithPath: "/tmp/ignored.wav"),
                modelID: TranscriptionBackendID.automatic
            )
            XCTFail("Expected noSpeechDetected")
        } catch {
            XCTAssertEqual(error as? OnDeviceTranscriptionError, .noSpeechDetected)
        }
        let callCount = await backend.transcriptionCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testLiveTranscriptionStartsForReadyAutomaticAppleSpeech() async throws {
        let backend = FakeSystemTranscriptionBackend(
            availability: .ready,
            result: .success(SystemTranscriptionOutput(text: "Batch", language: "en-US"))
        )
        let service = OnDeviceTranscriptionService(
            systemBackend: backend,
            usesDownloadedLocalFallbacks: false
        )

        let session = try await service.startLiveTranscription(
            modelID: TranscriptionBackendID.automatic,
            language: "en-US",
            onUpdate: { _ in }
        )

        XCTAssertNotNil(session)
        let liveCallCount = await backend.liveTranscriptionCallCount
        XCTAssertEqual(liveCallCount, 1)
    }

    func testLiveTranscriptionAttemptsBackendWhenReadOnlyAvailabilityIsUnavailable() async throws {
        let backend = FakeSystemTranscriptionBackend(
            availability: .unavailable,
            result: .success(SystemTranscriptionOutput(text: "Batch", language: "en-US"))
        )
        let service = OnDeviceTranscriptionService(
            systemBackend: backend,
            usesDownloadedLocalFallbacks: false
        )

        let session = try await service.startLiveTranscription(
            modelID: TranscriptionBackendID.automatic,
            language: "auto",
            onUpdate: { _ in }
        )

        XCTAssertNotNil(session)
        let liveCallCount = await backend.liveTranscriptionCallCount
        XCTAssertEqual(liveCallCount, 1)
    }

    func testLiveTranscriptionDoesNotStartForExplicitLocalModel() async throws {
        let backend = FakeSystemTranscriptionBackend(
            availability: .ready,
            result: .success(SystemTranscriptionOutput(text: "Batch", language: "en-US"))
        )
        let service = OnDeviceTranscriptionService(
            systemBackend: backend,
            usesDownloadedLocalFallbacks: false
        )

        let session = try await service.startLiveTranscription(
            modelID: "whisper-base",
            onUpdate: { _ in }
        )

        XCTAssertNil(session)
        let liveCallCount = await backend.liveTranscriptionCallCount
        XCTAssertEqual(liveCallCount, 0)
    }

    func testLiveTranscriptionStartsWhenSystemAssetCanBeInstalled() async throws {
        let backend = FakeSystemTranscriptionBackend(
            availability: .supported,
            result: .success(SystemTranscriptionOutput(text: "Batch", language: "en-US"))
        )
        let service = OnDeviceTranscriptionService(
            systemBackend: backend,
            usesDownloadedLocalFallbacks: false
        )

        let session = try await service.startLiveTranscription(
            modelID: TranscriptionBackendID.automatic,
            onUpdate: { _ in }
        )

        XCTAssertNotNil(session)
        let liveCallCount = await backend.liveTranscriptionCallCount
        XCTAssertEqual(liveCallCount, 1)
    }

    func testExplicitMissingLocalModelBypassesSystemBackend() async {
        let backend = FakeSystemTranscriptionBackend(
            availability: .ready,
            result: .success(SystemTranscriptionOutput(text: "Should not run", language: "en-US"))
        )
        let service = OnDeviceTranscriptionService(
            systemBackend: backend,
            usesDownloadedLocalFallbacks: false
        )

        do {
            _ = try await service.transcribeResult(
                audioURL: URL(fileURLWithPath: "/tmp/ignored.wav"),
                modelID: "missing-local-model"
            )
            XCTFail("Expected modelUnavailable")
        } catch {
            XCTAssertEqual(error as? OnDeviceTranscriptionError, .modelUnavailable)
        }
        let callCount = await backend.transcriptionCallCount
        XCTAssertEqual(callCount, 0)
    }
}

private final class LockedProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TranscriptionProgress] = []

    var values: [TranscriptionProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ progress: TranscriptionProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }
}

private enum FakeError: Error, LocalizedError, Sendable {
    case failed

    var errorDescription: String? {
        "The Apple Speech asset operation failed."
    }
}

private actor FakeSystemTranscriptionBackend: SystemTranscriptionBackend {
    let configuredAvailability: SystemTranscriptionAvailability
    let result: Result<SystemTranscriptionOutput, Error>
    let preparationFails: Bool
    private(set) var transcriptionCallCount = 0
    private(set) var liveTranscriptionCallCount = 0

    init(
        availability: SystemTranscriptionAvailability,
        result: Result<SystemTranscriptionOutput, Error>,
        preparationFails: Bool = false
    ) {
        self.configuredAvailability = availability
        self.result = result
        self.preparationFails = preparationFails
    }

    func availability(language: String) async -> SystemTranscriptionAvailability {
        configuredAvailability
    }

    func prepare(language: String) async throws {
        if preparationFails { throw FakeError.failed }
    }

    func transcribe(audioURL: URL, language: String) async throws -> SystemTranscriptionOutput {
        transcriptionCallCount += 1
        return try result.get()
    }

    func startLiveTranscription(
        language: String,
        onUpdate: @escaping @concurrent @Sendable (SystemTranscriptionUpdate) async -> Void
    ) async throws -> any SystemLiveTranscriptionSession {
        liveTranscriptionCallCount += 1
        return FakeLiveTranscriptionSession()
    }
}

private actor FakeLiveTranscriptionSession: SystemLiveTranscriptionSession {
    func append(_ chunk: SystemTranscriptionAudioChunk) async throws {}

    func finish() async throws -> SystemTranscriptionOutput {
        SystemTranscriptionOutput(text: "Live", language: "en-US")
    }

    func cancel() async {}
}
