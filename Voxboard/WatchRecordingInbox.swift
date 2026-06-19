import Foundation
import VoxboardShared

nonisolated struct WatchRecordingInboxItem: Codable, Equatable, Identifiable {
    let id: String
    let filename: String
    let originalFilename: String?
    let createdAt: Date
    let receivedAt: Date
    let duration: TimeInterval?

    var fileURL: URL {
        WatchRecordingInbox.inboxDirectory.appendingPathComponent(filename)
    }
}

nonisolated final class WatchRecordingInbox {
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

    private init() {}

    @discardableResult
    func enqueue(fileURL: URL, metadata: [String: Any]) throws -> WatchRecordingInboxItem {
        try ensureDirectory()

        let id = (metadata[WatchRecordingFileMetadataKey.recordingID] as? String)
            ?? UUID().uuidString
        let createdAtSeconds = metadata[WatchRecordingFileMetadataKey.createdAt] as? TimeInterval
        let createdAt = createdAtSeconds.map(Date.init(timeIntervalSince1970:)) ?? Date()
        let duration = metadata[WatchRecordingFileMetadataKey.duration] as? TimeInterval
        let originalFilename = metadata[WatchRecordingFileMetadataKey.originalFilename] as? String
        let ext = fileURL.pathExtension.isEmpty ? "m4a" : fileURL.pathExtension
        let filename = "watch-\(sanitize(id)).\(ext)"
        let destination = Self.inboxDirectory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        // WCSession delivers files in a temporary location that must be moved
        // before the delegate returns. Enqueue is only used for those transfers,
        // so move rather than copy to satisfy WatchConnectivity's lifecycle.
        try FileManager.default.moveItem(at: fileURL, to: destination)

        let item = WatchRecordingInboxItem(
            id: id,
            filename: filename,
            originalFilename: originalFilename,
            createdAt: createdAt,
            receivedAt: Date(),
            duration: duration
        )

        var items = load().filter { $0.id != id }
        items.append(item)
        try save(items.sorted { $0.createdAt < $1.createdAt })
        notifyChanged()
        return item
    }

    func load() -> [WatchRecordingInboxItem] {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([WatchRecordingInboxItem].self, from: data) else {
            return []
        }

        let existing = decoded.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        if existing.count != decoded.count {
            try? save(existing)
        }
        return existing.sorted { $0.createdAt < $1.createdAt }
    }

    func remove(_ item: WatchRecordingInboxItem) {
        try? FileManager.default.removeItem(at: item.fileURL)
        let remaining = load().filter { $0.id != item.id }
        try? save(remaining)
        notifyChanged()
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: Self.inboxDirectory,
            withIntermediateDirectories: true
        )
    }

    private func save(_ items: [WatchRecordingInboxItem]) throws {
        try ensureDirectory()
        let data = try JSONEncoder().encode(items)
        try data.write(to: indexURL, options: .atomic)
    }

    private func sanitize(_ string: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = string.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars)
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
}
