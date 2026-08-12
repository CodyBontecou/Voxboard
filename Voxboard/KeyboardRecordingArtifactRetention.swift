import Foundation
import VoxboardShared

struct KeyboardRecordingArtifactCleanupResult: Equatable, Sendable {
    let retainedArtifactCount: Int
    let unprotectedRetainedArtifactCount: Int

    nonisolated var didRemoveAllArtifacts: Bool { retainedArtifactCount == 0 }
}

/// Couples destructive keyboard-audio cleanup to successful transcript delivery.
/// Any transcription, persistence, or IPC error escapes before either artifact
/// is removed, allowing relaunch orphan recovery to surface the recording.
enum KeyboardRecordingArtifactRetention {
    static func perform(
        wavURL: URL,
        journalURL: URL?,
        fileManager: FileManager = .default,
        removeItem: ((URL) throws -> Void)? = nil,
        writeDeliveryReceipt: ((URL) throws -> Void)? = nil,
        delivery: () async throws -> Void
    ) async throws -> KeyboardRecordingArtifactCleanupResult {
        try await delivery()
        let remove = removeItem ?? { try fileManager.removeItem(at: $0) }
        let writeReceipt = writeDeliveryReceipt
            ?? { try RecordingArtifactDeliveryReceipt.write(for: $0) }
        let artifacts = [journalURL, wavURL]
            .compactMap { $0 }
            .filter { fileManager.fileExists(atPath: $0.path) }

        // Protect every surviving source before the first destructive action.
        // If source deletion later fails, queue orphan recovery recognizes the
        // receipt and retries cleanup rather than retranscribing delivered audio.
        var receiptWriteFailed = false
        for artifact in artifacts {
            do {
                try writeReceipt(artifact)
            } catch {
                receiptWriteFailed = true
            }
        }
        guard !receiptWriteFailed else {
            return cleanupResult(
                wavURL: wavURL,
                journalURL: journalURL,
                fileManager: fileManager
            )
        }

        // Remove the recovery journal first. If that fails, keep the WAV too so
        // cleanup retains a recoverable pair, both protected by delivery receipts.
        if let journalURL, fileManager.fileExists(atPath: journalURL.path) {
            do {
                try remove(journalURL)
                RecordingArtifactDeliveryReceipt.remove(
                    for: journalURL,
                    fileManager: fileManager
                )
            } catch {
                return cleanupResult(
                    wavURL: wavURL,
                    journalURL: journalURL,
                    fileManager: fileManager
                )
            }
        }
        if fileManager.fileExists(atPath: wavURL.path) {
            do {
                try remove(wavURL)
                RecordingArtifactDeliveryReceipt.remove(
                    for: wavURL,
                    fileManager: fileManager
                )
            } catch {
                // The receipt deliberately remains beside the retained source.
            }
        }
        return cleanupResult(
            wavURL: wavURL,
            journalURL: journalURL,
            fileManager: fileManager
        )
    }

    private static func cleanupResult(
        wavURL: URL,
        journalURL: URL?,
        fileManager: FileManager
    ) -> KeyboardRecordingArtifactCleanupResult {
        let retained = [wavURL, journalURL]
            .compactMap { $0 }
            .filter { fileManager.fileExists(atPath: $0.path) }
        let unprotected = retained.filter {
            !RecordingArtifactDeliveryReceipt.exists(for: $0, fileManager: fileManager)
        }
        return KeyboardRecordingArtifactCleanupResult(
            retainedArtifactCount: retained.count,
            unprotectedRetainedArtifactCount: unprotected.count
        )
    }
}
