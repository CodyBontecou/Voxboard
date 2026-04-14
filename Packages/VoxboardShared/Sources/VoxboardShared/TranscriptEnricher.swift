import Foundation

// MARK: - Backend protocol

/// A minimal interface over whatever on-device LLM is producing completions.
/// Kept deliberately tiny so unit tests can inject a fake and the real
/// implementation (backed by Apple's FoundationModels framework) lives in
/// the main app target without pulling `FoundationModels` into this shared
/// package (which is also linked by the keyboard extension).
public protocol LLMBackend: Sendable {
    /// Plain text-completion path. Used when the backend does not support
    /// structured generation, or as a fallback when the native path returns
    /// nil for a particular input. The returned string is expected to contain
    /// JSON matching `TranscriptEnricher`'s schema; `parse(response:)`
    /// tolerates code fences and leading prose.
    func complete(prompt: String) async throws -> String

    /// Optional native structured-generation path. Backends that support
    /// guided generation (e.g., FoundationModels `@Generable`) can override
    /// this and return a fully-formed `TranscriptEnrichment` directly,
    /// bypassing prompt-engineering and string parsing.
    ///
    /// The default implementation returns `nil`, causing `TranscriptEnricher`
    /// to fall back to `complete(prompt:)`. Backends may also return `nil`
    /// for specific inputs where guided generation isn't desirable.
    func enrichNative(rawText: String) async throws -> TranscriptEnrichment?
}

public extension LLMBackend {
    func enrichNative(rawText: String) async throws -> TranscriptEnrichment? {
        nil
    }
}

// MARK: - Output shape

/// The structured enrichment produced for a transcript. Apply to a `Transcript`
/// via `withEnrichment(...)` before writing back to `TranscriptStore`.
public struct TranscriptEnrichment: Sendable, Equatable {
    public let title: String
    public let tags: [String]
    public let category: String
    public let cleanedText: String

    public init(title: String, tags: [String], category: String, cleanedText: String) {
        self.title = title
        self.tags = tags
        self.category = category
        self.cleanedText = cleanedText
    }
}

// MARK: - Enricher

public enum TranscriptEnricherError: Error {
    case emptyInput
    case malformedOutput(String)
}

public struct TranscriptEnricher: Sendable {

    /// Fixed taxonomy. The LLM may propose free-form tags (decision #3), but
    /// categories snap to this list so the UI can filter/color consistently.
    /// Anything the model returns outside the list becomes `"other"`.
    public static let allowedCategories: [String] = [
        "note",
        "idea",
        "task",
        "meeting",
        "journal",
        "message",
        "reminder",
        "other",
    ]

    private let backend: LLMBackend

    public init(backend: LLMBackend) {
        self.backend = backend
    }

    public func enrich(rawText: String) async throws -> TranscriptEnrichment {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptEnricherError.emptyInput
        }

        // Prefer the backend's native structured-generation path when it
        // exposes one (e.g., FoundationModels @Generable). The result is
        // guaranteed well-formed by the framework — no prompt engineering,
        // no parsing.
        if let native = try await backend.enrichNative(rawText: trimmed) {
            return Self.normalizeCategory(in: native)
        }

        // Fallback: string-based path with tolerant JSON extraction.
        let prompt = Self.buildPrompt(rawText: trimmed)
        let response = try await backend.complete(prompt: prompt)
        return try Self.parse(response: response)
    }

    /// Snap a free-form category to the fixed taxonomy, preserving other
    /// fields. Used for the native path where the backend may return any
    /// string; `parse(response:)` applies the same rule for the string path.
    private static func normalizeCategory(in enrichment: TranscriptEnrichment) -> TranscriptEnrichment {
        guard !allowedCategories.contains(enrichment.category) else {
            return enrichment
        }
        return TranscriptEnrichment(
            title: enrichment.title,
            tags: enrichment.tags,
            category: "other",
            cleanedText: enrichment.cleanedText
        )
    }

    /// Run enrichment on a transcript and write the enriched copy back to the store.
    /// Never throws — any backend or parse failure is swallowed, and the record
    /// is left as-is (per the agreed failure policy: fields stay nil). The caller
    /// is responsible for deciding when to invoke this (e.g., only after a
    /// foreground save, only when the feature is enabled).
    public func enrichAndUpdate(transcript: Transcript, into store: TranscriptStore) async {
        let log = KeyboardDebugLog.shared
        let shortId = String(transcript.id.uuidString.prefix(8))
        log.log("[Enrichment] start id=\(shortId) chars=\(transcript.text.count)")
        do {
            let enrichment = try await enrich(rawText: transcript.text)
            let updated = transcript.withEnrichment(
                title: enrichment.title,
                tags: enrichment.tags,
                category: enrichment.category,
                cleanedText: enrichment.cleanedText
            )
            await MainActor.run {
                store.update(updated)
            }
            log.log("[Enrichment] ✅ id=\(shortId) title=\"\(enrichment.title)\" tags=\(enrichment.tags.count) category=\(enrichment.category)")
        } catch {
            log.log("[Enrichment] ❌ id=\(shortId) error=\(error)")
        }
    }

    // MARK: - Prompt

    static func buildPrompt(rawText: String) -> String {
        let categoryList = allowedCategories.joined(separator: ", ")
        return """
        You are labeling a short voice transcription for a local voice-notes app. \
        The raw text was produced by an automatic speech recognizer and may contain \
        disfluencies, missing punctuation, and lowercase text.

        Return ONLY a single JSON object — no prose, no markdown fences — with these keys:
          - "title": a short descriptive title (max 6 words)
          - "tags": an array of 0–5 lowercase freeform tag strings
          - "category": exactly one of [\(categoryList)]
          - "cleanedText": the transcript rewritten with proper casing, punctuation, \
            and filler words removed; preserve the speaker's meaning verbatim, do not \
            add information that was not in the original

        Transcript:
        \"\"\"
        \(rawText)
        \"\"\"
        """
    }

    // MARK: - Parser

    static func parse(response: String) throws -> TranscriptEnrichment {
        guard let jsonSubstring = extractFirstJSONObject(from: response) else {
            throw TranscriptEnricherError.malformedOutput("no JSON object found")
        }

        guard let data = jsonSubstring.data(using: .utf8) else {
            throw TranscriptEnricherError.malformedOutput("could not encode JSON as UTF-8")
        }

        let raw: RawEnrichment
        do {
            raw = try JSONDecoder().decode(RawEnrichment.self, from: data)
        } catch {
            throw TranscriptEnricherError.malformedOutput("JSON decode failed: \(error)")
        }

        let normalizedCategory = allowedCategories.contains(raw.category) ? raw.category : "other"

        return TranscriptEnrichment(
            title: raw.title,
            tags: raw.tags,
            category: normalizedCategory,
            cleanedText: raw.cleanedText
        )
    }

    /// Finds the first balanced `{ ... }` block in the response, tolerating
    /// leading prose and markdown code fences the model may emit.
    private static func extractFirstJSONObject(from response: String) -> String? {
        guard let start = response.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var i = start
        while i < response.endIndex {
            let c = response[i]
            if escape {
                escape = false
            } else if c == "\\" && inString {
                escape = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(response[start...i])
                    }
                }
            }
            i = response.index(after: i)
        }
        return nil
    }

    private struct RawEnrichment: Decodable {
        let title: String
        let tags: [String]
        let category: String
        let cleanedText: String
    }
}
