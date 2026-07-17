import Foundation

public enum CaptureVoiceLifecycleFailure: String, Equatable, Sendable {
    case microphoneBusy
    case permissionDenied
    case couldNotStart
    case noUsableAudio
    case encoding
}

public enum CaptureVoiceLifecyclePhase: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case review
    case failed(CaptureVoiceLifecycleFailure)
}

public enum CaptureVoiceCompletionAction: Equatable, Sendable {
    case ignore
    case rejectAudio
    case reviewAudio
    case transcribeAudio
}

/// Pure lifecycle guard for capture voice attachments. Audio engines remain an
/// app concern; this state machine makes interruption, retry, cancellation, and
/// late-transcription behavior deterministic and independently testable.
public struct CaptureVoiceLifecycle: Equatable, Sendable {
    public private(set) var phase: CaptureVoiceLifecyclePhase = .idle
    public private(set) var generation: UInt64 = 0
    public var minimumUsableDuration: TimeInterval

    public init(minimumUsableDuration: TimeInterval = 0.3) {
        self.minimumUsableDuration = minimumUsableDuration
    }

    @discardableResult
    public mutating func beginAttempt() -> UInt64 {
        generation &+= 1
        phase = .idle
        return generation
    }

    @discardableResult
    public mutating func recordingStarted(generation candidate: UInt64) -> Bool {
        guard candidate == generation, phase == .idle else { return false }
        phase = .recording
        return true
    }

    @discardableResult
    public mutating func fail(
        generation candidate: UInt64,
        with failure: CaptureVoiceLifecycleFailure
    ) -> Bool {
        guard candidate == generation else { return false }
        switch failure {
        case .microphoneBusy, .permissionDenied, .couldNotStart:
            guard phase == .idle else { return false }
        case .encoding:
            guard phase == .recording else { return false }
        case .noUsableAudio:
            guard phase == .recording else { return false }
        }
        phase = .failed(failure)
        return true
    }

    public mutating func finishRecording(
        generation candidate: UInt64,
        duration: TimeInterval,
        fileExists: Bool,
        fileByteCount: Int64,
        wantsTranscript: Bool,
        modelAvailable: Bool
    ) -> CaptureVoiceCompletionAction {
        guard candidate == generation, phase == .recording else { return .ignore }
        guard isUsableAudio(duration: duration, fileExists: fileExists, fileByteCount: fileByteCount) else {
            phase = .failed(.noUsableAudio)
            return .rejectAudio
        }
        if wantsTranscript, modelAvailable {
            phase = .transcribing
            return .transcribeAudio
        }
        phase = .review
        return .reviewAudio
    }

    @discardableResult
    public mutating func transcriptionFinished(generation candidate: UInt64) -> Bool {
        guard candidate == generation, phase == .transcribing else { return false }
        phase = .review
        return true
    }

    public mutating func backgrounded(
        generation candidate: UInt64,
        duration: TimeInterval,
        fileExists: Bool,
        fileByteCount: Int64
    ) -> CaptureVoiceCompletionAction {
        guard candidate == generation, phase == .recording else { return .ignore }
        guard isUsableAudio(duration: duration, fileExists: fileExists, fileByteCount: fileByteCount) else {
            phase = .failed(.noUsableAudio)
            return .rejectAudio
        }
        phase = .review
        return .reviewAudio
    }

    public mutating func cancel() {
        invalidateAndReset()
    }

    public mutating func inserted() {
        invalidateAndReset()
    }

    private func isUsableAudio(
        duration: TimeInterval,
        fileExists: Bool,
        fileByteCount: Int64
    ) -> Bool {
        duration >= minimumUsableDuration && fileExists && fileByteCount > 0
    }

    private mutating func invalidateAndReset() {
        generation &+= 1
        phase = .idle
    }
}
