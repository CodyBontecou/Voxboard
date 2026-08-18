import Foundation
import Testing
import VoxboardCaptureCore
@testable import VoxboardShared

/// A backend whose `enrichNative` never returns on its own — it only wakes on
/// cancellation, simulating a stalled on-device model session (#11).
private struct HangingLLMBackend: LLMBackend {
    func complete(prompt: String) async throws -> String {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CancellationError()
    }

    func enrichNative(rawText: String) async throws -> TranscriptEnrichment? {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CancellationError()
    }
}

private struct ImmediateLLMBackend: LLMBackend {
    func complete(prompt: String) async throws -> String { "{}" }

    func enrichNative(rawText: String) async throws -> TranscriptEnrichment? {
        TranscriptEnrichment(title: "T", tags: ["a"], category: "note", cleanedText: "Cleaned: \(rawText)")
    }
}

@Suite("EnrichedCapturePresetTextProcessor timeouts")
struct EnrichedCapturePresetTextProcessorTimeoutTests {

    @Test("Stalled model session falls back to raw text within the deadline")
    func stalledEnrichmentFallsBackToRawText() async throws {
        let processor = EnrichedCapturePresetTextProcessor(
            enricher: TranscriptEnricher(backend: HangingLLMBackend()),
            timeout: 0.2
        )
        let profile = CapturePresetProfile(
            id: "test",
            name: "Test",
            symbolName: "note.text",
            postProcessingMode: .clean,
            captureProcessingEnabled: true
        )

        let started = Date()
        let result = try await processor.process(text: "raw note", profile: profile)
        let elapsed = Date().timeIntervalSince(started)

        #expect(result.text == "raw note")
        #expect(result.title == nil)
        #expect(result.tags.isEmpty)
        #expect(result.category == nil)
        #expect(elapsed < 10, "must return near the 0.2s deadline, not hang")
    }

    @Test("Fast enrichment is unaffected by the deadline")
    func fastEnrichmentPassesThrough() async throws {
        let processor = EnrichedCapturePresetTextProcessor(
            enricher: TranscriptEnricher(backend: ImmediateLLMBackend()),
            timeout: 5
        )
        let profile = CapturePresetProfile(
            id: "test",
            name: "Test",
            symbolName: "note.text",
            postProcessingMode: .clean,
            captureProcessingEnabled: true
        )

        let result = try await processor.process(text: "raw note", profile: profile)
        #expect(result.text == "Cleaned: raw note")
        #expect(result.title == "T")
    }

    @Test("Backend errors still propagate (timeout must not mask failures)")
    func backendErrorsPropagate() async throws {
        struct ExplodingBackend: LLMBackend {
            func complete(prompt: String) async throws -> String {
                throw URLError(.notConnectedToInternet)
            }
        }
        let processor = EnrichedCapturePresetTextProcessor(
            enricher: TranscriptEnricher(backend: ExplodingBackend()),
            timeout: 5
        )
        let profile = CapturePresetProfile(
            id: "test",
            name: "Test",
            symbolName: "note.text",
            postProcessingMode: .clean,
            captureProcessingEnabled: true
        )

        await #expect(throws: URLError.self) {
            _ = try await processor.process(text: "raw note", profile: profile)
        }
    }
}
