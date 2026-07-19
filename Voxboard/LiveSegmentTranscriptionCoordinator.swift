import Foundation
import VoxboardShared

private enum LiveSegmentCoordinatorError: Error, LocalizedError, Sendable {
    case audioOverwritten
    case feedFailed(String)

    var errorDescription: String? {
        switch self {
        case .audioOverwritten:
            return "Live transcription audio was overwritten."
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
            throw LiveSegmentCoordinatorError.feedFailed("Live transcription already ended.")
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
