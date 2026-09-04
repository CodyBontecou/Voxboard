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

    /// Upper bound for a single enrichment pass. On-device model sessions
    /// can stall indefinitely (resource pressure, mid-request unavailability)
    /// and recording delivery awaits this pass before exporting — the note
    /// must never hang behind the model (#11).
    public static let defaultEnrichmentTimeout: TimeInterval = 120

    private let backend: LLMBackend

    public init(backend: LLMBackend) {
        self.backend = backend
    }

    public func enrich(rawText: String, flow: CapturePreset? = nil) async throws -> TranscriptEnrichment {
        try await enrich(rawText: rawText, profile: flow?.captureProfile)
    }

    public func enrich(
        rawText: String,
        profile: CapturePresetProfile?
    ) async throws -> TranscriptEnrichment {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptEnricherError.emptyInput
        }

        // Prefer native structured generation for plain cleanup. Workflow-
        // specific formatting and diarized transcripts use the prompt path so
        // speaker labels and the selected instruction remain explicit.
        // A *throwing* native backend degrades to the prompt path rather than
        // aborting enrichment: a transient session error should not cost the
        // capture its title/tags when the string path might still succeed.
        if !Self.requiresPromptDrivenFormatting(profile),
           !Self.containsSpeakerLabels(trimmed) {
            do {
                if let native = try await backend.enrichNative(rawText: trimmed) {
                    return Self.applyVoxDefaults(Self.normalize(native), profile: profile)
                }
            } catch {
                KeyboardDebugLog.shared.log("[Enrichment] native generation failed (\(error)); falling back to prompt path")
            }
        }

        let prompt = Self.buildPrompt(rawText: trimmed, profile: profile)
        let response = try await backend.complete(prompt: prompt)
        return Self.applyVoxDefaults(try Self.parse(response: response), profile: profile)
    }

    /// Snap a free-form category to the fixed taxonomy and enforce the
    /// single-word tag contract on the tags array. Used for the native path
    /// where the backend may return anything; `parse(response:)` applies the
    /// same rules for the string path.
    private static func normalize(_ enrichment: TranscriptEnrichment) -> TranscriptEnrichment {
        let category = allowedCategories.contains(enrichment.category) ? enrichment.category : "other"
        return TranscriptEnrichment(
            title: strippingJSONEchoArtifacts(enrichment.title),
            tags: normalizeTags(enrichment.tags),
            category: category,
            cleanedText: strippingJSONEchoArtifacts(enrichment.cleanedText)
        )
    }

    /// Strips JSON-syntax echo artifacts from model-generated text.
    ///
    /// The on-device model occasionally mirrors the JSON it was asked (or
    /// guided) to produce into the string values themselves: the cleaned text
    /// arrives wrapped in quotation marks, or ends with the object's closing
    /// brace. The rules are deliberately conservative so legitimate text
    /// survives: wrappers are only removed when they clearly wrap the whole
    /// value, and braces only when unbalanced (balanced `{...}` pairs, as in
    /// code or LaTeX, are left untouched).
    static func strippingJSONEchoArtifacts(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return text }

        // Whole-value wrappers: triple quotes, straight quotes, smart quotes.
        // A value that is nothing but the wrapper pair ("" or “”) is left alone
        // so stripping can never empty the text.
        let wrappers: [(open: String, close: String)] = [
            ("\"\"\"", "\"\"\""),
            ("\"", "\""),
            ("\u{201C}", "\u{201D}"),
        ]

        // Phases interleave: stripping a stray brace can expose a wrapper
        // ("\"text\"}") and vice versa, so the whole sequence repeats until
        // stable rather than running each phase once.
        var didStrip = true
        while didStrip {
            didStrip = false

            for wrapper in wrappers where result.count > wrapper.open.count + wrapper.close.count {
                guard result.hasPrefix(wrapper.open), result.hasSuffix(wrapper.close) else { continue }
                let stripped = String(
                    result.dropFirst(wrapper.open.count).dropLast(wrapper.close.count)
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !stripped.isEmpty else { continue }
                result = stripped
                didStrip = true
            }

            // Stray braces echoed from the JSON object wrapper — stripped only
            // while unbalanced and only while something would remain.
            if result.hasSuffix("}"), !result.dropLast().contains("{") {
                let stripped = String(result.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty {
                    result = stripped
                    didStrip = true
                }
            }
            if result.hasPrefix("{"), !result.dropFirst().contains("}") {
                let stripped = String(result.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty {
                    result = stripped
                    didStrip = true
                }
            }
        }

        return result
    }

    private static func containsSpeakerLabels(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Speaker "), trimmed.hasSuffix(":") else { return false }
            let number = trimmed.dropFirst("Speaker ".count).dropLast()
            return Int(number) != nil
        }
    }

    private static func requiresPromptDrivenFormatting(_ profile: CapturePresetProfile?) -> Bool {
        guard let profile else { return false }
        switch profile.postProcessingMode {
        case .todoList, .meetingNotes, .custom:
            return profile.resolvedPostProcessingInstruction != nil
        case .none, .clean:
            return false
        }
    }

    private static func applyVoxDefaults(
        _ enrichment: TranscriptEnrichment,
        profile: CapturePresetProfile?
    ) -> TranscriptEnrichment {
        guard let profile else { return enrichment }
        let tags = TranscriptFlowFormatter.mergeTags(enrichment.tags, profile.staticTags)
        let category = enrichment.category == "other"
            ? (profile.staticCategory ?? enrichment.category)
            : enrichment.category
        let cleanedText: String
        switch profile.postProcessingMode {
        case .todoList:
            cleanedText = TranscriptFlowFormatter.formatTodoListPreservingSpeakerLabels(
                enrichment.cleanedText
            )
        case .none, .clean, .meetingNotes, .custom:
            cleanedText = enrichment.cleanedText
        }
        return TranscriptEnrichment(
            title: enrichment.title,
            tags: tags,
            category: category,
            cleanedText: cleanedText
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
                // Tags are lowercase single words by contract; drop any
                // brace/quote characters echoed from the JSON wrapper.
                let lower = word
                    .filter { !"{}\"\u{201C}\u{201D}".contains($0) }
                    .lowercased()
                guard !lower.isEmpty, seen.insert(lower).inserted else { continue }
                out.append(lower)
                if out.count == 5 { return out }
            }
        }
        return out
    }

    /// Run enrichment on a transcript and write the enriched copy back to the store.
    /// Never throws — any backend or parse failure is swallowed, and the record
    /// is left as-is (per the agreed failure policy: fields stay nil). A pass
    /// that exceeds `timeout` is cancelled and degrades the same way: the raw
    /// transcript is preserved and the caller's export proceeds, so delivery
    /// never hangs behind a stalled model session (#11).
    public func enrichAndUpdate(
        transcript: Transcript,
        flow: CapturePreset? = nil,
        into store: TranscriptStore,
        timeout: TimeInterval = TranscriptEnricher.defaultEnrichmentTimeout
    ) async {
        let log = KeyboardDebugLog.shared
        let shortId = String(transcript.id.uuidString.prefix(8))
        log.log("[Enrichment] start id=\(shortId) flow=\(flow?.id ?? "none") chars=\(transcript.text.count)")
        let enrichment: TranscriptEnrichment
        do {
            enrichment = try await withRunningTask(timeout: timeout) {
                try await self.enrich(rawText: transcript.text, flow: flow)
            }
        } catch is EnrichmentTimeoutError {
            log.log("[Enrichment] ⏱ id=\(shortId) exceeded its \(Int(timeout))s deadline — keeping the raw transcript so delivery proceeds")
            return
        } catch {
            log.log("[Enrichment] ❌ id=\(shortId) error=\(error)")
            return
        }
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
    }

    // MARK: - Prompt

    static func buildPrompt(rawText: String, flow: CapturePreset? = nil) -> String {
        buildPrompt(rawText: rawText, profile: flow?.captureProfile)
    }

    static func buildPrompt(rawText: String, profile: CapturePresetProfile?) -> String {
        let categoryList = allowedCategories.joined(separator: ", ")
        let flowInstruction = profile?.resolvedPostProcessingInstruction
        let flowLine = profile.map { "\nWorkflow: \($0.displayName)" } ?? ""
        let staticTags = profile?.staticTags ?? []
        let staticTagLine = staticTags.isEmpty ? "" : "\nPrefer including these tags when relevant: \(staticTags.joined(separator: ", "))"
        let staticCategoryLine = profile?.staticCategory.map { "\nPrefer this category when appropriate: \($0)" } ?? ""
        let speakerInstruction = containsSpeakerLabels(rawText)
            ? " Preserve every anonymous `Speaker N:` label and keep each statement with its original speaker."
            : ""
        let noSyntaxEchoLine = " Return only the plain text itself — never wrap it in quotation marks, braces, code fences, or JSON syntax."
        let cleanedTextInstruction = flowInstruction.map {
            "For \"cleanedText\": \($0) Preserve the author's meaning and do not add information that was not in the original.\(speakerInstruction)\(noSyntaxEchoLine)"
        } ?? "For \"cleanedText\": improve casing and punctuation while preserving meaning and existing Markdown structure; do not add information that was not in the original.\(speakerInstruction)\(noSyntaxEchoLine)"

        return """
        You are organizing text for a private, local-first capture app. The text may \
        be typed Markdown, an on-device voice transcription, or OCR extracted from a \
        document. Preserve existing Markdown structure unless the workflow explicitly \
        asks for a different structure.\(flowLine)\(staticTagLine)\(staticCategoryLine)

        Return ONLY a single JSON object — no prose, no markdown fences — with these keys:
          - "title": a short descriptive title (max 6 words)
          - "tags": an array of 0–5 lowercase single-word tags (no spaces; hyphens allowed for compound words like "app-dev")
          - "category": exactly one of [\(categoryList)]
          - "cleanedText": \(cleanedTextInstruction)

        Captured text:
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
