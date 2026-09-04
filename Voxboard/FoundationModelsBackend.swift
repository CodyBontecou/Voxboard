import Foundation
import FoundationModels
import VoxboardShared

/// `LLMBackend` backed by Apple's on-device Foundation Models framework.
///
/// Lives in the app targets only — FoundationModels is out of the
/// keyboard extension's memory budget and rate-limited in extensions.
///
/// Availability: iOS 26+ / macOS 26+ on Apple Intelligence-capable devices
/// with Apple Intelligence enabled. Callers should check `isAvailable` before
/// constructing the enricher; `complete` / `enrichNative` throw `.unavailable`
/// otherwise.
///
/// Structured output: overrides `enrichNative(rawText:)` to use `@Generable`
/// guided generation, which guarantees well-formed output. The string path
/// (`complete(prompt:)`) also runs against the same session but is only
/// used as a fallback when `TranscriptEnricher` can't or won't use native.
@available(iOS 26, macOS 26, *)
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

    /// Picks the best smart folder for a transcript.
    /// Returns the zero-based index into `folders`, or nil when none is a good fit.
    func routeToFolder(transcript: VoxboardShared.Transcript, folders: [SmartFolder]) async throws -> Int? {
        guard !folders.isEmpty else { return nil }
        let session = try makeSession(instructions: Self.routingInstructions)
        let prompt = Self.routingPrompt(transcript: transcript, folders: folders)
        let response = try await session.respond(to: prompt, generating: FolderSelection.self)
        let index = response.content.folderIndex
        guard index >= 0 && index < folders.count else { return nil }
        return index
    }

    /// Generates a folder name for auto-organize mode.
    /// Reuses an existing folder when the content fits; creates a new name otherwise.
    /// Returns nil when the model output is unusable.
    func generateFolderName(
        transcript: VoxboardShared.Transcript,
        existingFolders: [String]
    ) async throws -> String? {
        let session = try makeSession(instructions: Self.autoOrganizeInstructions)
        let prompt = Self.autoOrganizePrompt(transcript: transcript, existingFolders: existingFolders)
        let response = try await session.respond(to: prompt, generating: GeneratedFolderName.self)
        let name = Self.sanitizeFolderName(response.content.name)
        return name.isEmpty ? nil : name
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

    private static let autoOrganizeInstructions = """
    You organize voice transcriptions into folders. Given a transcript and a list \
    of existing folder names, choose the most appropriate existing folder when the \
    content clearly fits, or invent a concise new name. Use 1–3 lowercase words \
    separated by hyphens. Never use special characters or spaces.
    """

    private static func autoOrganizePrompt(
        transcript: VoxboardShared.Transcript,
        existingFolders: [String]
    ) -> String {
        let text = transcript.cleanedText ?? transcript.text
        let titleLine = transcript.title.map { "Title: \($0)\n" } ?? ""
        let tagsLine = transcript.tags.map { "Tags: \($0.joined(separator: ", "))\n" } ?? ""
        let categoryLine = transcript.category.map { "Category: \($0)\n" } ?? ""
        let folderSection = existingFolders.isEmpty
            ? "No existing folders — create a new one."
            : "Existing folders (reuse if appropriate): \(existingFolders.joined(separator: ", "))"

        return """
        \(titleLine)\(tagsLine)\(categoryLine)Transcript: \"\"\"\(text)\"\"\"

        \(folderSection)
        """
    }

    private static func sanitizeFolderName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return raw
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalid)
            .joined()
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    private static let routingInstructions = """
    You route voice transcriptions to the most appropriate folder based on the \
    transcript content and folder descriptions. Choose the folder whose description \
    best matches the transcript's topic and intent. Return -1 if no folder is a \
    reasonable match.
    """

    private static func routingPrompt(transcript: VoxboardShared.Transcript, folders: [SmartFolder]) -> String {
        let folderList = folders.enumerated().map { index, folder in
            "[\(index)] \(folder.name): \(folder.folderDescription)"
        }.joined(separator: "\n")

        let text = transcript.cleanedText ?? transcript.text
        let titleLine = transcript.title.map { "Title: \($0)\n" } ?? ""
        let tagsLine = transcript.tags.map { "Tags: \($0.joined(separator: ", "))\n" } ?? ""

        return """
        Transcript:
        \(titleLine)\(tagsLine)\"\"\"\(text)\"\"\"

        Folders:
        \(folderList)
        """
    }

    private static let systemInstructions = """
    You organize text for a private, local-first capture app. The text may be \
    typed Markdown, an on-device speech transcript, or OCR from a document. \
    Produce a title, single-word tags (no spaces; hyphens allowed), a category, \
    and a cleaned version. Preserve existing Markdown structure and the author's \
    meaning — never add information that wasn't in the original.
    """

    private static func userPrompt(rawText: String) -> String {
        """
        Captured text:
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
@available(iOS 26, macOS 26, *)
@Generable
private struct GeneratedEnrichment {
    @Guide(description: "A short descriptive title, at most 6 words, without surrounding quotation marks")
    let title: String

    @Guide(description: "0 to 5 lowercase single-word tags describing the content (no spaces; hyphens allowed for compound words like app-dev)")
    let tags: [String]

    @Guide(description: "The single best category for this captured text")
    let category: GeneratedCategory

    @Guide(description: "The captured text cleaned up while preserving meaning and existing Markdown structure. Return plain text only — never wrap it in quotes, braces, code fences, or JSON syntax")
    let cleanedText: String
}

@available(iOS 26, macOS 26, *)
@Generable
private struct GeneratedFolderName {
    @Guide(description: "1–3 lowercase words separated by hyphens. Reuse an existing folder name when the content fits, otherwise invent a new one. Examples: app-dev, meeting-notes, ideas, personal-journal")
    let name: String
}

@available(iOS 26, macOS 26, *)
@Generable
private struct FolderSelection {
    @Guide(description: "Zero-based index of the best matching folder, or -1 if no folder is appropriate")
    let folderIndex: Int
}

@available(iOS 26, macOS 26, *)
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
