import Foundation

public enum CaptureHistoryOutcome: String, Codable, CaseIterable, Sendable {
    case delivered
    case failed
}

/// A deliberately coarse failure classification. Unlike an underlying error's
/// message, these values are safe to persist and show to a user.
public enum CaptureHistoryFailureCategory: String, Codable, CaseIterable, Sendable {
    case destinationUnavailable
    case permissionDenied
    case invalidRequest
    case attachment
    case fileWrite
    case storage
    case unknown

    public var displayName: String {
        switch self {
        case .destinationUnavailable:
            return "Destination unavailable"
        case .permissionDenied:
            return "Permission required"
        case .invalidRequest:
            return "Capture could not be processed"
        case .attachment:
            return "Attachment could not be saved"
        case .fileWrite:
            return "Note could not be updated"
        case .storage:
            return "History storage unavailable"
        case .unknown:
            return "Delivery failed"
        }
    }
}

public enum CaptureHistoryError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedRecordSchemaVersion(Int)
    case unsupportedFileSchemaVersion(Int)
    case invalidAttachmentCount(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedRecordSchemaVersion(let version):
            return "Capture history record schema version \(version) is not supported."
        case .unsupportedFileSchemaVersion(let version):
            return "Capture history file schema version \(version) is not supported."
        case .invalidAttachmentCount(let count):
            return "Capture history attachment count cannot be negative: \(count)."
        }
    }
}

/// Privacy-limited delivery metadata. This model intentionally has no fields
/// for captured content, URLs, coordinates, filesystem roots, bookmark data,
/// or attachment names.
public struct CaptureHistoryRecord: Identifiable, Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var requestID: UUID
    public var createdAt: Date
    public var deliveredAt: Date?
    public var source: CaptureSource
    public var outcome: CaptureHistoryOutcome
    public var destinationID: UUID
    public var destinationName: String
    public var voxID: String?
    public var voxName: String?
    public var relativeNotePath: String?
    public var attachmentCount: Int
    public var failureCategory: CaptureHistoryFailureCategory?

    public var id: UUID { requestID }

    /// An explicit snapshot alias for clients that prefer to distinguish this
    /// value from a live destination name.
    public var destinationNameSnapshot: String {
        get { destinationName }
        set { destinationName = newValue }
    }

    public static func relativeNotePath(noteURL: URL, rootURL: URL) -> String? {
        let rootPath = rootURL.standardizedFileURL.path
        let notePath = noteURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard notePath.hasPrefix(prefix) else { return nil }
        let relativePath = String(notePath.dropFirst(prefix.count))
        guard (try? CapturePathValidation.validateRelativePath(relativePath)) != nil else { return nil }
        return relativePath
    }

    public init(
        requestID: UUID,
        createdAt: Date,
        deliveredAt: Date?,
        source: CaptureSource,
        outcome: CaptureHistoryOutcome,
        destinationID: UUID,
        destinationName: String,
        voxID: String? = nil,
        voxName: String? = nil,
        relativeNotePath: String?,
        attachmentCount: Int,
        failureCategory: CaptureHistoryFailureCategory? = nil
    ) throws {
        try Self.validate(relativeNotePath: relativeNotePath, attachmentCount: attachmentCount)
        self.schemaVersion = Self.currentSchemaVersion
        self.requestID = requestID
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.source = source
        self.outcome = outcome
        self.destinationID = destinationID
        self.destinationName = destinationName
        self.voxID = voxID
        self.voxName = voxName
        self.relativeNotePath = relativeNotePath
        self.attachmentCount = attachmentCount
        self.failureCategory = failureCategory
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case requestID
        case createdAt
        case deliveredAt
        case source
        case outcome
        case destinationID
        case destinationName
        case voxID
        case voxName
        case relativeNotePath
        case attachmentCount
        case failureCategory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CaptureHistoryError.unsupportedRecordSchemaVersion(schemaVersion)
        }
        try self.init(
            requestID: container.decode(UUID.self, forKey: .requestID),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            deliveredAt: container.decodeIfPresent(Date.self, forKey: .deliveredAt),
            source: container.decode(CaptureSource.self, forKey: .source),
            outcome: container.decode(CaptureHistoryOutcome.self, forKey: .outcome),
            destinationID: container.decode(UUID.self, forKey: .destinationID),
            destinationName: container.decode(String.self, forKey: .destinationName),
            voxID: container.decodeIfPresent(String.self, forKey: .voxID),
            voxName: container.decodeIfPresent(String.self, forKey: .voxName),
            relativeNotePath: container.decodeIfPresent(String.self, forKey: .relativeNotePath),
            attachmentCount: container.decode(Int.self, forKey: .attachmentCount),
            failureCategory: container.decodeIfPresent(
                CaptureHistoryFailureCategory.self,
                forKey: .failureCategory
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CaptureHistoryError.unsupportedRecordSchemaVersion(schemaVersion)
        }
        try Self.validate(relativeNotePath: relativeNotePath, attachmentCount: attachmentCount)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(deliveredAt, forKey: .deliveredAt)
        try container.encode(source, forKey: .source)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(destinationID, forKey: .destinationID)
        try container.encode(destinationName, forKey: .destinationName)
        try container.encodeIfPresent(voxID, forKey: .voxID)
        try container.encodeIfPresent(voxName, forKey: .voxName)
        try container.encodeIfPresent(relativeNotePath, forKey: .relativeNotePath)
        try container.encode(attachmentCount, forKey: .attachmentCount)
        try container.encodeIfPresent(failureCategory, forKey: .failureCategory)
    }

    fileprivate func validateForPersistence() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CaptureHistoryError.unsupportedRecordSchemaVersion(schemaVersion)
        }
        try Self.validate(relativeNotePath: relativeNotePath, attachmentCount: attachmentCount)
    }

    private static func validate(relativeNotePath: String?, attachmentCount: Int) throws {
        guard attachmentCount >= 0 else {
            throw CaptureHistoryError.invalidAttachmentCount(attachmentCount)
        }
        guard let relativeNotePath else { return }
        try CapturePathValidation.validateRelativePath(relativeNotePath)

        // CapturePathValidation rejects POSIX absolute paths, backslash-based
        // Windows paths, and traversal. Reject URL schemes and drive-letter
        // paths as well so this metadata can only contain a relative note path.
        let firstComponent = relativeNotePath.split(separator: "/", maxSplits: 1).first
        if firstComponent?.contains(":") == true {
            throw CaptureModelError.invalidRelativePath(relativeNotePath)
        }
    }
}

public enum CaptureHistoryWriteOperation: String, Equatable, Sendable {
    case upsert
    case remove
    case clear
}

/// A dedicated persistence error lets capture delivery succeed independently
/// of this best-effort history write.
public struct CaptureHistoryWriteError: Error, LocalizedError, @unchecked Sendable {
    public let operation: CaptureHistoryWriteOperation
    public let underlyingError: any Error

    public init(operation: CaptureHistoryWriteOperation, underlyingError: any Error) {
        self.operation = operation
        self.underlyingError = underlyingError
    }

    public var errorDescription: String? {
        "Capture delivery succeeded, but its history could not be updated during \(operation.rawValue): "
            + underlyingError.localizedDescription
    }
}

private struct CaptureHistoryFile: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var records: [CaptureHistoryRecord]

    init(records: [CaptureHistoryRecord]) {
        schemaVersion = Self.currentSchemaVersion
        self.records = records
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case records
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.records) else {
            throw DecodingError.dataCorruptedError(
                forKey: .records,
                in: container,
                debugDescription: "Capture history file has no records field."
            )
        }
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CaptureHistoryError.unsupportedFileSchemaVersion(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.records = try container.decode([CaptureHistoryRecord].self, forKey: .records)
    }
}

public actor CaptureHistoryStore {
    public static let defaultMaximumRecordCount = 500

    public nonisolated let fileURL: URL
    public nonisolated let maximumRecordCount: Int

    private let coordinator: any CaptureFileCoordinating
    private let fileManager: FileManager
    private let activityStatsStore: ActivityStatsStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public nonisolated var quarantineDirectoryURL: URL {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-corrupt", isDirectory: true)
    }

    public init(
        fileURL: URL,
        coordinator: any CaptureFileCoordinating = NSFileCoordinatorCaptureFileCoordinator.shared,
        maximumRecordCount: Int = CaptureHistoryStore.defaultMaximumRecordCount,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.coordinator = coordinator
        self.maximumRecordCount = max(0, maximumRecordCount)
        self.fileManager = fileManager
        self.activityStatsStore = ActivityStatsStore(
            fileURL: fileURL.deletingLastPathComponent()
                .appendingPathComponent(ActivityStatsStore.defaultFilename),
            coordinator: coordinator,
            fileManager: fileManager
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public init(
        fileURL: URL,
        coordinator: any CaptureFileCoordinating = NSFileCoordinatorCaptureFileCoordinator.shared,
        maxRecords: Int,
        fileManager: FileManager = .default
    ) {
        self.init(
            fileURL: fileURL,
            coordinator: coordinator,
            maximumRecordCount: maxRecords,
            fileManager: fileManager
        )
    }

    /// Loads a fresh coordinated snapshot every time; no actor-local cache can
    /// hide changes made by another process.
    public func load() throws -> [CaptureHistoryRecord] {
        try coordinator.coordinateWriting(at: fileURL) { coordinatedURL in
            try loadLatest(from: coordinatedURL)
        }
    }

    public func list() throws -> [CaptureHistoryRecord] {
        try load()
    }

    /// Replaces the record for the same request ID. Retrying a failed request
    /// therefore updates its one history row instead of adding a duplicate.
    @discardableResult
    public func upsert(_ record: CaptureHistoryRecord) throws -> CaptureHistoryRecord {
        do {
            try record.validateForPersistence()
            let persisted = try coordinator.coordinateWriting(at: fileURL) { coordinatedURL in
                var records = try loadLatest(from: coordinatedURL)
                records.removeAll { $0.requestID == record.requestID }
                records.append(record)
                records = normalized(records)
                try persist(records, to: coordinatedURL)
                return record
            }
            if persisted.outcome == .delivered {
                // Stats are best-effort and must never turn a completed Capture
                // into a reported delivery failure.
                _ = try? activityStatsStore.record(CaptureActivityEvent(
                    id: persisted.requestID,
                    date: persisted.deliveredAt ?? persisted.createdAt,
                    source: persisted.source,
                    attachmentCount: persisted.attachmentCount
                ))
            }
            return persisted
        } catch let error as CaptureHistoryWriteError {
            throw error
        } catch {
            throw CaptureHistoryWriteError(operation: .upsert, underlyingError: error)
        }
    }

    public func remove(requestIDs: Set<UUID>) throws {
        guard !requestIDs.isEmpty else { return }
        do {
            try coordinator.coordinateWriting(at: fileURL) { coordinatedURL in
                let records = try loadLatest(from: coordinatedURL)
                    .filter { !requestIDs.contains($0.requestID) }
                if records.isEmpty {
                    if fileManager.fileExists(atPath: coordinatedURL.path) {
                        try fileManager.removeItem(at: coordinatedURL)
                    }
                } else {
                    try persist(records, to: coordinatedURL)
                }
            }
        } catch let error as CaptureHistoryWriteError {
            throw error
        } catch {
            throw CaptureHistoryWriteError(operation: .remove, underlyingError: error)
        }
    }

    public func clear() throws {
        do {
            try coordinator.coordinateWriting(at: fileURL) { coordinatedURL in
                guard fileManager.fileExists(atPath: coordinatedURL.path) else { return }
                try fileManager.removeItem(at: coordinatedURL)
            }
        } catch let error as CaptureHistoryWriteError {
            throw error
        } catch {
            throw CaptureHistoryWriteError(operation: .clear, underlyingError: error)
        }
    }

    /// Convenience for callers that intentionally treat history as
    /// best-effort while still retaining an error for logging or diagnostics.
    @discardableResult
    public func upsertBestEffort(_ record: CaptureHistoryRecord) -> CaptureHistoryWriteError? {
        do {
            try upsert(record)
            return nil
        } catch let error as CaptureHistoryWriteError {
            return error
        } catch {
            return CaptureHistoryWriteError(operation: .upsert, underlyingError: error)
        }
    }

    @discardableResult
    public func clearBestEffort() -> CaptureHistoryWriteError? {
        do {
            try clear()
            return nil
        } catch let error as CaptureHistoryWriteError {
            return error
        } catch {
            return CaptureHistoryWriteError(operation: .clear, underlyingError: error)
        }
    }

    private func loadLatest(from url: URL) throws -> [CaptureHistoryRecord] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        do {
            let records: [CaptureHistoryRecord]
            if firstNonWhitespaceByte(in: data) == UInt8(ascii: "[") {
                // Legacy v0 files were a bare array. The next successful write
                // migrates them to the versioned envelope.
                records = try decoder.decode([CaptureHistoryRecord].self, from: data)
            } else {
                records = try decoder.decode(CaptureHistoryFile.self, from: data).records
            }
            return normalized(records)
        } catch let error as CaptureHistoryError {
            switch error {
            case .unsupportedRecordSchemaVersion, .unsupportedFileSchemaVersion:
                // A newer app may own this file. Never move or overwrite it.
                throw error
            case .invalidAttachmentCount:
                try quarantineCorruptFile(at: url)
                return []
            }
        } catch {
            try quarantineCorruptFile(at: url)
            return []
        }
    }

    private func persist(_ records: [CaptureHistoryRecord], to url: URL) throws {
        let data = try encoder.encode(CaptureHistoryFile(records: records))
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func normalized(_ records: [CaptureHistoryRecord]) -> [CaptureHistoryRecord] {
        var unique: [UUID: CaptureHistoryRecord] = [:]
        for record in records {
            if let existing = unique[record.requestID] {
                if Self.isNewer(record, than: existing) {
                    unique[record.requestID] = record
                }
            } else {
                unique[record.requestID] = record
            }
        }
        return Array(unique.values)
            .sorted(by: Self.newestFirst)
            .prefix(maximumRecordCount)
            .map { $0 }
    }

    private static func isNewer(
        _ candidate: CaptureHistoryRecord,
        than existing: CaptureHistoryRecord
    ) -> Bool {
        let candidateDate = candidate.deliveredAt ?? candidate.createdAt
        let existingDate = existing.deliveredAt ?? existing.createdAt
        if candidateDate != existingDate { return candidateDate > existingDate }
        return candidate.createdAt >= existing.createdAt
    }

    private static func newestFirst(
        _ lhs: CaptureHistoryRecord,
        _ rhs: CaptureHistoryRecord
    ) -> Bool {
        let lhsDate = lhs.deliveredAt ?? lhs.createdAt
        let rhsDate = rhs.deliveredAt ?? rhs.createdAt
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.requestID.uuidString < rhs.requestID.uuidString
    }

    private func quarantineCorruptFile(at sourceURL: URL) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        try fileManager.createDirectory(
            at: quarantineDirectoryURL,
            withIntermediateDirectories: true
        )
        var destinationURL = quarantineDirectoryURL
            .appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
        if fileManager.fileExists(atPath: destinationURL.path) {
            let stem = sourceURL.deletingPathExtension().lastPathComponent
            let suffix = UUID().uuidString.lowercased()
            let filename = sourceURL.pathExtension.isEmpty
                ? "\(stem)-\(suffix)"
                : "\(stem)-\(suffix).\(sourceURL.pathExtension)"
            destinationURL = quarantineDirectoryURL
                .appendingPathComponent(filename, isDirectory: false)
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    private func firstNonWhitespaceByte(in data: Data) -> UInt8? {
        data.first { byte in
            byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D
        }
    }
}
