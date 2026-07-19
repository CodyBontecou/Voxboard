import Foundation
import VoxboardCaptureCore

/// Bridges the app's on-device enrichment backend into the modality-neutral
/// CaptureCore request processor.
public struct EnrichedCapturePresetTextProcessor: CapturePresetTextProcessing {
    private let enricher: TranscriptEnricher

    public init(enricher: TranscriptEnricher) {
        self.enricher = enricher
    }

    public func process(
        text: String,
        profile: CapturePresetProfile
    ) async throws -> CapturePresetTextProcessingResult {
        let enrichment = try await enricher.enrich(rawText: text, profile: profile)
        return CapturePresetTextProcessingResult(
            text: enrichment.cleanedText,
            title: enrichment.title,
            tags: enrichment.tags,
            category: enrichment.category
        )
    }
}

public typealias EnrichedCaptureVoxTextProcessor = EnrichedCapturePresetTextProcessor
