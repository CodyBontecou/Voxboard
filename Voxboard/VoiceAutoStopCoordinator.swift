import Foundation
import VoxboardShared

enum VoiceAutoStopCoordinatorError: Error, LocalizedError, Sendable {
    case audioOverwritten

    var errorDescription: String? {
        switch self {
        case .audioOverwritten:
            return String(localized: "Voice pause detection audio was overwritten.")
        }
    }
}

/// Feeds exact 4,096-sample, 16 kHz frames from the recorder's rolling buffer
/// into FluidAudio VAD. Work stays off the AVAudioEngine real-time callback.
actor VoiceAutoStopCoordinator {
    typealias EndHandler = @MainActor @Sendable () -> Void

    private let requestID: String
    private let session: any VoiceActivityStreamingSession
    private let circularBuffer: CircularAudioBuffer
    private let frameSize: Int
    private let minimumSpeechSamples: Int
    private let onSpeechEnd: EndHandler

    private var cursor: Int64
    private var pendingSamples: [Float] = []
    private var speechStartSample: Int?
    private var feederTask: Task<Void, Never>?
    private var isFinished = false

    init(
        requestID: String,
        session: any VoiceActivityStreamingSession,
        circularBuffer: CircularAudioBuffer,
        startIndex: Int64,
        minimumSpeechDuration: TimeInterval = 0.3,
        sampleRate: Double = VoiceActivityModelAsset.sampleRate,
        frameSize: Int = VoiceActivityModelAsset.chunkSize,
        onSpeechEnd: @escaping EndHandler
    ) {
        self.requestID = requestID
        self.session = session
        self.circularBuffer = circularBuffer
        self.cursor = startIndex
        self.frameSize = frameSize
        self.minimumSpeechSamples = Int(minimumSpeechDuration * sampleRate)
        self.onSpeechEnd = onSpeechEnd
        self.pendingSamples.reserveCapacity(frameSize * 2)
    }

    func start() {
        guard feederTask == nil, !isFinished else { return }
        feederTask = Task { [weak self] in
            await self?.feedLoop()
        }
    }

    func cancel() async {
        guard !isFinished else { return }
        isFinished = true
        feederTask?.cancel()
        _ = await feederTask?.value
        feederTask = nil
    }

    /// Internal for deterministic tests and also used by the polling loop.
    func processAvailableAudio() async throws {
        guard !isFinished else { return }
        if cursor < circularBuffer.earliestAvailableIndex {
            throw VoiceAutoStopCoordinatorError.audioOverwritten
        }

        while !Task.isCancelled, !isFinished {
            let needed = max(1, frameSize - pendingSamples.count)
            guard let chunk = circularBuffer.extractAvailable(
                from: cursor,
                maxCount: needed
            ) else {
                break
            }
            cursor = chunk.nextIndex
            pendingSamples.append(contentsOf: chunk.samples)

            guard pendingSamples.count == frameSize else { continue }
            let frame = pendingSamples
            pendingSamples.removeAll(keepingCapacity: true)

            if let event = try await session.process(frame) {
                await handle(event)
            }
        }
    }

    private func feedLoop() async {
        while !Task.isCancelled, !isFinished {
            do {
                try await processAvailableAudio()
            } catch is CancellationError {
                return
            } catch {
                KeyboardDebugLog.shared.log("[VoiceAutoStop] Detection stopped for \(requestID.prefix(8)): \(error.localizedDescription)")
                isFinished = true
                return
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func handle(_ event: VoiceActivityStreamEvent) async {
        switch event {
        case .speechStarted(let sampleIndex):
            speechStartSample = sampleIndex

        case .speechEnded(let sampleIndex):
            guard let speechStartSample else { return }
            self.speechStartSample = nil
            guard sampleIndex - speechStartSample >= minimumSpeechSamples else {
                KeyboardDebugLog.shared.log("[VoiceAutoStop] Ignoring speech shorter than minimum for \(requestID.prefix(8))")
                return
            }

            isFinished = true
            KeyboardDebugLog.shared.log("[VoiceAutoStop] End of speech detected for \(requestID.prefix(8))")
            await onSpeechEnd()
        }
    }
}
