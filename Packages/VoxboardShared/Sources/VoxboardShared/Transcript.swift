import Foundation

/// A single voice transcription record, persisted as JSON in the App Group container.
public struct Transcript: Identifiable, Codable, Sendable {
    public let id: UUID
    public let text: String
    public let date: Date
    public let duration: TimeInterval
    public let modelUsed: String
    public let language: String

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
            language: language,
            title: nil,
            tags: nil,
            category: nil,
            cleanedText: nil
        )
    }

    private init(
        id: UUID,
        text: String,
        date: Date,
        duration: TimeInterval,
        modelUsed: String,
        language: String,
        title: String?,
        tags: [String]?,
        category: String?,
        cleanedText: String?
    ) {
        self.id = id
        self.text = text
        self.date = date
        self.duration = duration
        self.modelUsed = modelUsed
        self.language = language
        self.title = title
        self.tags = tags
        self.category = category
        self.cleanedText = cleanedText
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
            title: title,
            tags: tags,
            category: category,
            cleanedText: cleanedText
        )
    }
}
