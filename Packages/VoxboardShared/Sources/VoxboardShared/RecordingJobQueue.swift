import Foundation

public protocol RecordingJobFailureClassifying: Error {
    var recordingJobFailureStage: RecordingJobFailureStage { get }
}

extension TranscriptStorePersistenceError: RecordingJobFailureClassifying {
    public var recordingJobFailureStage: RecordingJobFailureStage { .delivery }
}

public struct RecordingJobExecutionResult: Equatable, Sendable {
    public var transcriptText: String?

    public init(transcriptText: String? = nil) {
        self.transcriptText = transcriptText
    }
}

public typealias RecordingJobProgressHandler = @MainActor @Sendable (TranscriptionProgress) -> Void
public typealias RecordingJobExecutor = @MainActor @Sendable (
    RecordingJob,
    URL,
    @escaping RecordingJobProgressHandler
) async throws -> RecordingJobExecutionResult

private enum RecordingQueueInterruption {
    case interactive
    case systemExpiration

    var statusMessage: String {
        switch self {
        case .interactive:
            "Paused for interactive transcription"
        case .systemExpiration:
            "Paused because background time expired"
        }
    }
}

@MainActor
@Observable
public final class RecordingJobQueue {
    public private(set) var jobs: [RecordingJob] = []
    public private(set) var activeJobID: UUID?
    public private(set) var transcriptionProgress: TranscriptionProgress?
    public private(set) var lastError: String?

    public var isProcessing: Bool { processingTask != nil }
    public var activeJob: RecordingJob? {
        guard let activeJobID else { return nil }
        return jobs.first(where: { $0.id == activeJobID })
    }
    public var actionableJobs: [RecordingJob] {
        jobs.filter { job in
            switch job.phase {
            case .queued, .processing, .finalizing, .failed:
                return true
            case .completed:
                return job.transcriptText != nil || job.audioDeletedAt == nil
            case .discarded:
                return false
            }
        }
    }
    public var pendingCount: Int {
        jobs.filter { $0.phase == .queued || $0.phase == .failed }.count
    }
    public var retryAllEligibleJobs: [RecordingJob] {
        actionableJobs.filter { $0.phase == .failed && $0.delivery != .recovery }
    }

    public let store: RecordingJobStore
    private let executor: RecordingJobExecutor
    private let processStartedAt = Date()
    private var processingTask: Task<Void, Never>?
    private var includesIdleWork = false
    private var isCaptureActive = false
    private var isSystemSuspended = false
    private var needsDrainAfterCurrent = false
    private var pendingInterruption: RecordingQueueInterruption?
    private var storeChangeObserver: NSObjectProtocol?
    private var externalRefreshTask: Task<Void, Never>?

    public init(
        store: RecordingJobStore,
        executor: @escaping RecordingJobExecutor
    ) {
        self.store = store
        self.executor = executor
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: RecordingJobStore.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self, store] notification in
            guard store.ownsChangeNotification(notification) else { return }
            Task { @MainActor [weak self] in
                self?.scheduleExternalRefresh()
            }
        }
    }

    isolated deinit {
        if let storeChangeObserver {
            NotificationCenter.default.removeObserver(storeChangeObserver)
        }
        externalRefreshTask?.cancel()
    }

    public func refresh(
        recoverInterrupted: Bool = false,
        clearExistingError: Bool = true
    ) async {
        do {
            let canRecover = recoverInterrupted && processingTask == nil && activeJobID == nil
            jobs = try await store.load(recoverInterrupted: canRecover)
            if clearExistingError { lastError = nil }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func scheduleExternalRefresh() {
        externalRefreshTask?.cancel()
        externalRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                await self?.refresh(clearExistingError: false)
            } catch {
                // A newer durable change superseded this coalesced refresh.
            }
        }
    }

    /// Polls durable manifests while queue UI is visible. In-process changes
    /// arrive immediately through NotificationCenter; polling also observes a
    /// separate process that shares the queue directory.
    public func monitorDurableChanges(
        every interval: Duration = .seconds(1)
    ) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await refresh(clearExistingError: false)
        }
    }

    public func resume(includeIdle: Bool) {
        isSystemSuspended = false
        scheduleDrain(includeIdle: includeIdle)
    }

    private func scheduleDrain(includeIdle: Bool) {
        includesIdleWork = includeIdle
        guard !isCaptureActive, !isSystemSuspended,
              pendingInterruption != .systemExpiration else { return }
        guard processingTask == nil else {
            // An enqueue can race the worker's final empty claim. Remember the
            // request so the defer path starts another drain after publishing
            // processingTask = nil.
            needsDrainAfterCurrent = true
            return
        }
        processingTask = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    public func clearError() {
        lastError = nil
    }

    /// Gives interactive keyboard transcription priority over background queue
    /// work. Cancellable backends stop promptly; non-cancellable native calls
    /// are requeued as soon as they return.
    public func interruptForInteractiveWork() {
        isCaptureActive = true
        if processingTask != nil {
            pendingInterruption = .interactive
            processingTask?.cancel()
        }
    }

    /// Stops opportunistic work when the OS revokes background time. The
    /// cancellation path returns the active job to its durable queued state.
    public func interruptForSystemExpiration() {
        // Latch the suspension even when no worker is currently running. A new
        // immediate enqueue is not a fresh OS background-time opportunity.
        isSystemSuspended = true
        if processingTask != nil {
            pendingInterruption = .systemExpiration
            processingTask?.cancel()
        }
    }

    public func setCaptureActive(_ active: Bool) {
        isCaptureActive = active
        if !active {
            scheduleDrain(includeIdle: includesIdleWork)
        }
    }

    /// Ends priority interactive work without treating it as a new system
    /// execution opportunity. A latched background expiration remains in force.
    public func finishInteractiveWork(includeIdle: Bool) {
        isCaptureActive = false
        scheduleDrain(includeIdle: includeIdle)
    }

    public func enqueue(
        sourceURL: URL,
        id: UUID = UUID(),
        requestID: String? = nil,
        draftRequestID: UUID? = nil,
        liveSessionID: UUID? = nil,
        captureSource: CaptureSource? = nil,
        locationOutcome: CaptureLocationOutcome? = nil,
        originalFilename: String? = nil,
        createdAt: Date = Date(),
        duration: TimeInterval,
        source: RecordingJobSource,
        delivery: RecordingJobDelivery,
        modelID: String,
        fallbackModelID: String?,
        language: String,
        configuration: RecordingQueueConfiguration? = nil,
        forceImmediate: Bool = false
    ) async throws -> RecordingJob {
        var resolvedConfiguration = configuration ?? RecordingQueuePreferences.load()
        if forceImmediate {
            resolvedConfiguration.processingPolicy = .immediate
        }
        let job = try await store.enqueue(
            sourceURL: sourceURL,
            id: id,
            requestID: requestID,
            draftRequestID: draftRequestID,
            liveSessionID: liveSessionID,
            captureSource: captureSource,
            locationOutcome: locationOutcome,
            originalFilename: originalFilename,
            createdAt: createdAt,
            duration: duration,
            source: source,
            delivery: delivery,
            modelID: modelID,
            fallbackModelID: fallbackModelID,
            language: language,
            configuration: resolvedConfiguration
        )
        await refresh()
        if resolvedConfiguration.processingPolicy == .immediate {
            scheduleDrain(includeIdle: includesIdleWork)
        }
        return job
    }

    public func processNow(_ job: RecordingJob) async {
        do {
            _ = try await store.processNow(id: job.id)
            await refresh()
            resume(includeIdle: includesIdleWork)
        } catch {
            lastError = error.localizedDescription
            await refresh(clearExistingError: false)
        }
    }

    public func retry(
        _ job: RecordingJob,
        modelID: String? = nil,
        fallbackModelID: String? = nil,
        replaceFallbackModelID: Bool = false,
        language: String? = nil,
        delivery: RecordingJobDelivery? = nil
    ) async {
        do {
            _ = try await store.retry(
                id: job.id,
                modelID: modelID,
                fallbackModelID: fallbackModelID,
                replaceFallbackModelID: replaceFallbackModelID,
                language: language,
                delivery: delivery
            )
            _ = try await store.processNow(id: job.id)
            await refresh()
            resume(includeIdle: includesIdleWork)
        } catch {
            lastError = error.localizedDescription
            await refresh(clearExistingError: false)
        }
    }

    public func discard(_ job: RecordingJob) async {
        do {
            _ = try await store.discard(id: job.id)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            await refresh(clearExistingError: false)
        }
    }

    public func recordTranscriptCheckpoint(id: UUID, text: String) async throws {
        _ = try await store.recordTranscriptCheckpoint(id: id, text: text)
        await refresh()
    }

    public func markExportedAudio(id: UUID, url: URL) async throws {
        _ = try await store.markExportedAudio(id: id, path: url.path)
        await refresh()
    }

    public func markExportedNote(id: UUID, url: URL) async throws {
        _ = try await store.markExportedNote(id: id, path: url.path)
        await refresh()
    }

    public func markAudioReferenceAttached(id: UUID) async throws {
        _ = try await store.markAudioReferenceAttached(id: id)
        await refresh()
    }

    public func markAutomaticClipboardDeliveryAttempted(id: UUID) async throws {
        _ = try await store.markAutomaticClipboardDeliveryAttempted(id: id)
        await refresh()
    }

    public func acknowledgeCopiedResult(_ job: RecordingJob) async {
        do {
            _ = try await store.clearCompletedTranscriptText(id: job.id)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            await refresh(clearExistingError: false)
        }
    }

    public func updateRetention(
        _ job: RecordingJob,
        policy: SourceAudioRetentionPolicy
    ) async {
        do {
            _ = try await store.updateRetention(id: job.id, policy: policy)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            await refresh(clearExistingError: false)
        }
    }

    public func audioURL(for job: RecordingJob) -> URL? {
        guard job.audioDeletedAt == nil else { return nil }
        let url = store.audioURL(for: job)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func drain() async {
        defer {
            let mayResumeAfterDrain = pendingInterruption != .systemExpiration
            activeJobID = nil
            transcriptionProgress = nil
            pendingInterruption = nil
            processingTask = nil
            if mayResumeAfterDrain, needsDrainAfterCurrent, !isCaptureActive {
                needsDrainAfterCurrent = false
                scheduleDrain(includeIdle: includesIdleWork)
            } else if !mayResumeAfterDrain {
                // A concurrent enqueue remains durably queued. Foreground or a
                // future background opportunity must explicitly call resume.
                needsDrainAfterCurrent = false
            }
        }
        var acquiredLease = false
        while !Task.isCancelled && !isCaptureActive && !acquiredLease {
            do {
                acquiredLease = try await store.tryAcquireWorkerLease()
            } catch {
                lastError = error.localizedDescription
                return
            }
            if !acquiredLease {
                // flock has no portable async wait. Retry without blocking a
                // thread until the process holding the worker lease exits or
                // finishes its drain.
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
        guard acquiredLease else { return }

        await drainWithWorkerLease()
        await store.releaseWorkerLease()
    }

    private func drainWithWorkerLease() async {
        do {
            if let recordingsDirectoryURL = AppConstants.recordingsDirectoryURL {
                _ = try await store.recoverExternalOrphans(
                    recordingsDirectoryURL: recordingsDirectoryURL,
                    olderThan: processStartedAt
                )
            }
            _ = try await store.performRetentionCleanup()
            jobs = try await store.load(recoverInterrupted: true)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        while !Task.isCancelled && !isCaptureActive {
            let job: RecordingJob
            do {
                guard let claimed = try await store.claimNext(includeIdle: includesIdleWork) else {
                    await refresh()
                    return
                }
                job = claimed
            } catch {
                lastError = error.localizedDescription
                await refresh()
                return
            }

            activeJobID = job.id
            transcriptionProgress = nil
            await refresh()
            let audioURL = store.audioURL(for: job)

            do {
                let result = try await executor(job, audioURL) { [weak self] progress in
                    guard self?.activeJobID == job.id else { return }
                    if let current = self?.transcriptionProgress?.exactFractionCompleted,
                       let incoming = progress.exactFractionCompleted,
                       incoming < current {
                        return
                    }
                    self?.transcriptionProgress = progress
                }
                try Task.checkCancellation()
                _ = try await store.markFinalizing(id: job.id)
                _ = try await store.markCompleted(
                    id: job.id,
                    transcriptText: result.transcriptText
                )
                lastError = nil
            } catch is CancellationError {
                let statusMessage = pendingInterruption?.statusMessage
                    ?? "Paused before processing completed"
                _ = try? await store.returnInterruptedJobToQueue(
                    id: job.id,
                    message: statusMessage
                )
                await refresh()
                return
            } catch {
                let stage = (error as? RecordingJobFailureClassifying)?.recordingJobFailureStage
                    ?? .transcription
                _ = try? await store.markFailed(
                    id: job.id,
                    stage: stage,
                    message: error.localizedDescription
                )
                lastError = error.localizedDescription
            }

            activeJobID = nil
            transcriptionProgress = nil
            await refresh()
        }
    }
}
