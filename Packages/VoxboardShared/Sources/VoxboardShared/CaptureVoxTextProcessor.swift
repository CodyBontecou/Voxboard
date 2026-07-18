import Foundation
import VoxboardCaptureCore

/// Bridges the app's on-device enrichment backend into the modality-neutral
/// CaptureCore request processor.
public struct EnrichedCaptureVoxTextProcessor: CaptureVoxTextProcessing {
    private let enricher: TranscriptEnricher

    public init(enricher: TranscriptEnricher) {
        self.enricher = enricher
    }

    public func process(
        text: String,
        profile: CaptureVoxProfile
    ) async throws -> CaptureVoxTextProcessingResult {
        let enrichment = try await enricher.enrich(rawText: text, profile: profile)
        return CaptureVoxTextProcessingResult(
            text: enrichment.cleanedText,
            title: enrichment.title,
            tags: enrichment.tags,
            category: enrichment.category
        )
    }
}
