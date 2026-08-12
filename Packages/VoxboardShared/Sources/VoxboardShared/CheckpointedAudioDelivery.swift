#if canImport(AVFoundation)
import Foundation

/// Publishes a requested audio attachment, durably checkpoints the exact URL
/// returned by the exporter, and only then attaches/checkpoints the note
/// reference. Source-audio ownership remains with the caller so any thrown
/// error preserves the recording for retry.
public enum CheckpointedAudioDelivery {
    public typealias ExportCheckpoint = @Sendable (URL) async throws -> Void
    public typealias ReferenceCheckpoint = @Sendable () async throws -> Void

    @discardableResult
    public static func deliver(
        sourceAudioURL: URL,
        transcriptFileURL: URL,
        flow: CapturePreset,
        transcriptFolderScopeURL: URL? = nil,
        previouslyExportedURL: URL? = nil,
        audioReferenceAlreadyAttached: Bool = false,
        audioDeliveryTransactionDirectoryURL: URL? = nil,
        audioReferenceDeliveryTransactionDirectoryURL: URL? = nil,
        checkpointExport: @escaping ExportCheckpoint,
        checkpointReference: @escaping ReferenceCheckpoint
    ) async throws -> URL? {
        guard let audioURL = try await AudioAttachmentExporter.exportAudioIfNeeded(
            sourceAudioURL: sourceAudioURL,
            transcriptFileURL: transcriptFileURL,
            flow: flow,
            transcriptFolderScopeURL: transcriptFolderScopeURL,
            previouslyExportedURL: previouslyExportedURL,
            deliveryTransactionDirectoryURL: audioDeliveryTransactionDirectoryURL
        ) else {
            return nil
        }

        // This is intentionally unconditional. The exporter may repair a
        // missing or zero-length checkpoint at a different URL, and that exact
        // returned URL must replace stale durable queue state.
        try await checkpointExport(audioURL)

        let repairedCheckpoint = previouslyExportedURL.map {
            $0.standardizedFileURL != audioURL.standardizedFileURL
        } ?? false
        if !audioReferenceAlreadyAttached || repairedCheckpoint {
            let relativePath = AudioAttachmentExporter.relativePath(
                from: transcriptFileURL,
                to: audioURL
            )
            let previousRelativePath = repairedCheckpoint
                ? previouslyExportedURL.map {
                    AudioAttachmentExporter.relativePath(from: transcriptFileURL, to: $0)
                }
                : nil
            try TranscriptFileExporter.attachAudioReference(
                to: transcriptFileURL,
                relativePath: relativePath,
                securityScopedFolderURL: transcriptFolderScopeURL,
                embedInMarkdown: flow.exportSettings.embedAudioInMarkdown,
                embedPlacement: flow.exportSettings.audioEmbedPlacement,
                replacingRelativePath: previousRelativePath,
                deliveryTransactionDirectoryURL: audioReferenceDeliveryTransactionDirectoryURL
            )
            try await checkpointReference()
        }

        return audioURL
    }
}
#endif
