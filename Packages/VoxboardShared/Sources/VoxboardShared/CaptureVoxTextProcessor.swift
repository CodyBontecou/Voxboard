import Foundation
import VoxboardCaptureCore

/// Bridges the app's on-device enrichment backend into the modality-neutral
/// CaptureCore request processor.
public struct EnrichedCapturePresetTextProcessor: CapturePresetTextProcessing {
    /// Upper bound for a single enrichment pass. On-device model sessions can
    /// stall indefinitely (resource pressure, mid-request unavailability);
    /// delivery must never hang behind them (#11).
    public static let defaultTimeout: TimeInterval = 120

    private let enricher: TranscriptEnricher
    private let timeout: TimeInterval

    public init(enricher: TranscriptEnricher, timeout: TimeInterval = EnrichedCapturePresetTextProcessor.defaultTimeout) {
        self.enricher = enricher
        self.timeout = timeout
    }

    public func process(
        text: String,
        profile: CapturePresetProfile
    ) async throws -> CapturePresetTextProcessingResult {
        let enrichment: TranscriptEnrichment
        do {
            enrichment = try await withRunningTask(timeout: timeout) {
                try await self.enricher.enrich(rawText: text, profile: profile)
            }
        } catch is EnrichmentTimeoutError {
            // Degrade to the raw capture instead of blocking delivery. The
            // note still lands promptly; cleanup/title/tags are simply absent.
            return CapturePresetTextProcessingResult(
                text: text,
                title: nil,
                tags: [],
                category: nil
            )
        }
        return CapturePresetTextProcessingResult(
            text: enrichment.cleanedText,
            title: enrichment.title,
            tags: enrichment.tags,
            category: enrichment.category
        )
    }
}

public typealias EnrichedCaptureVoxTextProcessor = EnrichedCapturePresetTextProcessor

/// Thrown when an enrichment pass exceeds its deadline. Distinct from
/// `CancellationError` so caller-side cancellation still propagates as-is.
public struct EnrichmentTimeoutError: Error, Sendable {}

/// Races `operation` against a deadline. On timeout the underlying task is
/// cancelled and `EnrichmentTimeoutError` is thrown. Errors thrown by the
/// operation itself (including `CancellationError`) propagate unchanged.
func withRunningTask<T: Sendable>(
    timeout: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw EnrichmentTimeoutError()
        }
        guard let result = try await group.next() else {
            throw EnrichmentTimeoutError()
        }
        group.cancelAll()
        return result
    }
}
