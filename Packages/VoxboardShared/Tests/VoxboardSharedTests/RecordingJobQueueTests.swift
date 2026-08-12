import Foundation
import XCTest
@testable import VoxboardShared

@MainActor
final class RecordingJobQueueTests: XCTestCase {
    func test_queueSerializesMultipleImmediateJobs() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let probe = QueueExecutionProbe()
        let queue = RecordingJobQueue(store: fixture.store) { job, _, _ in
            await probe.begin(job.id)
            try await Task.sleep(for: .milliseconds(30))
            await probe.end(job.id)
            return RecordingJobExecutionResult()
        }
        queue.setCaptureActive(true)

        _ = try await fixture.enqueue(on: queue, policy: .immediate)
        _ = try await fixture.enqueue(on: queue, policy: .immediate)
        queue.setCaptureActive(false)

        try await waitUntil {
            let jobs = try await fixture.store.load(recoverInterrupted: false)
            return jobs.count == 2 && jobs.allSatisfy { $0.phase == .completed }
        }
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.started.count, 2)
        XCTAssertEqual(snapshot.maximumConcurrentExecutions, 1)
    }

    func test_enqueueRemainsAvailableWhileEarlierJobProcesses() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let firstStarted = expectation(description: "first executor started")
        let release = AsyncReleaseGate()
        let probe = QueueExecutionProbe()
        let queue = RecordingJobQueue(store: fixture.store) { job, _, _ in
            await probe.begin(job.id)
            let snapshot = await probe.snapshot()
            if snapshot.started.count == 1 {
                firstStarted.fulfill()
            }
            await release.wait()
            await probe.end(job.id)
            return RecordingJobExecutionResult()
        }

        let first = try await fixture.enqueue(on: queue, policy: .immediate)
        await fulfillment(of: [firstStarted], timeout: 2)

        let clock = ContinuousClock()
        let enqueueStartedAt = clock.now
        let second = try await fixture.enqueue(on: queue, policy: .immediate)
        XCTAssertLessThan(enqueueStartedAt.duration(to: clock.now), .seconds(1))
        let firstPhase = try await fixture.store.job(id: first.id)?.phase
        let secondPhase = try await fixture.store.job(id: second.id)?.phase
        XCTAssertEqual(firstPhase, .processing)
        XCTAssertEqual(secondPhase, .queued)

        await release.open()
        try await waitUntil {
            let jobs = try await fixture.store.load(recoverInterrupted: false)
            return jobs.count == 2 && jobs.allSatisfy { $0.phase == .completed }
        }
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.started, [first.id, second.id])
        XCTAssertEqual(snapshot.maximumConcurrentExecutions, 1)
    }

    func test_manualJobDoesNotRunUntilProcessNow() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let probe = QueueExecutionProbe()
        let queue = RecordingJobQueue(store: fixture.store) { job, _, _ in
            await probe.begin(job.id)
            await probe.end(job.id)
            return RecordingJobExecutionResult()
        }

        let job = try await fixture.enqueue(on: queue, policy: .manual)
        try await Task.sleep(for: .milliseconds(50))
        let beforeStart = await probe.snapshot()
        XCTAssertEqual(beforeStart.started, [])

        await queue.processNow(job)
        try await waitUntil {
            try await fixture.store.job(id: job.id)?.phase == .completed
        }
        let afterCompletion = await probe.snapshot()
        XCTAssertEqual(afterCompletion.started, [job.id])
    }

    func test_executorFailureLeavesAudioAndRetryableJob() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        struct ExpectedFailure: LocalizedError {
            var errorDescription: String? { "Expected transcription failure" }
        }
        let queue = RecordingJobQueue(store: fixture.store) { _, _, _ in
            throw ExpectedFailure()
        }

        let job = try await fixture.enqueue(on: queue, policy: .immediate)
        try await waitUntil {
            try await fixture.store.job(id: job.id)?.phase == .failed
        }
        let persistedFailed = try await fixture.store.job(id: job.id)
        let failed = try XCTUnwrap(persistedFailed)

        XCTAssertEqual(failed.failureStage, .transcription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: failed).path))
    }

    func test_interactiveInterruptionReturnsActiveJobToQueue() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let started = expectation(description: "executor started")
        let queue = RecordingJobQueue(store: fixture.store) { _, _, _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(30))
            return RecordingJobExecutionResult()
        }

        let job = try await fixture.enqueue(on: queue, policy: .immediate)
        await fulfillment(of: [started], timeout: 2)
        queue.interruptForInteractiveWork()

        try await waitUntil {
            try await fixture.store.job(id: job.id)?.phase == .queued
        }
        let persisted = try await fixture.store.job(id: job.id)
        XCTAssertEqual(persisted?.statusMessage, "Paused for interactive transcription")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: job).path))
    }

    func test_systemExpirationReturnsActiveJobToQueueWithAccurateStatus() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let started = expectation(description: "executor started")
        let queue = RecordingJobQueue(store: fixture.store) { _, _, _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(30))
            return RecordingJobExecutionResult()
        }

        let job = try await fixture.enqueue(on: queue, policy: .immediate)
        await fulfillment(of: [started], timeout: 2)
        queue.interruptForSystemExpiration()

        try await waitUntil {
            try await fixture.store.job(id: job.id)?.phase == .queued
        }
        let persisted = try await fixture.store.job(id: job.id)
        XCTAssertEqual(persisted?.statusMessage, "Paused because background time expired")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: job).path))
    }

    func test_systemExpirationDoesNotRestartDrainForConcurrentEnqueue() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let firstStarted = expectation(description: "first executor started")
        let probe = QueueExecutionProbe()
        let queue = RecordingJobQueue(store: fixture.store) { job, _, _ in
            await probe.begin(job.id)
            let snapshot = await probe.snapshot()
            do {
                if snapshot.started.count == 1 {
                    firstStarted.fulfill()
                    try await Task.sleep(for: .seconds(30))
                }
            } catch {
                await probe.end(job.id)
                throw error
            }
            await probe.end(job.id)
            return RecordingJobExecutionResult()
        }

        let first = try await fixture.enqueue(on: queue, policy: .immediate)
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = try await fixture.enqueue(on: queue, policy: .immediate)
        queue.interruptForSystemExpiration()

        try await waitUntil {
            try await fixture.store.job(id: first.id)?.phase == .queued
        }
        try await Task.sleep(for: .milliseconds(150))
        let pausedSnapshot = await probe.snapshot()
        let secondPhase = try await fixture.store.job(id: second.id)?.phase
        XCTAssertEqual(pausedSnapshot.started, [first.id])
        XCTAssertEqual(secondPhase, .queued)

        queue.resume(includeIdle: false)
        try await waitUntil {
            let jobs = try await fixture.store.load(recoverInterrupted: false)
            return jobs.count == 2 && jobs.allSatisfy { $0.phase == .completed }
        }
        let completedSnapshot = await probe.snapshot()
        XCTAssertEqual(completedSnapshot.maximumConcurrentExecutions, 1)
    }

    func test_systemExpirationLatchBlocksLaterEnqueueUntilExplicitResume() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let firstStarted = expectation(description: "first executor started")
        let probe = QueueExecutionProbe()
        let queue = RecordingJobQueue(store: fixture.store) { job, _, _ in
            await probe.begin(job.id)
            let snapshot = await probe.snapshot()
            do {
                if snapshot.started.count == 1 {
                    firstStarted.fulfill()
                    try await Task.sleep(for: .seconds(30))
                }
            } catch {
                await probe.end(job.id)
                throw error
            }
            await probe.end(job.id)
            return RecordingJobExecutionResult()
        }

        let first = try await fixture.enqueue(on: queue, policy: .immediate)
        await fulfillment(of: [firstStarted], timeout: 2)
        queue.interruptForSystemExpiration()
        try await waitUntil {
            let phase = try await fixture.store.job(id: first.id)?.phase
            return phase == .queued && !queue.isProcessing
        }

        let later = try await fixture.enqueue(on: queue, policy: .immediate)
        try await Task.sleep(for: .milliseconds(150))
        let suspendedSnapshot = await probe.snapshot()
        let laterPhase = try await fixture.store.job(id: later.id)?.phase
        XCTAssertEqual(suspendedSnapshot.started, [first.id])
        XCTAssertEqual(laterPhase, .queued)

        queue.resume(includeIdle: false)
        try await waitUntil {
            let jobs = try await fixture.store.load(recoverInterrupted: false)
            return jobs.count == 2 && jobs.allSatisfy { $0.phase == .completed }
        }
    }

    func test_immediateWorkerWaitsForCrossProcessLeaseHandoff() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let acquired = try await fixture.store.tryAcquireWorkerLease()
        XCTAssertTrue(acquired)
        let secondStore = RecordingJobStore(
            rootDirectoryURL: fixture.store.rootDirectoryURL,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let executed = expectation(description: "second worker executed")
        let queue = RecordingJobQueue(store: secondStore) { _, _, _ in
            executed.fulfill()
            return RecordingJobExecutionResult()
        }

        let job = try await fixture.enqueue(on: queue, policy: .immediate)
        try await Task.sleep(for: .milliseconds(100))
        let waitingPhase = try await secondStore.job(id: job.id)?.phase
        XCTAssertEqual(waitingPhase, .queued)

        await fixture.store.releaseWorkerLease()
        await fulfillment(of: [executed], timeout: 2)
        try await waitUntil {
            try await secondStore.job(id: job.id)?.phase == .completed
        }
    }

    func test_retryAllEligibilityExcludesRecoveredJobsUntilRouteIsChosen() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let queue = RecordingJobQueue(store: fixture.store) { _, _, _ in
            RecordingJobExecutionResult()
        }
        let source = fixture.root.appendingPathComponent("recovered.wav")
        try Data(repeating: 3, count: 128).write(to: source)
        let recovered = try await fixture.store.enqueue(
            sourceURL: source,
            duration: 1,
            source: .recovered,
            delivery: .recovery,
            modelID: "automatic",
            language: "auto",
            configuration: RecordingQueueConfiguration(
                sourceAudioRetention: .permanent,
                processingPolicy: .manual
            )
        )
        _ = try await fixture.store.claim(id: recovered.id)
        _ = try await fixture.store.markFailed(
            id: recovered.id,
            stage: .storage,
            message: "Choose a preset"
        )
        await queue.refresh()

        XCTAssertTrue(queue.retryAllEligibleJobs.isEmpty)
        let preset = CapturePresetStore.defaultFlows[0]
        _ = try await fixture.store.retry(id: recovered.id, delivery: .preset(preset))
        _ = try await fixture.store.claim(id: recovered.id)
        _ = try await fixture.store.markFailed(
            id: recovered.id,
            stage: .transcription,
            message: "Retryable"
        )
        await queue.refresh()

        XCTAssertEqual(queue.retryAllEligibleJobs.map(\.id), [recovered.id])
    }

    func test_recoveryRetryPersistsChosenRouteAndCurrentTranscriptionSettings() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let queue = RecordingJobQueue(store: fixture.store) { _, _, _ in
            throw CancellationError()
        }
        queue.setCaptureActive(true)
        let source = fixture.root.appendingPathComponent("routed-recovery.wav")
        try Data(repeating: 5, count: 128).write(to: source)
        let recovered = try await fixture.store.enqueue(
            sourceURL: source,
            duration: 1,
            source: .recovered,
            delivery: .recovery,
            modelID: "",
            language: "auto",
            configuration: RecordingQueueConfiguration(
                sourceAudioRetention: .permanent,
                processingPolicy: .manual
            )
        )
        _ = try await fixture.store.claim(id: recovered.id)
        _ = try await fixture.store.markFailed(
            id: recovered.id,
            stage: .storage,
            message: "Choose a preset"
        )
        let preset = CapturePresetStore.defaultFlows[0]

        await queue.retry(
            recovered,
            modelID: "current-model",
            fallbackModelID: "current-fallback",
            language: "fr",
            delivery: .preset(preset)
        )

        let persistedRouted = try await fixture.store.job(id: recovered.id)
        let routed = try XCTUnwrap(persistedRouted)
        XCTAssertEqual(routed.modelID, "current-model")
        XCTAssertEqual(routed.fallbackModelID, "current-fallback")
        XCTAssertEqual(routed.language, "fr")
        XCTAssertEqual(routed.delivery, .preset(preset))
        XCTAssertEqual(routed.phase, .queued)
        XCTAssertEqual(routed.processingPolicy, .immediate)
    }

    func test_retryCanExplicitlyClearPersistedFallbackModel() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let queue = RecordingJobQueue(store: fixture.store) { _, _, _ in
            throw CancellationError()
        }
        queue.setCaptureActive(true)
        let source = fixture.root.appendingPathComponent("clear-fallback.wav")
        try Data(repeating: 7, count: 128).write(to: source)
        let job = try await fixture.store.enqueue(
            sourceURL: source,
            duration: 1,
            source: .iOSApp,
            delivery: .clipboard,
            modelID: "model",
            fallbackModelID: "stale-fallback",
            language: "en",
            configuration: RecordingQueueConfiguration(
                sourceAudioRetention: .permanent,
                processingPolicy: .manual
            )
        )
        _ = try await fixture.store.claim(id: job.id)
        _ = try await fixture.store.markFailed(
            id: job.id,
            stage: .transcription,
            message: "Retry"
        )

        await queue.retry(
            job,
            fallbackModelID: nil,
            replaceFallbackModelID: true
        )

        let retried = try await fixture.store.job(id: job.id)
        XCTAssertNil(retried?.fallbackModelID)
    }

    func test_actionFailureSurvivesRefreshForUserAlert() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let queue = RecordingJobQueue(store: fixture.store) { _, _, _ in
            RecordingJobExecutionResult()
        }
        let job = try await fixture.enqueue(on: queue, policy: .manual)
        _ = try await fixture.store.discard(id: job.id)

        await queue.processNow(job)

        XCTAssertNotNil(queue.lastError)
        XCTAssertEqual(
            queue.jobs.first(where: { $0.id == job.id })?.phase,
            .discarded
        )
    }

    func test_storeNotificationRefreshesMatchingQueueWithoutClearingError() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let queue = RecordingJobQueue(store: fixture.store) { _, _, _ in
            RecordingJobExecutionResult()
        }
        let staleJob = RecordingJob(
            audioFilename: "missing.wav",
            duration: 1,
            source: .iOSApp,
            delivery: .clipboard,
            modelID: "test-model",
            language: "en",
            retentionPolicy: .permanent,
            processingPolicy: .manual
        )
        await queue.processNow(staleJob)
        let actionError = try XCTUnwrap(queue.lastError)

        let secondStore = RecordingJobStore(
            rootDirectoryURL: fixture.store.rootDirectoryURL,
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
        let source = fixture.root.appendingPathComponent("external-change.wav")
        try Data(repeating: 8, count: 128).write(to: source)
        let externalJob = try await secondStore.enqueue(
            sourceURL: source,
            duration: 1,
            source: .macApp,
            delivery: .clipboard,
            modelID: "test-model",
            language: "en",
            configuration: RecordingQueueConfiguration(
                sourceAudioRetention: .permanent,
                processingPolicy: .manual
            )
        )

        try await waitUntil {
            queue.jobs.contains(where: { $0.id == externalJob.id })
        }
        XCTAssertEqual(queue.lastError, actionError)
    }

    func test_durableMonitorObservesChangeWithoutNotification() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let queue = RecordingJobQueue(store: fixture.store) { _, _, _ in
            RecordingJobExecutionResult()
        }
        await queue.refresh()
        let monitor = Task { @MainActor in
            await queue.monitorDurableChanges(every: .milliseconds(20))
        }
        defer { monitor.cancel() }

        let source = fixture.root.appendingPathComponent("polled-change.wav")
        try Data(repeating: 6, count: 128).write(to: source)
        let externalJob = RecordingJob(
            audioFilename: "polled.wav",
            duration: 1,
            source: .macApp,
            delivery: .clipboard,
            modelID: "test-model",
            language: "en",
            retentionPolicy: .permanent,
            processingPolicy: .manual
        )
        let itemsDirectory = fixture.store.rootDirectoryURL
            .appendingPathComponent("items", isDirectory: true)
        let audioDirectory = fixture.store.rootDirectoryURL
            .appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source,
            to: audioDirectory.appendingPathComponent(externalJob.audioFilename)
        )
        try JSONEncoder().encode(externalJob).write(
            to: itemsDirectory.appendingPathComponent("\(externalJob.id.uuidString.lowercased()).json"),
            options: .atomic
        )

        try await waitUntil {
            queue.jobs.contains(where: { $0.id == externalJob.id })
        }
    }

    func test_storeNotificationDoesNotRefreshQueueForDifferentRoot() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let other = try QueueFixture()
        defer { other.cleanup() }
        let queue = RecordingJobQueue(store: fixture.store) { _, _, _ in
            RecordingJobExecutionResult()
        }
        await queue.refresh()

        let source = other.root.appendingPathComponent("other-root.wav")
        try Data(repeating: 9, count: 128).write(to: source)
        _ = try await other.store.enqueue(
            sourceURL: source,
            duration: 1,
            source: .macApp,
            delivery: .clipboard,
            modelID: "test-model",
            language: "en",
            configuration: RecordingQueueConfiguration(
                sourceAudioRetention: .permanent,
                processingPolicy: .manual
            )
        )
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(queue.jobs.isEmpty)
    }

    func test_refreshDoesNotRequeueCurrentlyExecutingJob() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let started = expectation(description: "executor started")
        let release = AsyncReleaseGate()
        let queue = RecordingJobQueue(store: fixture.store) { _, _, _ in
            started.fulfill()
            await release.wait()
            return RecordingJobExecutionResult()
        }

        let job = try await fixture.enqueue(on: queue, policy: .immediate)
        await fulfillment(of: [started], timeout: 2)
        await queue.refresh(recoverInterrupted: true)
        let persistedWhileRunning = try await fixture.store.job(id: job.id)
        let whileRunning = try XCTUnwrap(persistedWhileRunning)
        XCTAssertEqual(whileRunning.phase, .processing)

        await release.open()
        try await waitUntil {
            try await fixture.store.job(id: job.id)?.phase == .completed
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for recording queue state")
    }
}

private struct QueueFixture {
    let root: URL
    let store: RecordingJobStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RecordingJobQueueTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = RecordingJobStore(
            rootDirectoryURL: root.appendingPathComponent("queue", isDirectory: true),
            coordinator: ProcessLocalCaptureFileCoordinator()
        )
    }

    @MainActor
    func enqueue(
        on queue: RecordingJobQueue,
        policy: RecordingJobProcessingPolicy
    ) async throws -> RecordingJob {
        let source = root.appendingPathComponent("\(UUID().uuidString).wav")
        try Data(repeating: 4, count: 128).write(to: source)
        return try await queue.enqueue(
            sourceURL: source,
            duration: 1,
            source: .iOSApp,
            delivery: .clipboard,
            modelID: "test-model",
            fallbackModelID: nil,
            language: "en",
            configuration: RecordingQueueConfiguration(
                sourceAudioRetention: .permanent,
                processingPolicy: policy
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor QueueExecutionProbe {
    private var active = 0
    private var maximum = 0
    private var startedIDs: [UUID] = []

    func begin(_ id: UUID) {
        active += 1
        maximum = max(maximum, active)
        startedIDs.append(id)
    }

    func end(_ id: UUID) {
        active -= 1
    }

    func snapshot() -> (started: [UUID], maximumConcurrentExecutions: Int) {
        (startedIDs, maximum)
    }
}

private actor AsyncReleaseGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}
