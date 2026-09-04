import Foundation
import VoxboardShared

private enum LiveSegmentCoordinatorError: Error, LocalizedError, Sendable {
    case audioOverwritten
    case feedFailed(String)

    var errorDescription: String? {
        switch self {
        case .audioOverwritten:
            return String(localized: "Live transcription audio was overwritten.")
        case .feedFailed(let message):
            return message
        }
    }
}

actor LiveTranscriptionProgress {
    private var finalizedText = ""

    func record(_ update: SystemTranscriptionUpdate) {
        if update.finalizedText.hasPrefix(finalizedText) {
            finalizedText = update.finalizedText
        }
    }

    var hasFinalizedText: Bool { !finalizedText.isEmpty }
}

/// Feeds one Apple Speech session from the existing rolling audio buffer.
/// Polling keeps actor work, allocations, IPC, and Speech APIs off the
/// AVAudioEngine real-time callback.
actor LiveSegmentTranscriptionCoordinator {
    private let session: any SystemLiveTranscriptionSession
    private let circularBuffer: CircularAudioBuffer
    private let sampleRate: Double
    private let chunkSize: Int
    private let progress: LiveTranscriptionProgress

    private var cursor: Int64
    private var feederTask: Task<Void, Never>?
    private var feedFailure: LiveSegmentCoordinatorError?
    private var isFinished = false
    /// Suspends feeding while the recorder is paused. On resume the cursor
    /// jumps to the buffer's write head so paused ambient audio is never fed
    /// to the Speech session.
    private var isPaused = false

    init(
        session: any SystemLiveTranscriptionSession,
        circularBuffer: CircularAudioBuffer,
        startIndex: Int64,
        sampleRate: Double,
        progress: LiveTranscriptionProgress,
        chunkSize: Int = 4_096
    ) {
        self.session = session
        self.circularBuffer = circularBuffer
        self.cursor = startIndex
        self.sampleRate = sampleRate
        self.progress = progress
        self.chunkSize = chunkSize
    }

    /// Stop feeding audio while the recorder is paused.
    func pause() {
        isPaused = true
    }

    /// Resume feeding after a pause, skipping every sample captured while
    /// paused so the transcript and final audio stay gap-free. Pass `until` to
    /// skip through a specific buffer index (used when a paused recording is
    /// stopped, so the suspended tail is never transcribed).
    func resume(until skipThrough: Int64? = nil) {
        guard isPaused else { return }
        isPaused = false
        let skipTarget = skipThrough ?? circularBuffer.totalSamplesWritten
        cursor = max(cursor, skipTarget)
    }

    func hasPublishedFinalizedText() async -> Bool {
        await progress.hasFinalizedText
    }

    func start() {
        guard feederTask == nil, !isFinished else { return }
        feederTask = Task { [weak self] in
            await self?.feedLoop()
        }
    }

    func finish(through endIndex: Int64) async throws -> SystemTranscriptionOutput {
        guard !isFinished else {
            throw LiveSegmentCoordinatorError.feedFailed(String(localized: "Live transcription already ended."))
        }
        isFinished = true
        feederTask?.cancel()
        _ = await feederTask?.value
        feederTask = nil

        do {
            if let feedFailure { throw feedFailure }
            try await drain(through: endIndex)
            if cursor < endIndex {
                throw LiveSegmentCoordinatorError.audioOverwritten
            }
            return try await session.finish()
        } catch {
            await session.cancel()
            throw error
        }
    }

    func cancel() async {
        guard !isFinished else { return }
        isFinished = true
        feederTask?.cancel()
        _ = await feederTask?.value
        feederTask = nil
        await session.cancel()
    }

    private func feedLoop() async {
        while !Task.isCancelled, !isFinished {
            guard !isPaused else {
                try? await Task.sleep(for: .milliseconds(80))
                continue
            }
            do {
                try await drain(through: nil)
            } catch is CancellationError {
                return
            } catch {
                feedFailure = .feedFailed(error.localizedDescription)
                return
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func drain(through endIndex: Int64?) async throws {
        if cursor < circularBuffer.earliestAvailableIndex {
            throw LiveSegmentCoordinatorError.audioOverwritten
        }

        while !Task.isCancelled,
              let chunk = circularBuffer.extractAvailable(
                from: cursor,
                through: endIndex,
                maxCount: chunkSize
              ) {
            try await session.append(SystemTranscriptionAudioChunk(
                samples: chunk.samples,
                sampleRate: sampleRate
            ))
            cursor = chunk.nextIndex
        }
    }
}
