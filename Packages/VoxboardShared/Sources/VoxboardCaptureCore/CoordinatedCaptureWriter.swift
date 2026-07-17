import Foundation

public protocol CaptureFileCoordinating: Sendable {
    func coordinateWriting<T>(at url: URL, _ accessor: (URL) throws -> T) throws -> T
}

public final class ProcessLocalCaptureFileCoordinator: CaptureFileCoordinating, @unchecked Sendable {
    public static let shared = ProcessLocalCaptureFileCoordinator()

    private let lock = NSRecursiveLock()

    public init() {}

    public func coordinateWriting<T>(at url: URL, _ accessor: (URL) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try accessor(url)
    }
}

/// Coordinates writes with document providers and other app extensions. A
/// process-local lock covers callers in this process while NSFileCoordinator
/// provides the cross-process/document-provider boundary.
public final class NSFileCoordinatorCaptureFileCoordinator: CaptureFileCoordinating, @unchecked Sendable {
    public static let shared = NSFileCoordinatorCaptureFileCoordinator()

    private let processCoordinator: ProcessLocalCaptureFileCoordinator

    public init(processCoordinator: ProcessLocalCaptureFileCoordinator = .shared) {
        self.processCoordinator = processCoordinator
    }

    public func coordinateWriting<T>(at url: URL, _ accessor: (URL) throws -> T) throws -> T {
        try processCoordinator.coordinateWriting(at: url) { lockedURL in
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var result: Result<T, Error>?
            coordinator.coordinate(
                writingItemAt: lockedURL,
                options: .forMerging,
                error: &coordinationError
            ) { coordinatedURL in
                result = Result { try accessor(coordinatedURL) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else {
                throw CaptureWriteError.coordinatorDidNotRun
            }
            return try result.get()
        }
    }
}

public enum CaptureWriteError: Error, Equatable, LocalizedError, Sendable {
    case coordinatorDidNotRun
    case verificationFailed(UUID)

    public var errorDescription: String? {
        switch self {
        case .coordinatorDidNotRun:
            return "The file coordinator did not perform the capture write."
        case .verificationFailed(let requestID):
            return "The capture write could not be verified for request \(requestID.uuidString)."
        }
    }
}

public struct CaptureWriteReceipt: Equatable, Sendable {
    public var fileURL: URL
    public var requestID: UUID
    public var byteCount: Int
    public var wasAlreadyApplied: Bool

    public init(fileURL: URL, requestID: UUID, byteCount: Int, wasAlreadyApplied: Bool) {
        self.fileURL = fileURL
        self.requestID = requestID
        self.byteCount = byteCount
        self.wasAlreadyApplied = wasAlreadyApplied
    }
}

public enum CaptureRequestMarker: Sendable {
    public static func text(for requestID: UUID) -> String {
        "<!-- vox-capture:\(requestID.uuidString.lowercased()) -->"
    }

    public static func isPresent(in markdown: String, requestID: UUID) -> Bool {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .contains(text(for: requestID))
    }
}

public protocol CaptureMutationWriting: Sendable {
    func write(_ mutation: MarkdownCaptureMutation, to fileURL: URL) async throws -> CaptureWriteReceipt
}

public actor CoordinatedCaptureWriter: CaptureMutationWriting {
    private let coordinator: any CaptureFileCoordinating
    private let editor: MarkdownDocumentEditor
    private let fileManager: FileManager

    public init(
        coordinator: any CaptureFileCoordinating = NSFileCoordinatorCaptureFileCoordinator.shared,
        editor: MarkdownDocumentEditor = MarkdownDocumentEditor(),
        fileManager: FileManager = .default
    ) {
        self.coordinator = coordinator
        self.editor = editor
        self.fileManager = fileManager
    }

    public func write(
        _ mutation: MarkdownCaptureMutation,
        to fileURL: URL
    ) async throws -> CaptureWriteReceipt {
        try coordinator.coordinateWriting(at: fileURL) { coordinatedURL in
            let marker = CaptureRequestMarker.text(for: mutation.requestID)
            let secureLocation = mutation.destinationRootURL.flatMap { root in
                mutation.relativeNotePath.map { (root: root, relativePath: $0) }
            }
            let existing: String
            if let secureLocation,
               let data = try SecureCaptureFileIO.read(
                    relativePath: secureLocation.relativePath,
                    rootURL: secureLocation.root
               ) {
                guard let decoded = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                existing = decoded
            } else if secureLocation != nil {
                existing = ""
            } else if fileManager.fileExists(atPath: coordinatedURL.path) {
                existing = try String(contentsOf: coordinatedURL, encoding: .utf8)
            } else {
                existing = ""
            }
            let wasAlreadyApplied = CaptureRequestMarker.isPresent(
                in: existing,
                requestID: mutation.requestID
            )
            let edited = try editor.applying(mutation, to: existing)

            if !wasAlreadyApplied {
                if let secureLocation {
                    try SecureCaptureFileIO.writeAtomically(
                        Data(edited.utf8),
                        relativePath: secureLocation.relativePath,
                        rootURL: secureLocation.root
                    )
                } else {
                    try fileManager.createDirectory(
                        at: coordinatedURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data(edited.utf8).write(to: coordinatedURL, options: .atomic)
                }
            }

            let verified: String
            if let secureLocation,
               let data = try SecureCaptureFileIO.read(
                    relativePath: secureLocation.relativePath,
                    rootURL: secureLocation.root
               ), let decoded = String(data: data, encoding: .utf8) {
                verified = decoded
            } else {
                verified = try String(contentsOf: coordinatedURL, encoding: .utf8)
            }
            let writeWasVerified: Bool
            if wasAlreadyApplied || mutation.retryProtectionEnabled {
                writeWasVerified = verified.contains(marker)
            } else {
                writeWasVerified = verified == edited
            }
            guard writeWasVerified else {
                throw CaptureWriteError.verificationFailed(mutation.requestID)
            }
            return CaptureWriteReceipt(
                fileURL: coordinatedURL,
                requestID: mutation.requestID,
                byteCount: verified.utf8.count,
                wasAlreadyApplied: wasAlreadyApplied
            )
        }
    }
}
