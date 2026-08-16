import Foundation

public enum RecordingArtifactRole: String, Codable, CaseIterable, Sendable {
    case primaryAudio
    case meetingMicrophone
    case meetingSystem
    case meetingTimeline
    case playbackMix
}

public struct RecordingArtifact: Codable, Equatable, Sendable, Identifiable {
    public var role: RecordingArtifactRole
    public var filename: String
    public var originalFilename: String?

    public var id: RecordingArtifactRole { role }

    public init(role: RecordingArtifactRole, filename: String, originalFilename: String? = nil) {
        self.role = role
        self.filename = filename
        self.originalFilename = originalFilename
    }
}

public enum TranscriptSpeakerRole: String, Codable, Sendable {
    case local
    case remoteAnonymous
    case unknown
}

public enum MeetingAudioSource: String, Codable, Sendable, CaseIterable {
    case microphone
    case system

    public var artifactRole: RecordingArtifactRole {
        self == .microphone ? .meetingMicrophone : .meetingSystem
    }
}

public struct MeetingTimelineEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case started
        case gap
        case dropped
        case discontinuity
        case formatChange
        case stopped
    }

    public var source: MeetingAudioSource
    public var kind: Kind
    public var presentationTime: TimeInterval
    public var duration: TimeInterval
    public var sampleRate: Double?
    public var channelCount: Int?

    public init(
        source: MeetingAudioSource,
        kind: Kind,
        presentationTime: TimeInterval,
        duration: TimeInterval = 0,
        sampleRate: Double? = nil,
        channelCount: Int? = nil
    ) {
        self.source = source
        self.kind = kind
        self.presentationTime = presentationTime
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// A finalized source chunk and its position on the common meeting timeline.
/// Chunk metadata is published only after AVAssetWriter reports `.completed`
/// and the file has a verified nonzero size.
public struct MeetingCaptureChunk: Codable, Equatable, Sendable, Identifiable {
    public var source: MeetingAudioSource
    public var filename: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var byteCount: UInt64

    public var id: String { filename }

    public init(source: MeetingAudioSource, filename: String, startTime: TimeInterval, endTime: TimeInterval, byteCount: UInt64) {
        self.source = source
        self.filename = filename
        self.startTime = startTime
        self.endTime = endTime
        self.byteCount = byteCount
    }
}

/// Durable sidecar written before an asynchronously finalized chunk is
/// announced to the in-memory coordinator. Recovery can therefore discover a
/// completed file even if the process exits before the aggregate manifest is
/// updated.
public struct MeetingCaptureChunkReceipt: Codable, Equatable, Sendable {
    public var chunk: MeetingCaptureChunk
    public var events: [MeetingTimelineEvent]
    public var warnings: [String]

    public init(chunk: MeetingCaptureChunk, events: [MeetingTimelineEvent], warnings: [String]) {
        self.chunk = chunk
        self.events = events
        self.warnings = warnings
    }
}

public struct MeetingCaptureManifest: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case preparing
        case recording
        case captured
        case interrupted
        case normalizing
        case queued
        case consumed
    }

    public static let currentSchemaVersion = 2
    public var schemaVersion = currentSchemaVersion
    public var sessionID: UUID
    public var createdAt: Date
    public var state: State
    public var selectedApplicationName: String?
    public var selectedApplicationBundleIdentifier: String?
    public var chunks: [MeetingCaptureChunk]
    public var events: [MeetingTimelineEvent]
    public var warnings: [String]
    public var duration: TimeInterval
    public var delivery: RecordingJobDelivery?
    public var modelID: String?
    public var fallbackModelID: String?
    public var language: String?
    public var draftRequestID: UUID?
    public var queuedAt: Date?

    public init(
        sessionID: UUID,
        createdAt: Date = Date(),
        state: State = .preparing,
        selectedApplicationName: String? = nil,
        selectedApplicationBundleIdentifier: String? = nil,
        chunks: [MeetingCaptureChunk] = [],
        events: [MeetingTimelineEvent] = [],
        warnings: [String] = [],
        duration: TimeInterval = 0,
        delivery: RecordingJobDelivery? = nil,
        modelID: String? = nil,
        fallbackModelID: String? = nil,
        language: String? = nil,
        draftRequestID: UUID? = nil,
        queuedAt: Date? = nil
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.state = state
        self.selectedApplicationName = selectedApplicationName
        self.selectedApplicationBundleIdentifier = selectedApplicationBundleIdentifier
        self.chunks = chunks
        self.events = events
        self.warnings = warnings
        self.duration = duration
        self.delivery = delivery
        self.modelID = modelID
        self.fallbackModelID = fallbackModelID
        self.language = language
        self.draftRequestID = draftRequestID
        self.queuedAt = queuedAt
    }

    public var hasSafeRecoveryMetadata: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              duration.isFinite, duration >= 0,
              Set(chunks.map(\.filename)).count == chunks.count else { return false }
        let chunksAreSafe = chunks.allSatisfy { chunk in
            !chunk.filename.isEmpty
                && chunk.filename != "."
                && chunk.filename != ".."
                && !chunk.filename.contains("/")
                && !chunk.filename.contains("\\")
                && URL(fileURLWithPath: chunk.filename).lastPathComponent == chunk.filename
                && chunk.byteCount > 0
                && chunk.startTime.isFinite
                && chunk.endTime.isFinite
                && chunk.startTime >= 0
                && chunk.endTime >= chunk.startTime
        }
        let eventsAreSafe = events.allSatisfy { event in
            event.presentationTime.isFinite
                && event.duration.isFinite
                && event.presentationTime >= 0
                && event.duration >= 0
                && (event.sampleRate.map { $0.isFinite && $0 > 0 } ?? true)
                && (event.channelCount.map { $0 > 0 } ?? true)
        }
        return chunksAreSafe && eventsAreSafe
    }

    public var isRecoverable: Bool {
        hasSafeRecoveryMetadata && state != .consumed && state != .queued && !chunks.isEmpty
    }

    public func orderedChunks(for source: MeetingAudioSource) -> [MeetingCaptureChunk] {
        chunks.filter { $0.source == source }.sorted {
            $0.startTime == $1.startTime ? $0.filename < $1.filename : $0.startTime < $1.startTime
        }
    }
}

public struct MeetingTimedText: Equatable, Sendable {
    public var source: MeetingAudioSource
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var remoteSpeaker: Int?

    public init(source: MeetingAudioSource, text: String, startTime: TimeInterval, endTime: TimeInterval, remoteSpeaker: Int? = nil) {
        self.source = source
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.remoteSpeaker = remoteSpeaker
    }
}

public enum MeetingTranscriptAssembler {
    public static func mapToMeetingTimeline(
        segments: [TimedTranscriptionSegment],
        source: MeetingAudioSource,
        manifest: MeetingCaptureManifest
    ) -> [MeetingTimedText] {
        let chunks = manifest.orderedChunks(for: source)
        return segments.map { segment in
            // Normalized stems already include leading/gap silence, so ASR
            // timestamps are on the common meeting timeline. Clamp them to the
            // captured source envelope to reject backend overshoot.
            let upper = chunks.map(\.endTime).max() ?? manifest.duration
            return MeetingTimedText(
                source: source,
                text: segment.text,
                startTime: max(0, min(segment.startTime, upper)),
                endTime: max(0, min(segment.endTime, upper))
            )
        }
    }

    public static func turns(from units: [MeetingTimedText]) -> [TranscriptSpeakerTurn] {
        units.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime }
            .map { unit in
                let role: TranscriptSpeakerRole = unit.source == .microphone ? .local : .remoteAnonymous
                return TranscriptSpeakerTurn(
                    speaker: unit.source == .microphone ? 0 : (unit.remoteSpeaker ?? 0) + 1,
                    text: unit.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    startTime: unit.startTime,
                    endTime: unit.endTime,
                    role: role,
                    displayLabel: role == .local ? "You" : nil
                )
            }
    }

    public static func renderedText(from turns: [TranscriptSpeakerTurn]) -> String {
        turns.map { "\($0.speakerLabel):\n\($0.text)" }.joined(separator: "\n\n")
    }
}

public enum MeetingClipboardPolicy {
    public static func shouldCopyAutomatically(
        delivery: RecordingJobDelivery,
        initialPolicy: RecordingJobProcessingPolicy,
        attemptedAt: Date?
    ) -> Bool {
        delivery == .clipboard && initialPolicy == .immediate && attemptedAt == nil
    }
}

/// Pure state transition used by the capture coordinator and deterministic tests.
public struct MeetingCaptureLifecycle: Equatable, Sendable {
    public enum State: Equatable, Sendable { case idle, selecting, preparing, recording, stopping, finished }
    public private(set) var state: State = .idle
    public private(set) var stopWasRequested = false

    public init() {}

    public mutating func beginSelection() throws {
        guard state == .idle || state == .finished else { throw TransitionError.invalidStart }
        state = .selecting
        stopWasRequested = false
    }

    public mutating func beginPreparing() throws {
        guard state == .selecting else { throw TransitionError.invalidTransition }
        state = .preparing
    }

    public mutating func didStart() throws {
        guard state == .preparing else { throw TransitionError.invalidTransition }
        state = .recording
    }

    /// Returns true once per session so user stop and SCStream interruption can race safely.
    public mutating func requestStop() -> Bool {
        guard state == .recording, !stopWasRequested else { return false }
        stopWasRequested = true
        state = .stopping
        return true
    }

    public mutating func didFinish() { state = .finished }
    public mutating func reset() { self = MeetingCaptureLifecycle() }

    public enum TransitionError: Error { case invalidStart, invalidTransition }
}

/// Callback-driven state machine for a chunk writer. Keeping the rollover/stop
/// interleaving independent from AVAssetWriter makes the boundary race
/// deterministic to test while the concrete writer remains queue-confined.
public struct MeetingChunkWriterLifecycle: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case accepting
        case rotating
        case stopping
        case stopped
    }

    public enum StopAction: Equatable, Sendable {
        case finalizeCurrent
        case waitForRotation
        case completeStop
        case alreadyStopping
    }

    public enum RotationCompletionAction: Equatable, Sendable {
        case startNextChunk
        case finalizeBufferedChunk
        case completeStop
        case none
    }

    public private(set) var state: State = .accepting

    public init() {}

    public var acceptsSamples: Bool { state == .accepting }
    public var buffersSamples: Bool { state == .rotating }

    @discardableResult
    public mutating func beginRotation() -> Bool {
        guard state == .accepting else { return false }
        state = .rotating
        return true
    }

    public mutating func requestStop(hasCurrentChunk: Bool) -> StopAction {
        switch state {
        case .accepting:
            if hasCurrentChunk {
                state = .stopping
                return .finalizeCurrent
            }
            state = .stopped
            return .completeStop
        case .rotating:
            state = .stopping
            return .waitForRotation
        case .stopping, .stopped:
            return .alreadyStopping
        }
    }

    public mutating func didFinishRotation(hasBufferedSamples: Bool) -> RotationCompletionAction {
        switch state {
        case .rotating:
            state = .accepting
            return hasBufferedSamples ? .startNextChunk : .none
        case .stopping:
            if hasBufferedSamples { return .finalizeBufferedChunk }
            state = .stopped
            return .completeStop
        case .accepting, .stopped:
            return .none
        }
    }

    public mutating func didFinishStop() {
        state = .stopped
    }
}
