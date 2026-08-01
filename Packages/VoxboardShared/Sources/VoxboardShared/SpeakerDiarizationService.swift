import FluidAudio
import Foundation

public enum SpeakerDiarizationError: Error, LocalizedError, Equatable, Sendable {
    case audioTooLarge
    case timestampsUnavailable
    case incompleteTimestamps
    case noSpeakersDetected
    case storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .audioTooLarge:
            return "The recording is too large for on-device speaker identification."
        case .timestampsUnavailable:
            return "The transcription backend did not return timestamps for speaker identification."
        case .incompleteTimestamps:
            return "The transcription timestamps do not cover the complete transcript."
        case .noSpeakersDetected:
            return "No distinct speakers were detected."
        case .storageUnavailable:
            return "Speaker identification model storage is unavailable."
        }
    }
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

/// Best-effort on-device speaker identification for completed recordings.
///
/// The service mirrors Rescript's mobile pipeline: transcription first provides
/// timed text, Pyannote-style diarization identifies who spoke when, and each
/// text unit is assigned to the overlapping (or nearest) speaker segment. Model
/// assets are downloaded only after a user enables the per-preset opt-in.
public actor SpeakerDiarizationService {
    public static let audioByteLimit: UInt64 = 120 * 1024 * 1024

    private let manager: OfflineDiarizerManager
    private var modelsArePrepared = false
    private var isProcessing = false
    private var processingWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {
        manager = OfflineDiarizerManager(config: .init())
    }

    public func diarize(
        audioURL: URL,
        transcriptText: String,
        transcriptionSegments: [TimedTranscriptionSegment]
    ) async throws -> SpeakerDiarizationOutput {
        await acquireProcessingSlot()
        defer { releaseProcessingSlot() }
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
        guard Self.fileSize(at: audioURL) <= Self.audioByteLimit else {
            throw SpeakerDiarizationError.audioTooLarge
        }
        guard let baseDirectory = AppConstants.modelsDirectoryURL else {
            throw SpeakerDiarizationError.storageUnavailable
        }
        let modelDirectory = baseDirectory
            .appendingPathComponent("SpeakerDiarization", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )

        if !modelsArePrepared {
            try await manager.prepareModels(directory: modelDirectory)
            modelsArePrepared = true
        }

        try Task.checkCancellation()
        let result = try await manager.process(audioURL)
        try Task.checkCancellation()
        let speakerSegments = result.segments.map {
            SpeakerDiarizationSegment(
                speakerID: $0.speakerId,
                startTime: TimeInterval($0.startTimeSeconds),
                endTime: TimeInterval($0.endTimeSeconds)
            )
        }
        let turns = SpeakerDiarizationAttribution.turns(
            transcriptionSegments: transcriptionSegments,
            speakerSegments: speakerSegments
        )
        guard !turns.isEmpty else {
            throw SpeakerDiarizationError.noSpeakersDetected
        }
        return SpeakerDiarizationOutput(turns: turns)
    }

    private func acquireProcessingSlot() async {
        if !isProcessing {
            isProcessing = true
            return
        }
        await withCheckedContinuation { continuation in
            processingWaiters.append(continuation)
        }
    }

    private func releaseProcessingSlot() {
        if processingWaiters.isEmpty {
            isProcessing = false
        } else {
            processingWaiters.removeFirst().resume()
        }
    }

    private nonisolated static func fileSize(at url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
            .uint64Value ?? 0
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
        let complete = normalizedCoverageText(transcriptText)
        let timed = normalizedCoverageText(
            transcriptionSegments.map(\.text).joined()
        )
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
