import Foundation

/// Privacy-safe metadata for one successfully completed recording.
public struct RecordingActivityEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let duration: TimeInterval

    public init(id: UUID, date: Date, duration: TimeInterval) {
        self.id = id
        self.date = date
        self.duration = max(0, duration)
    }
}

/// Privacy-safe metadata for one successfully delivered Capture.
public struct CaptureActivityEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let source: CaptureSource
    public let attachmentCount: Int

    public init(id: UUID, date: Date, source: CaptureSource, attachmentCount: Int) {
        self.id = id
        self.date = date
        self.source = source
        self.attachmentCount = max(0, attachmentCount)
    }
}

/// The durable, content-free activity ledger used to calculate lifetime stats.
public struct ActivityStatsLedger: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let empty = ActivityStatsLedger(recordings: [], captures: [])

    public let schemaVersion: Int
    public var recordings: [RecordingActivityEvent]
    public var captures: [CaptureActivityEvent]

    public init(
        recordings: [RecordingActivityEvent],
        captures: [CaptureActivityEvent]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.recordings = recordings
        self.captures = captures
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case recordings
        case captures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        guard version == Self.currentSchemaVersion else {
            throw ActivityStatsStoreError.unsupportedSchemaVersion(version)
        }
        schemaVersion = version
        recordings = try container.decode([RecordingActivityEvent].self, forKey: .recordings)
        captures = try container.decode([CaptureActivityEvent].self, forKey: .captures)
    }

    public func encode(to encoder: Encoder) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ActivityStatsStoreError.unsupportedSchemaVersion(schemaVersion)
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(recordings, forKey: .recordings)
        try container.encode(captures, forKey: .captures)
    }
}

public enum ActivityStatsStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Activity stats schema version \(version) is not supported."
        }
    }
}

/// A coordinated App Group ledger of completed activity.
///
/// Stable recording and Capture IDs make writes idempotent across retries and
/// app extensions. Deleting user content or trimming the visible history does
/// not erase these content-free lifetime totals.
public final class ActivityStatsStore: @unchecked Sendable {
    public static let defaultFilename = "activity-stats-v1.json"

    public let fileURL: URL
    private let coordinator: any CaptureFileCoordinating
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public var quarantineDirectoryURL: URL {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-corrupt", isDirectory: true)
    }

    public init(
        fileURL: URL,
        coordinator: any CaptureFileCoordinating = NSFileCoordinatorCaptureFileCoordinator.shared,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.coordinator = coordinator
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    public func load() throws -> ActivityStatsLedger {
        try coordinator.coordinateWriting(at: fileURL) { coordinatedURL in
            try loadLatest(from: coordinatedURL)
        }
    }

    /// Adds or replaces one recording event by its stable transcript ID.
    @discardableResult
    public func record(_ event: RecordingActivityEvent) throws -> ActivityStatsLedger {
        try merge(recordings: [event], captures: [])
    }

    /// Adds or replaces one Capture event by its stable request ID.
    @discardableResult
    public func record(_ event: CaptureActivityEvent) throws -> ActivityStatsLedger {
        try merge(recordings: [], captures: [event])
    }

    /// Backfills any history created before the stats ledger was introduced.
    /// Existing IDs are replaced rather than counted twice.
    @discardableResult
    public func reconcile(
        recordings: [RecordingActivityEvent],
        captures: [CaptureActivityEvent]
    ) throws -> ActivityStatsLedger {
        guard !recordings.isEmpty || !captures.isEmpty else { return try load() }
        return try merge(recordings: recordings, captures: captures)
    }

    private func merge(
        recordings: [RecordingActivityEvent],
        captures: [CaptureActivityEvent]
    ) throws -> ActivityStatsLedger {
        try coordinator.coordinateWriting(at: fileURL) { coordinatedURL in
            var latest = try loadLatest(from: coordinatedURL)
            latest.recordings.append(contentsOf: recordings)
            latest.captures.append(contentsOf: captures)
            latest = normalized(latest)
            try persist(latest, to: coordinatedURL)
            return latest
        }
    }

    private func loadLatest(from url: URL) throws -> ActivityStatsLedger {
        guard fileManager.fileExists(atPath: url.path) else { return .empty }
        let data = try Data(contentsOf: url)
        do {
            return normalized(try decoder.decode(ActivityStatsLedger.self, from: data))
        } catch let error as ActivityStatsStoreError {
            // A newer app may own this file. Never move or overwrite it.
            throw error
        } catch {
            try quarantineCorruptFile(at: url)
            return .empty
        }
    }

    private func normalized(_ ledger: ActivityStatsLedger) -> ActivityStatsLedger {
        var recordingsByID: [UUID: RecordingActivityEvent] = [:]
        for event in ledger.recordings {
            if let existing = recordingsByID[event.id], existing.date > event.date { continue }
            recordingsByID[event.id] = RecordingActivityEvent(
                id: event.id,
                date: event.date,
                duration: event.duration
            )
        }

        var capturesByID: [UUID: CaptureActivityEvent] = [:]
        for event in ledger.captures {
            if let existing = capturesByID[event.id], existing.date > event.date { continue }
            capturesByID[event.id] = CaptureActivityEvent(
                id: event.id,
                date: event.date,
                source: event.source,
                attachmentCount: event.attachmentCount
            )
        }

        return ActivityStatsLedger(
            recordings: recordingsByID.values.sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.id.uuidString < $1.id.uuidString
            },
            captures: capturesByID.values.sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.id.uuidString < $1.id.uuidString
            }
        )
    }

    private func persist(_ ledger: ActivityStatsLedger, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(ledger).write(to: url, options: .atomic)
    }

    private func quarantineCorruptFile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.createDirectory(
            at: quarantineDirectoryURL,
            withIntermediateDirectories: true
        )
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        var destination = quarantineDirectoryURL
            .appendingPathComponent("\(url.lastPathComponent).\(timestamp).corrupt")
        if fileManager.fileExists(atPath: destination.path) {
            destination = quarantineDirectoryURL
                .appendingPathComponent("\(url.lastPathComponent).\(timestamp)-\(UUID().uuidString).corrupt")
        }
        try fileManager.moveItem(at: url, to: destination)
    }
}
