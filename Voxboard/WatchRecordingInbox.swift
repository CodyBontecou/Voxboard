import Foundation
import VoxboardShared

nonisolated enum WatchRecordingProcessingPhase: String, Codable, CaseIterable, Sendable {
    case queued
    case transcribing
    case delivering
    case delivered
    case failed
    case discarded

    var isTerminal: Bool {
        self == .delivered || self == .discarded
    }
}

nonisolated enum WatchRecordingFailureStage: String, Codable, Sendable {
    case storage
    case transcription
    case delivery
}

nonisolated enum WatchRecordingStatusMessage {
    static let transcriptionLimitReached =
        "You've used your free transcription time. Get Vox.md Unlimited to continue."
}

/// Durable, privacy-safe state for one recording received from Apple Watch.
/// The original audio remains in WatchInbox until delivery succeeds or the user
/// explicitly discards it.
nonisolated struct WatchRecordingInboxItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let requestID: UUID
    let filename: String
    let originalFilename: String?
    let createdAt: Date
    let receivedAt: Date
    let duration: TimeInterval?
    var flowSnapshot: CapturePreset?
    var flowSnapshotPayload: Data?
    var requiresPresetSelection: Bool
    /// One-shot fallback chosen from the iPhone queue after Watch transcription
    /// fails. This remains durable across suspension and Capture delivery retries.
    var capturesRecordingWithoutTranscript: Bool
    /// Stable user-visible filename reserved before a recording-only Files copy.
    /// Persisting it makes a retry idempotent if the app is suspended after copy.
    var reservedOutputFilename: String?
    /// Folder permission paired with `reservedOutputFilename`. A reservation
    /// must never be silently reused against a different Files destination.
    var reservedOutputFolderBookmark: Data?
    var phase: WatchRecordingProcessingPhase
    var failureStage: WatchRecordingFailureStage?
    var statusMessage: String?
    var attemptCount: Int
    var revision: Int
    var updatedAt: Date
    var deliveredAt: Date?
    var acknowledgedAt: Date?

    var fileURL: URL {
        WatchRecordingInbox.inboxDirectory.appendingPathComponent(filename)
    }

    var hasAudio: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    var displayPresetName: String {
        if requiresPresetSelection { return "Choose a Preset" }
        return flowSnapshot?.displayName ?? "Capture Preset"
    }

    init(
        id: String,
        requestID: UUID,
        filename: String,
        originalFilename: String?,
        createdAt: Date,
        receivedAt: Date,
        duration: TimeInterval?,
        flowSnapshot: CapturePreset?,
        flowSnapshotPayload: Data? = nil,
        requiresPresetSelection: Bool = false,
        capturesRecordingWithoutTranscript: Bool = false,
        reservedOutputFilename: String? = nil,
        reservedOutputFolderBookmark: Data? = nil,
        phase: WatchRecordingProcessingPhase = .queued,
        failureStage: WatchRecordingFailureStage? = nil,
        statusMessage: String? = nil,
        attemptCount: Int = 0,
        revision: Int = 1,
        updatedAt: Date = Date(),
        deliveredAt: Date? = nil,
        acknowledgedAt: Date? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.filename = filename
        self.originalFilename = originalFilename
        self.createdAt = createdAt
        self.receivedAt = receivedAt
        self.duration = duration
        self.flowSnapshot = flowSnapshot
        self.flowSnapshotPayload = flowSnapshotPayload
        self.requiresPresetSelection = requiresPresetSelection
        self.capturesRecordingWithoutTranscript = capturesRecordingWithoutTranscript
        self.reservedOutputFilename = reservedOutputFilename
        self.reservedOutputFolderBookmark = reservedOutputFolderBookmark
        self.phase = phase
        self.failureStage = failureStage
        self.statusMessage = statusMessage
        self.attemptCount = attemptCount
        self.revision = revision
        self.updatedAt = updatedAt
        self.deliveredAt = deliveredAt
        self.acknowledgedAt = acknowledgedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case requestID
        case filename
        case originalFilename
        case createdAt
        case receivedAt
        case duration
        case flowSnapshot
        case flowSnapshotPayload
        case requiresPresetSelection
        case capturesRecordingWithoutTranscript
        case reservedOutputFilename
        case reservedOutputFolderBookmark
        case phase
        case failureStage
        case statusMessage
        case attemptCount
        case revision
        case updatedAt
        case deliveredAt
        case acknowledgedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let receivedAt = try container.decodeIfPresent(Date.self, forKey: .receivedAt) ?? Date()
        self.init(
            id: id,
            requestID: try container.decodeIfPresent(UUID.self, forKey: .requestID)
                ?? UUID(uuidString: id)
                ?? UUID(),
            filename: try container.decode(String.self, forKey: .filename),
            originalFilename: try container.decodeIfPresent(String.self, forKey: .originalFilename),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? receivedAt,
            receivedAt: receivedAt,
            duration: try container.decodeIfPresent(TimeInterval.self, forKey: .duration),
            flowSnapshot: try? container.decode(CapturePreset.self, forKey: .flowSnapshot),
            flowSnapshotPayload: try container.decodeIfPresent(Data.self, forKey: .flowSnapshotPayload),
            requiresPresetSelection: try container.decodeIfPresent(Bool.self, forKey: .requiresPresetSelection) ?? false,
            capturesRecordingWithoutTranscript: try container.decodeIfPresent(
                Bool.self,
                forKey: .capturesRecordingWithoutTranscript
            ) ?? false,
            reservedOutputFilename: try container.decodeIfPresent(String.self, forKey: .reservedOutputFilename),
            reservedOutputFolderBookmark: try container.decodeIfPresent(Data.self, forKey: .reservedOutputFolderBookmark),
            phase: try container.decodeIfPresent(WatchRecordingProcessingPhase.self, forKey: .phase) ?? .queued,
            failureStage: try container.decodeIfPresent(WatchRecordingFailureStage.self, forKey: .failureStage),
            statusMessage: try container.decodeIfPresent(String.self, forKey: .statusMessage),
            attemptCount: try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0,
            revision: try container.decodeIfPresent(Int.self, forKey: .revision) ?? 1,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? receivedAt,
            deliveredAt: try container.decodeIfPresent(Date.self, forKey: .deliveredAt),
            acknowledgedAt: try container.decodeIfPresent(Date.self, forKey: .acknowledgedAt)
        )
    }
}

nonisolated final class WatchRecordingInbox: @unchecked Sendable {
    static let shared = WatchRecordingInbox()
    static let didChangeNotification = Notification.Name("WatchRecordingInboxDidChange")

    static var inboxDirectory: URL {
        let base = AppConstants.recordingsDirectoryURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WatchInbox", isDirectory: true)
    }

    private var indexURL: URL {
        Self.inboxDirectory.appendingPathComponent("index.json")
    }

    private let lock = NSLock()

    private init() {}

    /// Moves WatchConnectivity's temporary file into durable storage before the
    /// delegate returns. Duplicate transfers never replace active or completed work.
    @discardableResult
    func enqueue(fileURL: URL, metadata: [String: Any]) throws -> WatchRecordingInboxItem {
        let item: WatchRecordingInboxItem = try withLock {
            try ensureDirectory()

            let id = (metadata[WatchRecordingFileMetadataKey.recordingID] as? String)
                ?? UUID().uuidString
            var items = loadUnlocked()
            if let index = items.firstIndex(where: { $0.id == id }) {
                var existing = items[index]
                if !existing.hasAudio, !existing.phase.isTerminal {
                    let destination = Self.inboxDirectory.appendingPathComponent(existing.filename)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: fileURL, to: destination)
                    existing.phase = .queued
                    existing.failureStage = nil
                    existing.statusMessage = "Received retry from Apple Watch"
                    existing.updatedAt = Date()
                    existing.revision += 1
                    items[index] = existing
                    try saveUnlocked(items)
                } else {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                return existing
            }

            let createdAtSeconds = metadata[WatchRecordingFileMetadataKey.createdAt] as? TimeInterval
            let createdAt = createdAtSeconds
                .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                ?? Date()
            let duration = (metadata[WatchRecordingFileMetadataKey.duration] as? TimeInterval)
                .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let originalFilename = metadata[WatchRecordingFileMetadataKey.originalFilename] as? String
            let ext = fileURL.pathExtension.isEmpty ? "m4a" : fileURL.pathExtension
            let filename = "watch-\(sanitize(id)).\(ext)"
            let destination = Self.inboxDirectory.appendingPathComponent(filename)
            let requestedPresetID = metadata[WatchRecordingFileMetadataKey.presetID] as? String
            let flowSnapshotPayload = metadata[WatchRecordingFileMetadataKey.presetSnapshot] as? Data
            let transferredSnapshot = flowSnapshotPayload
                .flatMap { try? JSONDecoder().decode(CapturePreset.self, from: $0) }
            let snapshotIsIncompatible = flowSnapshotPayload != nil && transferredSnapshot == nil
            let flowSnapshot = flowSnapshotPayload == nil
                ? resolvedFlowSnapshot(requestedPresetID: requestedPresetID)
                : transferredSnapshot
            let newItem = WatchRecordingInboxItem(
                id: id,
                requestID: UUID(uuidString: id) ?? UUID(),
                filename: filename,
                originalFilename: originalFilename,
                createdAt: createdAt,
                receivedAt: Date(),
                duration: duration,
                flowSnapshot: flowSnapshot,
                flowSnapshotPayload: flowSnapshotPayload,
                phase: snapshotIsIncompatible ? .failed : .queued,
                failureStage: snapshotIsIncompatible ? .storage : nil,
                statusMessage: snapshotIsIncompatible
                    ? "Update Vox.md on iPhone to use this recording's Capture Preset."
                    : "Received from Apple Watch"
            )

            // Journal metadata before moving WCSession's temporary file. If the
            // process is interrupted at either step, a retry can reconstruct it.
            try saveSidecarUnlocked(newItem)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: fileURL, to: destination)
            items.append(newItem)
            try saveUnlocked(items)
            return newItem
        }
        notifyChanged()
        return item
    }

    func load() -> [WatchRecordingInboxItem] {
        withLock { loadUnlocked() }
    }

    @discardableResult
    func update(
        id: String,
        _ mutation: (inout WatchRecordingInboxItem) -> Void
    ) -> WatchRecordingInboxItem? {
        let updated: WatchRecordingInboxItem? = withLock {
            var items = loadUnlocked()
            guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
            mutation(&items[index])
            items[index].revision += 1
            items[index].updatedAt = Date()
            do {
                try saveUnlocked(items)
                return items[index]
            } catch {
                return nil
            }
        }
        if updated != nil { notifyChanged() }
        return updated
    }

    @discardableResult
    func transition(
        id: String,
        to phase: WatchRecordingProcessingPhase,
        failureStage: WatchRecordingFailureStage? = nil,
        message: String? = nil
    ) -> WatchRecordingInboxItem? {
        let updated: WatchRecordingInboxItem? = withLock {
            var items = loadUnlocked()
            guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
            guard !items[index].phase.isTerminal || items[index].phase == phase else { return nil }
            items[index].phase = phase
            items[index].failureStage = failureStage
            items[index].statusMessage = message
            if phase == .transcribing {
                items[index].attemptCount += 1
            }
            if phase == .delivered {
                items[index].deliveredAt = Date()
            }
            items[index].updatedAt = Date()
            items[index].revision += 1
            do {
                try saveUnlocked(items)
                return items[index]
            } catch {
                return nil
            }
        }
        if updated != nil { notifyChanged() }
        return updated
    }

    @discardableResult
    func ensureFlowSnapshot(id: String) -> WatchRecordingInboxItem? {
        update(id: id) { item in
            guard item.flowSnapshot == nil, !item.requiresPresetSelection else { return }
            if let payload = item.flowSnapshotPayload {
                item.flowSnapshot = try? JSONDecoder().decode(CapturePreset.self, from: payload)
            } else {
                item.flowSnapshot = resolvedFlowSnapshot(requestedPresetID: nil)
            }
        }
    }

    /// Keeps a compact terminal tombstone after Watch acknowledgement so any
    /// delayed duplicate transfer can never recreate completed work.
    @discardableResult
    func markDelivered(
        id: String,
        message: String = "Saved to Capture"
    ) -> WatchRecordingInboxItem? {
        let item = transition(id: id, to: .delivered, message: message)
        if let item {
            try? FileManager.default.removeItem(at: item.fileURL)
        }
        return item
    }

    @discardableResult
    func discard(id: String) -> WatchRecordingInboxItem? {
        let item = transition(id: id, to: .discarded, message: "Discarded on iPhone")
        if let item {
            try? FileManager.default.removeItem(at: item.fileURL)
        }
        return item
    }

    func acknowledgeTerminalState(id: String, revision: Int) {
        let didUpdate: Bool = withLock {
            var items = loadUnlocked()
            guard let index = items.firstIndex(where: { $0.id == id }),
                  items[index].phase.isTerminal,
                  revision >= items[index].revision else { return false }
            try? FileManager.default.removeItem(at: items[index].fileURL)
            if items[index].acknowledgedAt == nil {
                items[index].acknowledgedAt = Date()
            }
            do {
                try saveUnlocked(items)
                return true
            } catch {
                return false
            }
        }
        if didUpdate { notifyChanged() }
    }

    private func resolvedFlowSnapshot(requestedPresetID: String?) -> CapturePreset {
        if let requestedPresetID,
           let requested = CapturePresetStore.flow(id: requestedPresetID),
           requested.isEnabled {
            return requested
        }
        if let selectedID = CapturePresetProfileStore.selectedProfileID(defaults: AppConstants.sharedDefaults),
           let selected = CapturePresetStore.flow(id: selectedID),
           selected.isEnabled {
            return selected
        }
        return CapturePresetStore.selectedFlow()
    }

    private func loadUnlocked() -> [WatchRecordingInboxItem] {
        let indexData = try? Data(contentsOf: indexURL)
        let decoded = indexData.flatMap {
            try? JSONDecoder().decode([WatchRecordingInboxItem].self, from: $0)
        }
        var items = decoded ?? []
        var recovered = decoded == nil && indexData != nil

        let sidecarURLs = (try? FileManager.default.contentsOfDirectory(
            at: Self.inboxDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.lastPathComponent.hasPrefix("item-") && $0.pathExtension == "json" } ?? []
        var sidecarIDs = Set<String>()
        for url in sidecarURLs {
            guard let data = try? Data(contentsOf: url),
                  let sidecar = try? JSONDecoder().decode(WatchRecordingInboxItem.self, from: data) else {
                continue
            }
            sidecarIDs.insert(sidecar.id)
            if let index = items.firstIndex(where: { $0.id == sidecar.id }) {
                if sidecar.revision > items[index].revision {
                    items[index] = sidecar
                    recovered = true
                }
            } else {
                items.append(sidecar)
                recovered = true
            }
        }

        let knownFilenames = Set(items.map(\.filename))
        let orphanAudioURLs = ((try? FileManager.default.contentsOfDirectory(
            at: Self.inboxDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter {
            $0.pathExtension.lowercased() == "m4a" && !knownFilenames.contains($0.lastPathComponent)
        }
        for url in orphanAudioURLs {
            let stem = url.deletingPathExtension().lastPathComponent
            let id = stem.hasPrefix("watch-") ? String(stem.dropFirst("watch-".count)) : stem
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            items.append(WatchRecordingInboxItem(
                id: id,
                requestID: UUID(uuidString: id) ?? UUID(),
                filename: url.lastPathComponent,
                originalFilename: url.lastPathComponent,
                createdAt: values?.creationDate ?? values?.contentModificationDate ?? Date(),
                receivedAt: Date(),
                duration: AudioFileConverter.duration(of: url),
                flowSnapshot: nil,
                requiresPresetSelection: true,
                phase: .failed,
                failureStage: .storage,
                statusMessage: "Recovered after an interrupted save. Choose a Preset to continue."
            ))
            recovered = true
        }

        if indexData != nil && decoded == nil {
            let backup = Self.inboxDirectory.appendingPathComponent(
                "index-corrupt-\(Int(Date().timeIntervalSince1970)).json"
            )
            try? FileManager.default.copyItem(at: indexURL, to: backup)
        }
        if recovered {
            try? saveUnlocked(items)
        } else {
            // Lazily create sidecars for queues written by older app versions.
            items.filter { !sidecarIDs.contains($0.id) }
                .forEach { try? saveSidecarUnlocked($0) }
        }

        return items.sorted { lhs, rhs in
            if lhs.phase.isTerminal != rhs.phase.isTerminal {
                return !lhs.phase.isTerminal
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: Self.inboxDirectory,
            withIntermediateDirectories: true
        )
    }

    private func saveUnlocked(_ items: [WatchRecordingInboxItem]) throws {
        try ensureDirectory()
        let sorted = items.sorted { $0.createdAt < $1.createdAt }
        for item in sorted {
            try saveSidecarUnlocked(item)
        }
        let data = try JSONEncoder().encode(sorted)
        try data.write(to: indexURL, options: .atomic)
    }

    private func saveSidecarUnlocked(_ item: WatchRecordingInboxItem) throws {
        let url = Self.inboxDirectory
            .appendingPathComponent("item-\(sanitize(item.id)).json")
        try JSONEncoder().encode(item).write(to: url, options: .atomic)
    }

    private func sanitize(_ string: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = string.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars)
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}

nonisolated enum WatchRecordingFileMetadataKey {
    static let kind = "kind"
    static let watchAudioRecordingKind = "watchAudioRecording"
    static let recordingID = "recordingID"
    static let createdAt = "createdAt"
    static let duration = "duration"
    static let originalFilename = "originalFilename"
    static let presetID = "presetID"
    static let presetName = "presetName"
    static let presetSnapshot = "presetSnapshot"
}
