import FluidAudio
import Foundation

public struct RecordingVoiceProcessingConfiguration: Codable, Equatable, Sendable {
    public let presetID: String
    public let speakerDiarizationEnabled: Bool

    public init(presetID: String, speakerDiarizationEnabled: Bool) {
        self.presetID = presetID
        self.speakerDiarizationEnabled = speakerDiarizationEnabled
    }

    public init(preset: CapturePreset) {
        self.init(
            presetID: preset.id,
            speakerDiarizationEnabled: preset.speakerDiarizationEnabled
        )
    }
}

public enum SpeakerDiarizationSkipReason: String, Codable, Equatable, Sendable {
    case timestampsUnavailable
    case incompleteTimestamps
    case noSpeakersDetected
    case storageUnavailable
    case modelPreparationFailed
    case processingFailed

    public var displayText: String {
        switch self {
        case .timestampsUnavailable:
            return String(localized: "Speaker identification was skipped because this transcript has no timing information.")
        case .incompleteTimestamps:
            return String(localized: "Speaker identification was skipped because timing information did not cover the complete transcript.")
        case .noSpeakersDetected:
            return String(localized: "Speaker identification was skipped because no distinct speakers were detected.")
        case .storageUnavailable:
            return String(localized: "Speaker identification was skipped because model storage was unavailable.")
        case .modelPreparationFailed:
            return String(localized: "Speaker identification was skipped because its model could not be prepared.")
        case .processingFailed:
            return String(localized: "Speaker identification could not process this recording.")
        }
    }
}

public enum SpeakerDiarizationError: Error, LocalizedError, Equatable, Sendable {
    case timestampsUnavailable
    case incompleteTimestamps
    case noSpeakersDetected
    case storageUnavailable
    case modelPreparationFailed
    case processingFailed

    public var skipReason: SpeakerDiarizationSkipReason {
        switch self {
        case .timestampsUnavailable: .timestampsUnavailable
        case .incompleteTimestamps: .incompleteTimestamps
        case .noSpeakersDetected: .noSpeakersDetected
        case .storageUnavailable: .storageUnavailable
        case .modelPreparationFailed: .modelPreparationFailed
        case .processingFailed: .processingFailed
        }
    }

    public var errorDescription: String? { skipReason.displayText }
}

public struct SpeakerDiarizationOutput: Equatable, Sendable {
    public let turns: [TranscriptSpeakerTurn]

    public init(turns: [TranscriptSpeakerTurn]) {
        self.turns = turns
    }

    public var renderedText: String {
        turns.map { turn in
            "\(turn.speakerLabel):\n\(turn.text)"
        }
        .joined(separator: "\n\n")
    }
}

public struct SpeakerDiarizationResolution: Equatable, Sendable {
    public let text: String
    public let turns: [TranscriptSpeakerTurn]?
    public let skipReason: SpeakerDiarizationSkipReason?

    public init(
        text: String,
        turns: [TranscriptSpeakerTurn]? = nil,
        skipReason: SpeakerDiarizationSkipReason? = nil
    ) {
        self.text = text
        self.turns = turns
        self.skipReason = skipReason
    }
}

protocol OfflineSpeakerDiarizationEngine: Sendable {
    func prepareModels(directory: URL) async throws
    func process(_ url: URL) async throws -> [SpeakerDiarizationSegment]
}

private final class FluidAudioOfflineSpeakerDiarizationEngine: OfflineSpeakerDiarizationEngine, @unchecked Sendable {
    private let manager = OfflineDiarizerManager(config: .init())

    func prepareModels(directory: URL) async throws {
        try await manager.prepareModels(directory: directory)
    }

    func process(_ url: URL) async throws -> [SpeakerDiarizationSegment] {
        let result = try await manager.process(url)
        return result.segments.map {
            SpeakerDiarizationSegment(
                speakerID: $0.speakerId,
                startTime: TimeInterval($0.startTimeSeconds),
                endTime: TimeInterval($0.endTimeSeconds)
            )
        }
    }
}

/// Best-effort on-device speaker identification for completed recordings.
///
/// FluidAudio's URL-based offline pipeline converts and streams through a
/// disk-backed sample source. Model assets download only after a user enables
/// the per-preset opt-in.
public actor SpeakerDiarizationService {
    private let engine: any OfflineSpeakerDiarizationEngine
    private let modelsDirectoryProvider: @Sendable () -> URL?
    private let processingGate = AsyncExclusiveGate()
    private var modelsArePrepared = false

    public init() {
        engine = FluidAudioOfflineSpeakerDiarizationEngine()
        modelsDirectoryProvider = { AppConstants.modelsDirectoryURL }
    }

    init(
        engine: any OfflineSpeakerDiarizationEngine,
        modelsDirectoryProvider: @escaping @Sendable () -> URL?
    ) {
        self.engine = engine
        self.modelsDirectoryProvider = modelsDirectoryProvider
    }

    /// Applies speaker identification when enabled. A non-cancellation failure
    /// is represented as a typed warning while preserving the valid ASR text.
    public func resolve(
        audioURL: URL,
        transcription: OnDeviceTranscriptionResult,
        configuration: RecordingVoiceProcessingConfiguration?
    ) async throws -> SpeakerDiarizationResolution {
        guard configuration?.speakerDiarizationEnabled == true else {
            return SpeakerDiarizationResolution(text: transcription.text)
        }

        do {
            let output = try await diarize(
                audioURL: audioURL,
                transcriptText: transcription.text,
                transcriptionSegments: transcription.segments
            )
            return SpeakerDiarizationResolution(
                text: output.renderedText,
                turns: output.turns
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeakerDiarizationError {
            return SpeakerDiarizationResolution(
                text: transcription.text,
                skipReason: error.skipReason
            )
        } catch {
            Self.logFailure(stage: "resolution", error: error, audioURL: audioURL)
            return SpeakerDiarizationResolution(
                text: transcription.text,
                skipReason: .processingFailed
            )
        }
    }

    public func diarize(
        audioURL: URL,
        transcriptText: String,
        transcriptionSegments: [TimedTranscriptionSegment]
    ) async throws -> SpeakerDiarizationOutput {
        try await processingGate.withExclusiveAccess { [self] in
            try await self.diarizeExclusively(
                audioURL: audioURL,
                transcriptText: transcriptText,
                transcriptionSegments: transcriptionSegments
            )
        }
    }

    private func diarizeExclusively(
        audioURL: URL,
        transcriptText: String,
        transcriptionSegments: [TimedTranscriptionSegment]
    ) async throws -> SpeakerDiarizationOutput {
        try Task.checkCancellation()
        guard !transcriptionSegments.isEmpty else {
            throw SpeakerDiarizationError.timestampsUnavailable
        }
        guard SpeakerDiarizationAttribution.hasCompleteTimestampCoverage(
            transcriptText: transcriptText,
            transcriptionSegments: transcriptionSegments
        ) else {
            throw SpeakerDiarizationError.incompleteTimestamps
        }
        guard let baseDirectory = modelsDirectoryProvider() else {
            throw SpeakerDiarizationError.storageUnavailable
        }
        let modelDirectory = baseDirectory
            .appendingPathComponent("SpeakerDiarization", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: modelDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            try Task.checkCancellation()
            Self.logFailure(stage: "model storage", error: error, audioURL: audioURL)
            throw SpeakerDiarizationError.storageUnavailable
        }

        if !modelsArePrepared {
            do {
                try await engine.prepareModels(directory: modelDirectory)
                modelsArePrepared = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                Self.logFailure(stage: "model preparation", error: error, audioURL: audioURL)
                throw SpeakerDiarizationError.modelPreparationFailed
            }
        }

        try Task.checkCancellation()
        let speakerSegments: [SpeakerDiarizationSegment]
        do {
            speakerSegments = try await engine.process(audioURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            Self.logFailure(stage: "audio processing", error: error, audioURL: audioURL)
            throw SpeakerDiarizationError.processingFailed
        }
        try Task.checkCancellation()
        let turns = SpeakerDiarizationAttribution.turns(
            transcriptionSegments: transcriptionSegments,
            speakerSegments: speakerSegments
        )
        guard !turns.isEmpty else {
            throw SpeakerDiarizationError.noSpeakersDetected
        }
        return SpeakerDiarizationOutput(turns: turns)
    }

    private nonisolated static func logFailure(stage: String, error: Error, audioURL: URL) {
        KeyboardDebugLog.shared.log(
            "[SpeakerDiarizationService] \(stage) failed for \(audioURL.lastPathComponent): \(String(reflecting: error))"
        )
    }
}

struct SpeakerDiarizationSegment: Equatable, Sendable {
    let speakerID: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum SpeakerDiarizationAttribution {
    static func hasCompleteTimestampCoverage(
        transcriptText: String,
        transcriptionSegments: [TimedTranscriptionSegment]
    ) -> Bool {
        let nonemptySegments = transcriptionSegments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !nonemptySegments.isEmpty,
              nonemptySegments.allSatisfy({
                  $0.startTime.isFinite
                      && $0.endTime.isFinite
                      && $0.endTime > $0.startTime
              }) else {
            return false
        }
        let complete = normalizedCoverageText(transcriptText)
        let timed = normalizedCoverageText(nonemptySegments.map(\.text).joined())
        return !complete.isEmpty && complete == timed
    }

    static func turns(
        transcriptionSegments: [TimedTranscriptionSegment],
        speakerSegments: [SpeakerDiarizationSegment]
    ) -> [TranscriptSpeakerTurn] {
        let textSegments = transcriptionSegments
            .filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.startTime.isFinite
                    && $0.endTime.isFinite
                    && $0.endTime > $0.startTime
            }
            .sorted {
                if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
                return $0.startTime < $1.startTime
            }
        let speakers = speakerSegments.filter {
            !$0.speakerID.isEmpty
                && $0.startTime.isFinite
                && $0.endTime.isFinite
                && $0.endTime > $0.startTime
        }
        guard !textSegments.isEmpty, !speakers.isEmpty else { return [] }

        var speakerIndices: [String: Int] = [:]
        var turns: [TranscriptSpeakerTurn] = []

        for textSegment in textSegments {
            let midpoint = (textSegment.startTime + textSegment.endTime) / 2
            guard let best = speakers.max(by: { left, right in
                score(left, for: textSegment, midpoint: midpoint)
                    < score(right, for: textSegment, midpoint: midpoint)
            }) else { continue }

            let speaker = speakerIndices[best.speakerID] ?? {
                let next = speakerIndices.count
                speakerIndices[best.speakerID] = next
                return next
            }()
            let piece = textSegment.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if let last = turns.last, last.speaker == speaker {
                turns[turns.count - 1] = TranscriptSpeakerTurn(
                    id: last.id,
                    speaker: speaker,
                    text: joining(last.text, piece),
                    startTime: min(last.startTime, textSegment.startTime),
                    endTime: max(last.endTime, textSegment.endTime)
                )
            } else {
                turns.append(TranscriptSpeakerTurn(
                    speaker: speaker,
                    text: piece,
                    startTime: textSegment.startTime,
                    endTime: textSegment.endTime
                ))
            }
        }
        return turns
    }

    private static func score(
        _ speaker: SpeakerDiarizationSegment,
        for text: TimedTranscriptionSegment,
        midpoint: TimeInterval
    ) -> Double {
        let overlap = max(
            0,
            min(text.endTime, speaker.endTime) - max(text.startTime, speaker.startTime)
        )
        if overlap > 0 { return 1_000 + overlap }
        let speakerMidpoint = (speaker.startTime + speaker.endTime) / 2
        return -abs(midpoint - speakerMidpoint)
    }

    private static func normalizedCoverageText(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
        .folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
    }

    private static func joining(_ existing: String, _ next: String) -> String {
        guard !existing.isEmpty else { return next }
        guard !next.isEmpty else { return existing }
        if existing.last?.isWhitespace == true || next.first?.isWhitespace == true {
            return existing + next
        }
        if let first = next.first,
           CharacterSet(charactersIn: ".,!?;:%)]}’'").contains(first.unicodeScalars.first!) {
            return existing + next
        }
        return existing + " " + next
    }
}
