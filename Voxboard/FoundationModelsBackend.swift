import Foundation
import FoundationModels
import VoxboardShared

/// `LLMBackend` backed by Apple's on-device Foundation Models framework.
///
/// Lives in the main app target only — FoundationModels is out of the
/// keyboard extension's memory budget and rate-limited in extensions.
///
/// Availability: iOS 26+ on Apple Intelligence-capable devices with AI
/// enabled. Callers should check `isAvailable` before constructing the
/// enricher; `complete` / `enrichNative` throw `.unavailable` otherwise.
///
/// Structured output: overrides `enrichNative(rawText:)` to use `@Generable`
/// guided generation, which guarantees well-formed output. The string path
/// (`complete(prompt:)`) also runs against the same session but is only
/// used as a fallback when `TranscriptEnricher` can't or won't use native.
@available(iOS 26, *)
final class FoundationModelsBackend: LLMBackend {

    // MARK: - Availability

    enum BackendError: Error {
        case unavailable(SystemLanguageModel.Availability.UnavailableReason)
    }

    /// True when a session can be created right now. Mirrors
    /// `SystemLanguageModel.default.availability == .available` with a
    /// stable call site for the rest of the app.
    static var isAvailable: Bool {
        switch SystemLanguageModel.default.availability {
        case .available:
            return true
        case .unavailable:
            return false
        }
    }

    // MARK: - LLMBackend

    func complete(prompt: String) async throws -> String {
        let session = try makeSession()
        let response = try await session.respond(to: prompt)
        return response.content
    }

    func enrichNative(rawText: String) async throws -> TranscriptEnrichment? {
        let session = try makeSession(instructions: Self.systemInstructions)
        let response = try await session.respond(
            to: Self.userPrompt(rawText: rawText),
            generating: GeneratedEnrichment.self
        )
        let generated = response.content
        return TranscriptEnrichment(
            title: generated.title,
            tags: generated.tags,
            category: generated.category.rawValue,
            cleanedText: generated.cleanedText
        )
    }

    // MARK: - Session construction

    private func makeSession(instructions: String? = nil) throws -> LanguageModelSession {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw BackendError.unavailable(reason)
        }
        if let instructions {
            return LanguageModelSession(instructions: instructions)
        } else {
            return LanguageModelSession()
        }
    }

    // MARK: - Prompt

    private static let systemInstructions = """
    You label short voice transcriptions for a local voice-notes app. The raw \
    text comes from an automatic speech recognizer and may contain disfluencies, \
    missing punctuation, and lowercase words. You produce a title, free-form \
    tags, a category, and a cleaned version of the transcript. Preserve the \
    speaker's meaning verbatim — never add information that wasn't in the \
    original.
    """

    private static func userPrompt(rawText: String) -> String {
        """
        Transcript:
        \"\"\"
        \(rawText)
        \"\"\"
        """
    }
}

// MARK: - @Generable output

/// The shape the on-device model produces via guided generation. Kept
/// private to the backend so `VoxboardShared` stays FoundationModels-free.
/// Converted to `TranscriptEnrichment` before returning to the enricher.
@available(iOS 26, *)
@Generable
private struct GeneratedEnrichment {
    @Guide(description: "A short descriptive title, at most 6 words")
    let title: String

    @Guide(description: "0 to 5 lowercase free-form tags describing the content")
    let tags: [String]

    @Guide(description: "The single best category for this transcript")
    let category: GeneratedCategory

    @Guide(description: "The transcript rewritten with proper casing and punctuation, filler words removed, meaning preserved verbatim")
    let cleanedText: String
}

@available(iOS 26, *)
@Generable
private enum GeneratedCategory: String {
    case note
    case idea
    case task
    case meeting
    case journal
    case message
    case reminder
    case other
}
