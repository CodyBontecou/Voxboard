import Foundation

public struct TranscriptStorePersistenceError: Error, Equatable, LocalizedError, Sendable {
    public enum Operation: String, Sendable {
        case load
        case add
        case update
        case delete
        case clear
    }

    public var operation: Operation
    public var message: String

    public init(operation: Operation, message: String) {
        self.operation = operation
        self.message = message
    }

    public var errorDescription: String? {
        "Transcript history \(operation.rawValue) failed: \(message)"
    }
}

/// Persists transcription history as JSON in the App Group shared container.
/// Every mutation reloads the latest coordinated disk value before writing so
/// the app, keyboard, and extensions cannot silently overwrite one another.
@Observable
public final class TranscriptStore {
    public var transcripts: [Transcript] = []
    public private(set) var lastPersistenceError: TranscriptStorePersistenceError?

    private let fileURL: URL?
    private let coordinator: any CaptureFileCoordinating
    private let fileManager: FileManager
    private let activityStatsStore: ActivityStatsStore?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public convenience init() {
        let coordinator = NSFileCoordinatorCaptureFileCoordinator.shared
        self.init(
            fileURL: AppConstants.sharedContainerURL?.appendingPathComponent("transcripts.json"),
            coordinator: coordinator,
            activityStatsStore: AppConstants.activityStatsURL.map {
                ActivityStatsStore(fileURL: $0, coordinator: coordinator)
            }
        )
    }

    init(
        fileURL: URL?,
        coordinator: any CaptureFileCoordinating = NSFileCoordinatorCaptureFileCoordinator.shared,
        fileManager: FileManager = .default,
        activityStatsStore: ActivityStatsStore? = nil
    ) {
        self.fileURL = fileURL
        self.coordinator = coordinator
        self.fileManager = fileManager
        self.activityStatsStore = activityStatsStore
        load()
    }

    public func add(_ transcript: Transcript) {
        mutate(operation: .add) { latest in
            latest.removeAll { $0.id == transcript.id }
            latest.insert(transcript, at: 0)
        }
        guard lastPersistenceError == nil else { return }
        // Stats are content-free and best-effort; history persistence remains
        // the source of truth for whether this recording completed.
        _ = try? activityStatsStore?.record(RecordingActivityEvent(
            id: transcript.id,
            date: transcript.date,
            duration: transcript.duration
        ))
    }

    /// Replace an existing transcript by id. No-op if the id is unknown.
    public func update(_ transcript: Transcript) {
        mutate(operation: .update) { latest in
            guard let index = latest.firstIndex(where: { $0.id == transcript.id }) else { return }
            latest[index] = transcript
        }
    }

    public func delete(at offsets: IndexSet) {
        let ids = Set(offsets.compactMap { index in
            transcripts.indices.contains(index) ? transcripts[index].id : nil
        })
        delete(ids: ids)
    }

    public func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        mutate(operation: .delete) { latest in
            latest.removeAll { ids.contains($0.id) }
        }
    }

    public func clear() {
        mutate(operation: .clear) { $0.removeAll() }
    }

    public func clearPersistenceError() {
        lastPersistenceError = nil
    }

    /// Re-read transcripts from disk (e.g. after another process wrote new data).
    public func reload() {
        load()
    }

    private func mutate(
        operation: TranscriptStorePersistenceError.Operation,
        _ mutation: (inout [Transcript]) -> Void
    ) {
        guard let url = fileURL else {
            mutation(&transcripts)
            lastPersistenceError = nil
            return
        }

        do {
            let updated = try coordinator.coordinateWriting(at: url) { coordinatedURL in
                var latest = try read(from: coordinatedURL)
                mutation(&latest)
                try persist(latest, to: coordinatedURL)
                return latest
            }
            transcripts = updated
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = TranscriptStorePersistenceError(
                operation: operation,
                message: error.localizedDescription
            )
        }
    }

    private func load() {
        guard let url = fileURL else { return }
        do {
            transcripts = try coordinator.coordinateWriting(at: url) { coordinatedURL in
                try read(from: coordinatedURL)
            }
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = TranscriptStorePersistenceError(
                operation: .load,
                message: error.localizedDescription
            )
        }
    }

    private func read(from url: URL) throws -> [Transcript] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([Transcript].self, from: Data(contentsOf: url))
    }

    private func persist(_ value: [Transcript], to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
