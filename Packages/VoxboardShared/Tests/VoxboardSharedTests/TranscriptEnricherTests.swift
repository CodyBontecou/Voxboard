import XCTest
@testable import VoxboardShared

final class TranscriptEnricherTests: XCTestCase {

    // MARK: - Happy path

    func test_enrich_parsesWellFormedJSONResponse() async throws {
        let backend = FakeLLMBackend(response: #"""
        {
          "title": "Grocery List",
          "tags": ["shopping", "food"],
          "category": "task",
          "cleanedText": "Buy milk, eggs, and bread."
        }
        """#)
        let enricher = TranscriptEnricher(backend: backend)

        let result = try await enricher.enrich(rawText: "buy milk eggs and bread")

        XCTAssertEqual(result.title, "Grocery List")
        XCTAssertEqual(result.tags, ["shopping", "food"])
        XCTAssertEqual(result.category, "task")
        XCTAssertEqual(result.cleanedText, "Buy milk, eggs, and bread.")
    }

    func test_enrich_stripsMarkdownCodeFences() async throws {
        let backend = FakeLLMBackend(response: #"""
        Sure! Here's the JSON:
        ```json
        {
          "title": "Meeting Notes",
          "tags": ["work"],
          "category": "meeting",
          "cleanedText": "Discussed Q2 goals."
        }
        ```
        Let me know if you need anything else.
        """#)
        let enricher = TranscriptEnricher(backend: backend)

        let result = try await enricher.enrich(rawText: "discussed q2 goals")

        XCTAssertEqual(result.title, "Meeting Notes")
        XCTAssertEqual(result.category, "meeting")
    }

    func test_enrich_passesRawTextToBackendPrompt() async throws {
        let backend = FakeLLMBackend(response: #"""
        {"title": "X", "tags": [], "category": "note", "cleanedText": "x"}
        """#)
        let enricher = TranscriptEnricher(backend: backend)

        _ = try await enricher.enrich(rawText: "um so the thing is")

        XCTAssertTrue(
            backend.lastPrompt?.contains("um so the thing is") == true,
            "prompt should include the raw transcript text"
        )
    }

    // MARK: - Tag normalization (single-word enforcement)

    func test_enrich_splitsMultiWordTagsIntoSingleWords_stringPath() async throws {
        let backend = FakeLLMBackend(response: #"""
        {
          "title": "T",
          "tags": ["grocery shopping", "food"],
          "category": "note",
          "cleanedText": "x"
        }
        """#)
        let enricher = TranscriptEnricher(backend: backend)

        let result = try await enricher.enrich(rawText: "x")

        XCTAssertEqual(result.tags, ["grocery", "shopping", "food"])
    }

    func test_enrich_splitsMultiWordTagsIntoSingleWords_nativePath() async throws {
        let native = TranscriptEnrichment(
            title: "T",
            tags: ["meeting notes", "q2 planning"],
            category: "note",
            cleanedText: "x"
        )
        let backend = FakeLLMBackend(nativeResponse: native)
        let enricher = TranscriptEnricher(backend: backend)

        let result = try await enricher.enrich(rawText: "x")

        XCTAssertEqual(result.tags, ["meeting", "notes", "q2", "planning"])
    }

    func test_enrich_lowercasesAndDedupesTags() async throws {
        let backend = FakeLLMBackend(response: #"""
        {
          "title": "T",
          "tags": ["Work", "work", "  WORK  "],
          "category": "note",
          "cleanedText": "x"
        }
        """#)
        let enricher = TranscriptEnricher(backend: backend)

        let result = try await enricher.enrich(rawText: "x")

        XCTAssertEqual(result.tags, ["work"])
    }

    func test_enrich_dropsEmptyTagsAndCapsAtFive() async throws {
        let backend = FakeLLMBackend(response: #"""
        {
          "title": "T",
          "tags": ["", "  ", "one two three four", "five", "six"],
          "category": "note",
          "cleanedText": "x"
        }
        """#)
        let enricher = TranscriptEnricher(backend: backend)

        let result = try await enricher.enrich(rawText: "x")

        XCTAssertEqual(result.tags.count, 5)
        XCTAssertEqual(result.tags, ["one", "two", "three", "four", "five"])
    }

    func test_enrich_preservesHyphenatedTagsAsSingleWord() async throws {
        let backend = FakeLLMBackend(response: #"""
        {
          "title": "T",
          "tags": ["app-dev", "machine-learning"],
          "category": "note",
          "cleanedText": "x"
        }
        """#)
        let enricher = TranscriptEnricher(backend: backend)

        let result = try await enricher.enrich(rawText: "x")

        XCTAssertEqual(result.tags, ["app-dev", "machine-learning"])
    }

    // MARK: - Category taxonomy

    func test_enrich_snapsUnknownCategoryToOther() async throws {
        let backend = FakeLLMBackend(response: #"""
        {"title": "Mystery", "tags": [], "category": "quantum-banana", "cleanedText": "x"}
        """#)
        let enricher = TranscriptEnricher(backend: backend)

        let result = try await enricher.enrich(rawText: "x")

        XCTAssertEqual(result.category, "other")
    }

    func test_enrich_acceptsAllKnownCategories() async throws {
        for category in TranscriptEnricher.allowedCategories {
            let backend = FakeLLMBackend(response: #"""
            {"title": "T", "tags": [], "category": "\#(category)", "cleanedText": "c"}
            """#)
            let enricher = TranscriptEnricher(backend: backend)

            let result = try await enricher.enrich(rawText: "x")
            XCTAssertEqual(result.category, category)
        }
    }

    // MARK: - Malformed output

    func test_enrich_throwsOnNonJSONOutput() async {
        let backend = FakeLLMBackend(response: "I'm sorry, I can't help with that.")
        let enricher = TranscriptEnricher(backend: backend)

        do {
            _ = try await enricher.enrich(rawText: "hello")
            XCTFail("expected enrich to throw on malformed output")
        } catch {
            // expected
        }
    }

    func test_enrich_throwsOnMissingRequiredFields() async {
        // missing cleanedText
        let backend = FakeLLMBackend(response: #"""
        {"title": "T", "tags": [], "category": "note"}
        """#)
        let enricher = TranscriptEnricher(backend: backend)

        do {
            _ = try await enricher.enrich(rawText: "hello")
            XCTFail("expected enrich to throw when required fields are missing")
        } catch {
            // expected
        }
    }

    func test_enrich_propagatesBackendErrors() async {
        let backend = FakeLLMBackend(error: FakeLLMError.boom)
        let enricher = TranscriptEnricher(backend: backend)

        do {
            _ = try await enricher.enrich(rawText: "hello")
            XCTFail("expected enrich to rethrow backend error")
        } catch {
            // expected
        }
    }

    // MARK: - Empty input

    func test_enrich_throwsOnEmptyRawText() async {
        let backend = FakeLLMBackend(response: "{}")
        let enricher = TranscriptEnricher(backend: backend)

        do {
            _ = try await enricher.enrich(rawText: "   ")
            XCTFail("expected enrich to reject empty input without invoking backend")
        } catch {
            XCTAssertNil(backend.lastPrompt, "backend should not be called on empty input")
        }
    }

    // MARK: - Flow-specific formatting

    func test_enrich_todoFlowNormalizesDashBulletsToMarkdownCheckboxes() async throws {
        let backend = FakeLLMBackend(
            nativeResponse: TranscriptEnrichment(title: "Native", tags: [], category: "task", cleanedText: "native"),
            response: #"""
            {
              "title": "Apple Intelligence Task",
              "tags": ["task", "apple"],
              "category": "task",
              "cleanedText": "- Ensure Vox on device processing works with Apple Intelligence."
            }
            """#
        )
        var flow = RecordingFlowStore.makeCustomFlow()
        flow.postProcessingMode = .todoList
        let enricher = TranscriptEnricher(backend: backend)

        let result = try await enricher.enrich(rawText: "ensure vox on device processing works with apple intelligence", flow: flow)

        XCTAssertEqual(result.cleanedText, "- [ ] Ensure Vox on device processing works with Apple Intelligence.")
        XCTAssertNotNil(backend.lastPrompt, "todo flows should use the prompt path so the workflow instruction is included")
        XCTAssertNil(backend.lastNativeInput, "todo flows should not use native cleanup because they need flow-specific formatting")
    }

    // MARK: - enrichAndUpdate orchestration

    func test_enrichAndUpdate_writesEnrichedCopyBackToStore() async {
        let backend = FakeLLMBackend(response: #"""
        {
          "title": "Buy Groceries",
          "tags": ["shopping"],
          "category": "task",
          "cleanedText": "Buy milk and eggs."
        }
        """#)
        let enricher = TranscriptEnricher(backend: backend)

        let store = TranscriptStore()
        let original = Transcript(
            text: "buy milk and eggs",
            duration: 1.0,
            modelUsed: "whisper-base",
            language: "en"
        )
        store.add(original)

        await enricher.enrichAndUpdate(transcript: original, into: store)

        XCTAssertEqual(store.transcripts.count, 1)
        XCTAssertEqual(store.transcripts[0].id, original.id)
        XCTAssertEqual(store.transcripts[0].title, "Buy Groceries")
        XCTAssertEqual(store.transcripts[0].tags, ["shopping"])
        XCTAssertEqual(store.transcripts[0].category, "task")
        XCTAssertEqual(store.transcripts[0].cleanedText, "Buy milk and eggs.")
    }

    func test_enrichAndUpdate_leavesStoreUnchangedOnBackendError() async {
        let backend = FakeLLMBackend(error: FakeLLMError.boom)
        let enricher = TranscriptEnricher(backend: backend)

        let store = TranscriptStore()
        let original = Transcript(
            text: "hi",
            duration: 1.0,
            modelUsed: "whisper-base",
            language: "en"
        )
        store.add(original)

        await enricher.enrichAndUpdate(transcript: original, into: store)

        XCTAssertEqual(store.transcripts.count, 1)
        XCTAssertEqual(store.transcripts[0].id, original.id)
        XCTAssertNil(store.transcripts[0].title)
        XCTAssertNil(store.transcripts[0].tags)
        XCTAssertNil(store.transcripts[0].category)
        XCTAssertNil(store.transcripts[0].cleanedText)
    }

    func test_enrichAndUpdate_leavesStoreUnchangedOnMalformedOutput() async {
        let backend = FakeLLMBackend(response: "I'm sorry, I can't help with that.")
        let enricher = TranscriptEnricher(backend: backend)

        let store = TranscriptStore()
        let original = Transcript(
            text: "hi",
            duration: 1.0,
            modelUsed: "whisper-base",
            language: "en"
        )
        store.add(original)

        await enricher.enrichAndUpdate(transcript: original, into: store)

        XCTAssertNil(store.transcripts[0].title)
    }

    // MARK: - Native (guided-generation) path

    func test_enrich_prefersNativeBackendPathWhenAvailable() async throws {
        // Backend provides a native path. The enricher should use it and
        // never invoke the string-based complete(prompt:) path.
        let native = TranscriptEnrichment(
            title: "Native Title",
            tags: ["alpha"],
            category: "note",
            cleanedText: "Clean."
        )
        let backend = FakeLLMBackend(nativeResponse: native)

        let enricher = TranscriptEnricher(backend: backend)
        let result = try await enricher.enrich(rawText: "raw input")

        XCTAssertEqual(result, native)
        XCTAssertNil(backend.lastPrompt, "complete(prompt:) should not be called when native path returns a value")
        XCTAssertEqual(backend.lastNativeInput, "raw input")
    }

    func test_enrich_fallsBackToStringPathWhenNativeReturnsNil() async throws {
        // Backend's native path returns nil (not supported for this input).
        // The enricher should fall through to complete(prompt:) + parse.
        let backend = FakeLLMBackend(
            nativeResponse: nil,
            response: #"""
            {"title": "String Path", "tags": [], "category": "note", "cleanedText": "x"}
            """#
        )
        let enricher = TranscriptEnricher(backend: backend)

        let result = try await enricher.enrich(rawText: "raw input")

        XCTAssertEqual(result.title, "String Path")
        XCTAssertNotNil(backend.lastPrompt, "fallback path must call complete(prompt:)")
    }

    func test_enrich_defaultBackendExtensionReturnsNilForNative() async throws {
        // FakeLLMBackend opts in to the native path explicitly. A backend that
        // doesn't override enrichNative should get the default nil and fall
        // through to the string path. This guards the protocol extension.
        let stringOnly = StringOnlyFakeBackend(response: #"""
        {"title": "Default", "tags": [], "category": "note", "cleanedText": "x"}
        """#)
        let enricher = TranscriptEnricher(backend: stringOnly)

        let result = try await enricher.enrich(rawText: "raw")

        XCTAssertEqual(result.title, "Default")
        XCTAssertNotNil(stringOnly.lastPrompt)
    }

    func test_enrich_stillRejectsEmptyInputWhenNativePathExists() async {
        let native = TranscriptEnrichment(title: "x", tags: [], category: "note", cleanedText: "x")
        let backend = FakeLLMBackend(nativeResponse: native)
        let enricher = TranscriptEnricher(backend: backend)

        do {
            _ = try await enricher.enrich(rawText: "   ")
            XCTFail("expected emptyInput error")
        } catch {
            XCTAssertNil(backend.lastNativeInput, "backend should not be called on empty input")
        }
    }
}

// MARK: - Fakes

private final class FakeLLMBackend: LLMBackend, @unchecked Sendable {
    private let response: String?
    private let error: Error?
    private let nativeResponse: TranscriptEnrichment?
    private(set) var lastPrompt: String?
    private(set) var lastNativeInput: String?

    /// String-path only.
    init(response: String) {
        self.response = response
        self.error = nil
        self.nativeResponse = nil
    }

    /// String-path only, throws from complete(prompt:).
    init(error: Error) {
        self.response = nil
        self.error = error
        self.nativeResponse = nil
    }

    /// Native path returns the given enrichment. If `response` is provided,
    /// the string path also works (used to assert native is preferred).
    init(nativeResponse: TranscriptEnrichment?, response: String? = nil) {
        self.response = response
        self.error = nil
        self.nativeResponse = nativeResponse
    }

    func complete(prompt: String) async throws -> String {
        lastPrompt = prompt
        if let error { throw error }
        return response ?? ""
    }

    func enrichNative(rawText: String) async throws -> TranscriptEnrichment? {
        lastNativeInput = rawText
        return nativeResponse
    }
}

/// A backend that only implements the string path (uses the default
/// `enrichNative` from the protocol extension). Guards the fall-through.
private final class StringOnlyFakeBackend: LLMBackend, @unchecked Sendable {
    private let response: String
    private(set) var lastPrompt: String?

    init(response: String) {
        self.response = response
    }

    func complete(prompt: String) async throws -> String {
        lastPrompt = prompt
        return response
    }
}

private enum FakeLLMError: Error {
    case boom
}
