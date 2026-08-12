import CryptoKit
import Foundation

/// App-private write-ahead transaction for publishing one user-facing file.
///
/// The staged payload and journal are durable before the destination changes.
/// A retry can therefore distinguish this delivery's completed write from a
/// different delivery with identical bytes. Callers remove the transaction only
/// after their durable queue checkpoint has been persisted.
public struct ExternalFileDeliveryTransaction: Sendable {
    public struct PublishedFile: Equatable, Sendable {
        public let url: URL
        public let byteCount: Int

        public init(url: URL, byteCount: Int) {
            self.url = url
            self.byteCount = byteCount
        }
    }

    public enum TargetExpectation: Sendable {
        case missing
        case contents(Data)
    }

    public enum TransactionError: LocalizedError, Equatable {
        case incompleteJournal
        case stagedPayloadChanged
        case targetWasNotMissing
        case destinationConflict
        case publishedPayloadMismatch

        public var errorDescription: String? {
            switch self {
            case .incompleteJournal:
                "The pending export transaction is incomplete."
            case .stagedPayloadChanged:
                "The pending export payload could not be verified."
            case .targetWasNotMissing:
                "The selected export filename became occupied before it could be written."
            case .destinationConflict:
                "The export destination changed while this delivery was pending."
            case .publishedPayloadMismatch:
                "The exported file could not be verified after it was written."
            }
        }
    }

    private struct FileSnapshot: Codable, Equatable {
        var exists: Bool
        var digest: String?
        var byteCount: Int

        static let missing = FileSnapshot(exists: false, digest: nil, byteCount: 0)
    }

    private struct Journal: Codable {
        static let currentVersion = 1

        var version: Int
        var targetPath: String
        var preimage: FileSnapshot
        var postimage: FileSnapshot
    }

    public let directoryURL: URL
    private let beforeCoordinatedPublish: (@Sendable () throws -> Void)?

    private var journalURL: URL {
        directoryURL.appendingPathComponent("journal.json", isDirectory: false)
    }

    private var stagedPayloadURL: URL {
        directoryURL.appendingPathComponent("payload", isDirectory: false)
    }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.beforeCoordinatedPublish = nil
    }

    init(
        directoryURL: URL,
        beforeCoordinatedPublish: @escaping @Sendable () throws -> Void
    ) {
        self.directoryURL = directoryURL
        self.beforeCoordinatedPublish = beforeCoordinatedPublish
    }

    /// Returns nil when no prepared transaction exists. Otherwise it verifies
    /// and, when needed, publishes the already-staged payload.
    public func resumeIfPrepared() throws -> PublishedFile? {
        let fileManager = FileManager.default
        let journalExists = fileManager.fileExists(atPath: journalURL.path)
        let payloadExists = fileManager.fileExists(atPath: stagedPayloadURL.path)
        guard journalExists || payloadExists else { return nil }
        if payloadExists, !journalExists {
            // The destination cannot have changed before the journal is durable.
            // A crash during preparation may therefore discard this uncommitted
            // stage and safely start planning again.
            try? fileManager.removeItem(at: stagedPayloadURL)
            return nil
        }
        guard journalExists, payloadExists else { throw TransactionError.incompleteJournal }

        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        guard journal.version == Journal.currentVersion else {
            throw TransactionError.incompleteJournal
        }
        let stagedData = try Data(contentsOf: stagedPayloadURL)
        guard snapshot(of: stagedData) == journal.postimage else {
            throw TransactionError.stagedPayloadChanged
        }

        let targetURL = URL(fileURLWithPath: journal.targetPath)
        let current = try snapshot(at: targetURL)
        if current == journal.postimage {
            return PublishedFile(url: targetURL, byteCount: journal.postimage.byteCount)
        }
        guard current == journal.preimage else {
            throw TransactionError.destinationConflict
        }

        try publishCoordinated(
            stagedData,
            to: targetURL,
            expectedPreimage: journal.preimage,
            expectedPostimage: journal.postimage
        )
        return PublishedFile(url: targetURL, byteCount: journal.postimage.byteCount)
    }

    /// Stages and journals a payload before atomically publishing it. The
    /// transaction remains durable until `clear()` is called after the queue's
    /// own exported-file checkpoint succeeds.
    public func prepareAndPublish(
        data: Data,
        to targetURL: URL,
        expecting expectation: TargetExpectation
    ) throws -> PublishedFile {
        if let resumed = try resumeIfPrepared() {
            return resumed
        }

        let preimage = try snapshot(at: targetURL)
        switch expectation {
        case .missing:
            guard !preimage.exists else {
                throw TransactionError.targetWasNotMissing
            }
        case .contents(let expectedData):
            guard preimage == snapshot(of: expectedData) else {
                throw TransactionError.destinationConflict
            }
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: stagedPayloadURL, options: .atomic)

        let journal = Journal(
            version: Journal.currentVersion,
            targetPath: targetURL.standardizedFileURL.path,
            preimage: preimage,
            postimage: snapshot(of: data)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: journalURL, options: .atomic)

        guard let published = try resumeIfPrepared() else {
            throw TransactionError.incompleteJournal
        }
        return published
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func publishCoordinated(
        _ data: Data,
        to targetURL: URL,
        expectedPreimage: FileSnapshot,
        expectedPostimage: FileSnapshot
    ) throws {
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(
            writingItemAt: targetURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                guard try snapshot(at: coordinatedURL) == expectedPreimage else {
                    throw TransactionError.destinationConflict
                }
                try beforeCoordinatedPublish?()
                // The second comparison both supports deterministic race tests
                // and catches non-coordinating writers that changed the file
                // while this coordinated replacement was being prepared.
                guard try snapshot(at: coordinatedURL) == expectedPreimage else {
                    throw TransactionError.destinationConflict
                }
                try data.write(to: coordinatedURL, options: .atomic)
                guard try snapshot(at: coordinatedURL) == expectedPostimage else {
                    throw TransactionError.publishedPayloadMismatch
                }
            } catch {
                operationError = error
            }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
    }

    private func snapshot(at url: URL) throws -> FileSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        return snapshot(of: try Data(contentsOf: url))
    }

    private func snapshot(of data: Data) -> FileSnapshot {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return FileSnapshot(exists: true, digest: digest, byteCount: data.count)
    }
}
