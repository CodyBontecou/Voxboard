import Foundation

/// A single voice transcription record, persisted as JSON in the App Group container.
public struct Transcript: Identifiable, Codable, Sendable {
    public let id: UUID
    public let text: String
    public let date: Date
    public let duration: TimeInterval
    public let modelUsed: String
    public let language: String

    public init(text: String, duration: TimeInterval, modelUsed: String, language: String) {
        self.id = UUID()
        self.text = text
        self.date = Date()
        self.duration = duration
        self.modelUsed = modelUsed
        self.language = language
    }
}
