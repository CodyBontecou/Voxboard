import AVFoundation
import Foundation
import VoxboardCaptureCore

enum WatchLocalRecordingTransportState: String, Codable, Equatable {
    case local
    case transferring
    case uploaded
}

struct WatchLocalQueuedRecording: Codable, Equatable, Identifiable {
    let id: String
    let filename: String
    let createdAt: Date
    var duration: TimeInterval
    var transportState: WatchLocalRecordingTransportState
    var remotePhase: WatchRemoteRecordingPhase?
    var remoteRevision: Int
    var remoteMessage: String?
    var presetID: String?
    var presetName: String?
    var presetSnapshot: Data?
    var locationOutcome: CaptureLocationOutcome?

    init(
        id: String,
        filename: String,
        createdAt: Date,
        duration: TimeInterval,
        transportState: WatchLocalRecordingTransportState = .local,
        remotePhase: WatchRemoteRecordingPhase? = nil,
        remoteRevision: Int = 0,
        remoteMessage: String? = nil,
        presetID: String? = nil,
        presetName: String? = nil,
        presetSnapshot: Data? = nil,
        locationOutcome: CaptureLocationOutcome? = nil
    ) {
        self.id = id
        self.filename = filename
        self.createdAt = createdAt
        self.duration = duration
        self.transportState = transportState
        self.remotePhase = remotePhase
        self.remoteRevision = remoteRevision
        self.remoteMessage = remoteMessage
        self.presetID = presetID
        self.presetName = presetName
        self.presetSnapshot = presetSnapshot
        self.locationOutcome = locationOutcome
    }

    private enum CodingKeys: String, CodingKey {
        case id, filename, createdAt, duration, transportState, remotePhase,
             remoteRevision, remoteMessage, presetID, presetName, presetSnapshot,
             locationOutcome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            filename: try container.decode(String.self, forKey: .filename),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            duration: try container.decode(TimeInterval.self, forKey: .duration),
            transportState: try container.decodeIfPresent(
                WatchLocalRecordingTransportState.self,
                forKey: .transportState
            ) ?? .local,
            remotePhase: try container.decodeIfPresent(WatchRemoteRecordingPhase.self, forKey: .remotePhase),
            remoteRevision: try container.decodeIfPresent(Int.self, forKey: .remoteRevision) ?? 0,
            remoteMessage: try container.decodeIfPresent(String.self, forKey: .remoteMessage),
            presetID: try container.decodeIfPresent(String.self, forKey: .presetID),
            presetName: try container.decodeIfPresent(String.self, forKey: .presetName),
            presetSnapshot: try container.decodeIfPresent(Data.self, forKey: .presetSnapshot),
            locationOutcome: try container.decodeIfPresent(CaptureLocationOutcome.self, forKey: .locationOutcome)
        )
    }
}

enum WatchLocalTransferCompletionOutcome: Equatable {
    case unknownRecording
    case uploaded
    case retryRequired
    case failed
}

struct WatchLocalTransferCompletion: Equatable {
    let recordings: [WatchLocalQueuedRecording]
    let outcome: WatchLocalTransferCompletionOutcome
}

struct WatchLocalTerminalAcknowledgement: Equatable {
    let recordingID: String
    let revision: Int
}

struct WatchLocalRemoteReconciliation: Equatable {
    let recordings: [WatchLocalQueuedRecording]
    let removedRecordings: [WatchLocalQueuedRecording]
    let terminalAcknowledgements: [WatchLocalTerminalAcknowledgement]
}

struct WatchLocalPersistedRemoteReconciliation: Equatable {
    let reconciliation: WatchLocalRemoteReconciliation
    let deletedAudioRecordings: [WatchLocalQueuedRecording]
}

struct WatchLocalRecordingQueueStore {
    let recordingsDirectoryURL: URL
    var now: () -> Date = Date.init

    private var queueIndexURL: URL {
        recordingsDirectoryURL.appendingPathComponent("index.json")
    }

    private var activeRecordingURL: URL {
        recordingsDirectoryURL.appendingPathComponent("active-recording.json")
    }

    func audioURL(for recording: WatchLocalQueuedRecording) -> URL {
        precondition(Self.isSafeAudioFilename(recording.filename), "Unsafe Watch recording filename")
        return recordingsDirectoryURL.appendingPathComponent(recording.filename)
    }

    private func validatedAudioURL(for recording: WatchLocalQueuedRecording) -> URL? {
        guard Self.isSafeAudioFilename(recording.filename) else { return nil }
        return recordingsDirectoryURL.appendingPathComponent(recording.filename)
    }

    func loadRecoveringInterruptedCapture() -> [WatchLocalQueuedRecording] {
        let indexData = try? Data(contentsOf: queueIndexURL)
        let decoded = indexData.flatMap {
            try? JSONDecoder().decode([WatchLocalQueuedRecording].self, from: $0)
        }
        let indexCouldNotDecode = indexData != nil && decoded == nil
        var existing = (decoded ?? []).filter {
            guard let audioURL = validatedAudioURL(for: $0) else { return false }
            return FileManager.default.fileExists(atPath: audioURL.path)
        }

        if let activeData = try? Data(contentsOf: activeRecordingURL),
           var interrupted = try? JSONDecoder().decode(WatchLocalQueuedRecording.self, from: activeData),
           let interruptedAudioURL = validatedAudioURL(for: interrupted),
           FileManager.default.fileExists(atPath: interruptedAudioURL.path),
           !existing.contains(where: { $0.id == interrupted.id }) {
            interrupted.transportState = .local
            interrupted.duration = max(
                interrupted.duration,
                (try? AVAudioPlayer(contentsOf: interruptedAudioURL).duration) ?? 0
            )
            if interrupted.locationOutcome == nil,
               CaptureWatchLocationAcquisitionPolicy.shouldAcquire(
                   presetSnapshot: interrupted.presetSnapshot
               ) {
                interrupted.locationOutcome = .unavailable(.unavailable, attemptedAt: now())
            }
            existing.append(interrupted)
        }

        let audioFiles = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectoryURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in audioFiles where url.pathExtension.lowercased() == "m4a" {
            guard !existing.contains(where: { $0.filename == url.lastPathComponent }) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let id = stem.hasPrefix("watch-") ? String(stem.dropFirst("watch-".count)) : stem
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            existing.append(WatchLocalQueuedRecording(
                id: id,
                filename: url.lastPathComponent,
                createdAt: values?.creationDate ?? values?.contentModificationDate ?? now(),
                duration: (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
            ))
        }

        existing.sort { $0.createdAt < $1.createdAt }
        do {
            if indexCouldNotDecode {
                let backup = recordingsDirectoryURL.appendingPathComponent(
                    "index-corrupt-\(Int(now().timeIntervalSince1970)).json"
                )
                try? FileManager.default.copyItem(at: queueIndexURL, to: backup)
            }
            try save(existing)
            clearActiveRecording()
        } catch {
            // Preserve original manifests for a later recovery attempt.
        }
        return existing
    }

    func reconcilingTransferCompletion(
        recordings: [WatchLocalQueuedRecording],
        recordingID: String,
        didSucceed: Bool
    ) -> WatchLocalTransferCompletion {
        guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else {
            return WatchLocalTransferCompletion(
                recordings: recordings,
                outcome: .unknownRecording
            )
        }
        var reconciled = recordings
        if !didSucceed {
            reconciled[index].transportState = .local
            return WatchLocalTransferCompletion(recordings: reconciled, outcome: .failed)
        }
        if reconciled[index].remotePhase == .transportFailed {
            reconciled[index].transportState = .local
            return WatchLocalTransferCompletion(
                recordings: reconciled,
                outcome: .retryRequired
            )
        }
        reconciled[index].transportState = .uploaded
        if reconciled[index].remotePhase == nil {
            reconciled[index].remotePhase = .queued
        }
        return WatchLocalTransferCompletion(recordings: reconciled, outcome: .uploaded)
    }

    func reconcilingRemoteStatuses(
        _ statuses: [WatchRemoteRecordingStatus],
        recordings: [WatchLocalQueuedRecording]
    ) -> WatchLocalRemoteReconciliation {
        var reconciled = recordings
        var removed: [WatchLocalQueuedRecording] = []
        var acknowledgements: [WatchLocalTerminalAcknowledgement] = []

        for status in statuses {
            guard let index = reconciled.firstIndex(where: { $0.id == status.recordingID }) else {
                if status.phase == .delivered || status.phase == .discarded {
                    acknowledgements.append(WatchLocalTerminalAcknowledgement(
                        recordingID: status.recordingID,
                        revision: status.revision
                    ))
                }
                continue
            }
            guard status.revision > reconciled[index].remoteRevision else { continue }

            if status.phase == .transportFailed {
                reconciled[index].transportState = .local
                reconciled[index].remotePhase = .transportFailed
                reconciled[index].remoteRevision = status.revision
                reconciled[index].remoteMessage = status.message
                continue
            }

            reconciled[index].transportState = .uploaded
            reconciled[index].remotePhase = status.phase
            reconciled[index].remoteRevision = status.revision
            reconciled[index].remoteMessage = status.message

            if status.phase == .delivered || status.phase == .discarded {
                removed.append(recordings.first(where: { $0.id == status.recordingID }) ?? reconciled[index])
                reconciled.remove(at: index)
                acknowledgements.append(WatchLocalTerminalAcknowledgement(
                    recordingID: status.recordingID,
                    revision: status.revision
                ))
            }
        }

        return WatchLocalRemoteReconciliation(
            recordings: reconciled,
            removedRecordings: removed,
            terminalAcknowledgements: acknowledgements
        )
    }

    /// Applies remote statuses with the same crash order used by the Watch app:
    /// persist the terminal-free queue before deleting acknowledged source audio.
    /// If the process exits after persistence, orphan recovery preserves the file
    /// as a visible recovery item rather than silently losing user audio.
    func applyRemoteStatusesPersisting(
        _ statuses: [WatchRemoteRecordingStatus],
        recordings: [WatchLocalQueuedRecording]
    ) throws -> WatchLocalPersistedRemoteReconciliation {
        let reconciliation = reconcilingRemoteStatuses(statuses, recordings: recordings)
        try save(reconciliation.recordings)
        var deleted: [WatchLocalQueuedRecording] = []
        for item in reconciliation.removedRecordings {
            let url = audioURL(for: item)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.removeItem(at: url)
            deleted.append(item)
        }
        return WatchLocalPersistedRemoteReconciliation(
            reconciliation: reconciliation,
            deletedAudioRecordings: deleted
        )
    }

    func save(_ recordings: [WatchLocalQueuedRecording]) throws {
        guard recordings.allSatisfy({ Self.isSafeAudioFilename($0.filename) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(
            at: recordingsDirectoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(recordings.sorted { $0.createdAt < $1.createdAt })
            .write(to: queueIndexURL, options: .atomic)
    }

    func saveActiveRecording(_ recording: WatchLocalQueuedRecording) throws {
        guard Self.isSafeAudioFilename(recording.filename) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(
            at: recordingsDirectoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(recording).write(to: activeRecordingURL, options: .atomic)
    }

    func clearActiveRecording() {
        try? FileManager.default.removeItem(at: activeRecordingURL)
    }

    private static func isSafeAudioFilename(_ filename: String) -> Bool {
        let path = filename as NSString
        return !filename.isEmpty
            && path.lastPathComponent == filename
            && !filename.contains("/")
            && !filename.contains("\\")
            && URL(fileURLWithPath: filename).pathExtension.lowercased() == "m4a"
    }
}
