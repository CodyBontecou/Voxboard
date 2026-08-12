import Foundation
import VoxboardCaptureCore

public struct CaptureRecordingOriginSnapshot: Codable, Equatable, Sendable {
    public var presetID: String
    public var source: CaptureSource
    public var outcome: CaptureLocationOutcome

    public init(presetID: String, source: CaptureSource, outcome: CaptureLocationOutcome) {
        self.presetID = presetID
        self.source = source
        self.outcome = outcome
    }
}

/// Short-lived durable seam between recording stop and creation of the final
/// transcript CaptureRequest. It prevents a crash or long transcription from
/// replacing the origin result with a later location.
public actor CaptureRecordingOriginStore {
    private let directoryURL: URL
    private let fileManager: FileManager

    public init(rootDirectoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = rootDirectoryURL.appendingPathComponent(
            "recording-origin-location",
            isDirectory: true
        )
        self.fileManager = fileManager
    }

    public func save(_ snapshot: CaptureRecordingOriginSnapshot, recordingID: String) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url(for: recordingID), options: .atomic)
    }

    public func load(recordingID: String) throws -> CaptureRecordingOriginSnapshot? {
        let url = url(for: recordingID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(
            CaptureRecordingOriginSnapshot.self,
            from: Data(contentsOf: url)
        )
    }

    @discardableResult
    public func purge(olderThan interval: TimeInterval, now: Date = Date()) throws -> Int {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return 0 }
        var count = 0
        for url in try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let date = try url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(date) >= interval else { continue }
            try fileManager.removeItem(at: url)
            count += 1
        }
        return count
    }

    public func remove(recordingID: String) throws {
        let url = url(for: recordingID)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func url(for recordingID: String) -> URL {
        // URL-safe base64 prevents IPC identifiers from becoming path input.
        let encoded = Data(recordingID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directoryURL.appendingPathComponent(String(encoded.prefix(180))).appendingPathExtension("json")
    }
}

public extension CaptureSource {
    static func recordingSource(
        for origin: RecordingCommand.Origin?,
        overriding explicitSource: CaptureSource? = nil
    ) -> CaptureSource? {
        if let explicitSource { return explicitSource }
        switch origin {
        case .keyboardExtension:
            return .keyboard
        case .quickRecord, .liveActivity:
            return .widget
        case .watch:
            return .watch
        case .inAppDraft:
            return .app
        case .inAppImmediate, nil:
            return .voice
        }
    }
}
