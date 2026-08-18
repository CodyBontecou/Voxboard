import Foundation
import Testing
@testable import VoxboardShared

/// A backend whose model calls never return on their own — they only wake on
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

/// Recording delivery awaits `enrichAndUpdate` before exporting a voice
/// capture. A stalled FoundationModels session must degrade to the raw
/// transcript at the deadline instead of hanging the capture (#11).
@Suite("TranscriptEnricher.enrichAndUpdate timeouts")
struct TranscriptEnricherTimeoutTests {

    @Test("Stalled model session keeps the raw transcript within the deadline")
    func stalledEnrichmentKeepsRawTranscript() async throws {
        let enricher = TranscriptEnricher(backend: HangingLLMBackend())
        let store = TranscriptStore(fileURL: nil)
        let original = Transcript(
            text: "raw voice transcript",
            duration: 3.0,
            modelUsed: "tiny",
            language: "en"
        )
        store.add(original)

        let started = Date()
        await enricher.enrichAndUpdate(transcript: original, into: store, timeout: 0.2)
        let elapsed = Date().timeIntervalSince(started)

        #expect(store.transcripts.count == 1)
        #expect(store.transcripts[0].id == original.id)
        #expect(store.transcripts[0].text == "raw voice transcript")
        #expect(store.transcripts[0].title == nil)
        #expect(store.transcripts[0].tags == nil)
        #expect(store.transcripts[0].category == nil)
        #expect(store.transcripts[0].cleanedText == nil)
        #expect(elapsed < 10, "must return near the 0.2s deadline, not hang")
    }

    @Test("Fast enrichment is unaffected by the deadline")
    func fastEnrichmentStillApplies() async throws {
        let enricher = TranscriptEnricher(
            backend: ImmediateNativeBackend(cleanedText: "Cleaned voice text.")
        )
        let store = TranscriptStore(fileURL: nil)
        let original = Transcript(
            text: "raw voice transcript",
            duration: 3.0,
            modelUsed: "tiny",
            language: "en"
        )
        store.add(original)

        await enricher.enrichAndUpdate(transcript: original, into: store, timeout: 30)

        #expect(store.transcripts[0].title == "T")
        #expect(store.transcripts[0].cleanedText == "Cleaned voice text.")
    }

    @Test("Default deadline bounds the call for production callers")
    func defaultDeadlineIsBounded() {
        #expect(TranscriptEnricher.defaultEnrichmentTimeout > 0)
        #expect(
            TranscriptEnricher.defaultEnrichmentTimeout
                <= EnrichedCapturePresetTextProcessor.defaultTimeout,
            "voice delivery must not wait longer than the typed-text deadline"
        )
    }
}

private struct ImmediateNativeBackend: LLMBackend {
    let cleanedText: String

    func complete(prompt: String) async throws -> String { "{}" }

    func enrichNative(rawText: String) async throws -> TranscriptEnrichment? {
        TranscriptEnrichment(title: "T", tags: ["a"], category: "note", cleanedText: cleanedText)
    }
}
