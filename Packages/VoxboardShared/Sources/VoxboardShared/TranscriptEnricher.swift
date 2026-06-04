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

    public func enrich(rawText: String, flow: RecordingFlow? = nil) async throws -> TranscriptEnrichment {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptEnricherError.emptyInput
        }

        // Prefer the backend's native structured-generation path when this is
        // a plain cleanup flow. For flow-specific formatting (todo checkboxes,
        // meeting notes, or custom instructions), force the prompt path so the
        // flow instruction can shape `cleanedText`.
        if !Self.requiresPromptDrivenFormatting(flow),
           let native = try await backend.enrichNative(rawText: trimmed) {
            return Self.applyFlowDefaults(Self.normalize(native), flow: flow)
        }

        // Fallback: string-based path with tolerant JSON extraction.
        let prompt = Self.buildPrompt(rawText: trimmed, flow: flow)
        let response = try await backend.complete(prompt: prompt)
        return Self.applyFlowDefaults(try Self.parse(response: response), flow: flow)
    }

    /// Snap a free-form category to the fixed taxonomy and enforce the
    /// single-word tag contract on the tags array. Used for the native path
    /// where the backend may return anything; `parse(response:)` applies the
    /// same rules for the string path.
    private static func normalize(_ enrichment: TranscriptEnrichment) -> TranscriptEnrichment {
        let category = allowedCategories.contains(enrichment.category) ? enrichment.category : "other"
        return TranscriptEnrichment(
            title: enrichment.title,
            tags: normalizeTags(enrichment.tags),
            category: category,
            cleanedText: enrichment.cleanedText
        )
    }

    private static func requiresPromptDrivenFormatting(_ flow: RecordingFlow?) -> Bool {
        guard let flow else { return false }
        switch flow.postProcessingMode {
        case .todoList, .meetingNotes, .custom:
            return flow.resolvedPostProcessingInstruction != nil
        case .none, .clean:
            return false
        }
    }

    private static func applyFlowDefaults(_ enrichment: TranscriptEnrichment, flow: RecordingFlow?) -> TranscriptEnrichment {
        guard let flow else { return enrichment }
        let tags = TranscriptFlowFormatter.mergeTags(enrichment.tags, flow.staticTags)
        let category = enrichment.category == "other" ? (flow.staticCategory ?? enrichment.category) : enrichment.category
        return TranscriptEnrichment(
            title: enrichment.title,
            tags: tags,
            category: category,
            cleanedText: enrichment.cleanedText
        )
    }

    /// Collapse free-form tags into the single-word contract used by the UI:
    /// split each tag on whitespace, lowercase, drop empties, dedupe while
    /// preserving order, and cap at 5. Hyphenated tokens ("app-dev") are
    /// kept intact — only whitespace breaks a tag into multiple words.
    static func normalizeTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in raw {
            let words = tag.split(whereSeparator: { $0.isWhitespace })
            for word in words {
                let lower = word.lowercased()
                guard !lower.isEmpty, seen.insert(lower).inserted else { continue }
                out.append(lower)
                if out.count == 5 { return out }
            }
        }
        return out
    }

    /// Run enrichment on a transcript and write the enriched copy back to the store.
    /// Never throws — any backend or parse failure is swallowed, and the record
    /// is left as-is (per the agreed failure policy: fields stay nil). The caller
    /// is responsible for deciding when to invoke this (e.g., only after a
    /// foreground save, only when the feature is enabled).
    public func enrichAndUpdate(transcript: Transcript, flow: RecordingFlow? = nil, into store: TranscriptStore) async {
        let log = KeyboardDebugLog.shared
        let shortId = String(transcript.id.uuidString.prefix(8))
        log.log("[Enrichment] start id=\(shortId) flow=\(flow?.id ?? "none") chars=\(transcript.text.count)")
        do {
            let enrichment = try await enrich(rawText: transcript.text, flow: flow)
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

    static func buildPrompt(rawText: String, flow: RecordingFlow? = nil) -> String {
        let categoryList = allowedCategories.joined(separator: ", ")
        let flowInstruction = flow?.resolvedPostProcessingInstruction
        let flowLine = flow.map { "\nWorkflow: \($0.displayName)" } ?? ""
        let staticTags = flow?.staticTags ?? []
        let staticTagLine = staticTags.isEmpty ? "" : "\nPrefer including these tags when relevant: \(staticTags.joined(separator: ", "))"
        let staticCategoryLine = flow?.staticCategory.map { "\nPrefer this category when appropriate: \($0)" } ?? ""
        let cleanedTextInstruction = flowInstruction.map {
            "For \"cleanedText\": \($0) Preserve the speaker's meaning and do not add information that was not in the original."
        } ?? "For \"cleanedText\": rewrite the transcript with proper casing, punctuation, and filler words removed; preserve the speaker's meaning verbatim and do not add information that was not in the original."

        return """
        You are labeling a short voice transcription for a local voice-notes app. \
        The raw text was produced by an automatic speech recognizer and may contain \
        disfluencies, missing punctuation, and lowercase text.\(flowLine)\(staticTagLine)\(staticCategoryLine)

        Return ONLY a single JSON object — no prose, no markdown fences — with these keys:
          - "title": a short descriptive title (max 6 words)
          - "tags": an array of 0–5 lowercase single-word tags (no spaces; hyphens allowed for compound words like "app-dev")
          - "category": exactly one of [\(categoryList)]
          - "cleanedText": \(cleanedTextInstruction)

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

        return normalize(
            TranscriptEnrichment(
                title: raw.title,
                tags: raw.tags,
                category: raw.category,
                cleanedText: raw.cleanedText
            )
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
