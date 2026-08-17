import Foundation

/// A contiguous piece of a transcript attributed to one anonymous speaker.
/// Speaker indices are zero-based in storage and rendered as “Speaker 1”,
/// “Speaker 2”, and so on.
public struct TranscriptSpeakerTurn: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let speaker: Int
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    /// Optional provenance added for multi-stem meeting recordings. Nil decodes
    /// legacy anonymous diarization turns without changing their rendering.
    public let role: TranscriptSpeakerRole?
    public let displayLabel: String?

    public init(
        id: UUID = UUID(),
        speaker: Int,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        role: TranscriptSpeakerRole? = nil,
        displayLabel: String? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.role = role
        self.displayLabel = displayLabel
    }

    public var speakerLabel: String { displayLabel ?? "Speaker \(speaker + 1)" }
}

/// A single voice transcription record, persisted as JSON in the App Group container.
public struct Transcript: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let date: Date
    public let duration: TimeInterval
    public let modelUsed: String
    public let language: String
    /// Present only when the user opted into local speaker identification and
    /// the best-effort diarization pass completed successfully.
    public let speakerTurns: [TranscriptSpeakerTurn]?
    /// A durable, nonfatal explanation when opted-in speaker identification
    /// preserved the valid raw transcript instead of adding labels.
    public let speakerDiarizationSkipReason: SpeakerDiarizationSkipReason?

    // MARK: - On-device LLM enrichment (optional)
    //
    // These fields are populated asynchronously by TranscriptEnricher after the
    // raw whisper text is saved. They remain nil for records created before the
    // feature existed, for records the user has not yet re-opened, and whenever
    // enrichment is disabled or fails.

    public let title: String?
    public let tags: [String]?
    public let category: String?
    public let cleanedText: String?

    public init(text: String, duration: TimeInterval, modelUsed: String, language: String) {
        self.init(
            id: UUID(),
            text: text,
            date: Date(),
            duration: duration,
            modelUsed: modelUsed,
            language: language
        )
    }

    /// Creates a transcript with identity supplied by its capture source.
    /// Apple Watch imports use the recording UUID and original recording date so
    /// retries update one durable transcript and one Capture request.
    public init(
        id: UUID,
        text: String,
        date: Date,
        duration: TimeInterval,
        modelUsed: String,
        language: String,
        speakerTurns: [TranscriptSpeakerTurn]? = nil,
        speakerDiarizationSkipReason: SpeakerDiarizationSkipReason? = nil,
        title: String? = nil,
        tags: [String]? = nil,
        category: String? = nil,
        cleanedText: String? = nil
    ) {
        self.id = id
        self.text = text
        self.date = date
        self.duration = duration
        self.modelUsed = modelUsed
        self.language = language
        self.speakerTurns = speakerTurns
        self.speakerDiarizationSkipReason = speakerDiarizationSkipReason
        self.title = title
        self.tags = tags
        self.category = category
        self.cleanedText = cleanedText
    }

    /// Returns a copy with user-edited text and metadata while preserving the
    /// recording identity, date, duration, model, and language.
    public func withEdits(
        text: String,
        title: String?,
        tags: [String]?,
        category: String?,
        cleanedText: String?
    ) -> Transcript {
        Transcript(
            id: id,
            text: text,
            date: date,
            duration: duration,
            modelUsed: modelUsed,
            language: language,
            speakerTurns: text == self.text ? speakerTurns : nil,
            speakerDiarizationSkipReason: text == self.text ? speakerDiarizationSkipReason : nil,
            title: title,
            tags: tags,
            category: category,
            cleanedText: cleanedText
        )
    }

    /// Returns a copy with enrichment fields replaced. Identity and raw content
    /// (id, text, date, duration, modelUsed, language) are preserved so that
    /// `TranscriptStore.update` can locate and replace the record by id.
    public func withEnrichment(
        title: String?,
        tags: [String]?,
        category: String?,
        cleanedText: String?
    ) -> Transcript {
        Transcript(
            id: id,
            text: text,
            date: date,
            duration: duration,
            modelUsed: modelUsed,
            language: language,
            speakerTurns: speakerTurns,
            speakerDiarizationSkipReason: speakerDiarizationSkipReason,
            title: title,
            tags: tags,
            category: category,
            cleanedText: cleanedText
        )
    }

    public var speakerCount: Int {
        guard let highest = speakerTurns?.map(\.speaker).max() else { return 0 }
        return highest + 1
    }
}
