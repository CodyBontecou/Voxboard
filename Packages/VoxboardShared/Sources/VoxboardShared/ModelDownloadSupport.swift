import Foundation

/// Truthful, transport-level state for an app-managed model download.
public struct ModelDownloadState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case preparing
        case listingFiles
        case transferring
        case verifying
        case cancelling
    }

    public var phase: Phase
    /// A real byte fraction when the transport provides one. Nil means the UI
    /// must remain indeterminate rather than presenting file count as bytes.
    public var fractionCompleted: Double?
    public var completedFiles: Int?
    public var totalFiles: Int?

    public init(
        phase: Phase,
        fractionCompleted: Double? = nil,
        completedFiles: Int? = nil,
        totalFiles: Int? = nil
    ) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted.map { min(max($0, 0), 1) }
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
    }

    public var isCancelling: Bool { phase == .cancelling }

    /// Progress callbacks are delivered asynchronously and may arrive after a
    /// cancellation or verification update. Keep phases monotonic so queued
    /// callbacks cannot make the UI claim that a terminal phase is transferring.
    func accepting(_ proposed: ModelDownloadState) -> ModelDownloadState {
        if phase == .cancelling { return self }
        if proposed.phase == .cancelling { return proposed }
        if proposed.phase.order < phase.order { return self }
        return proposed
    }

    public var fileProgressDescription: String? {
        guard let completedFiles, let totalFiles, totalFiles > 0 else { return nil }
        return String(localized: "\(completedFiles) of \(totalFiles) files complete", bundle: .main)
    }
}

private extension ModelDownloadState.Phase {
    var order: Int {
        switch self {
        case .preparing: return 0
        case .listingFiles: return 1
        case .transferring: return 2
        case .verifying: return 3
        case .cancelling: return 4
        }
    }
}

/// Pure helpers shared by model metadata, the manager, and deterministic tests.
struct ModelDownloadOperationRegistry {
    private var operationIDs: [String: UUID] = [:]

    mutating func reserve(modelID: String) -> UUID? {
        guard operationIDs[modelID] == nil else { return nil }
        let operationID = UUID()
        operationIDs[modelID] = operationID
        return operationID
    }

    func owns(modelID: String, operationID: UUID) -> Bool {
        operationIDs[modelID] == operationID
    }

    @discardableResult
    mutating func release(modelID: String, operationID: UUID) -> Bool {
        guard owns(modelID: modelID, operationID: operationID) else { return false }
        operationIDs[modelID] = nil
        return true
    }
}

enum ModelDownloadStorage {
    static func requiredCapacity(forDownloadSize downloadSize: Int64) -> Int64 {
        let headroom = max(128_000_000, downloadSize / 5)
        return downloadSize + headroom
    }

    static func availableCapacity(at directory: URL) -> Int64? {
        try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
    }
}

enum WhisperModelDownloadValidationError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case sizeMismatch(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "The model server returned an invalid response.", bundle: .main)
        case .httpStatus(let status):
            return String(localized: "The model server returned HTTP \(status).", bundle: .main)
        case .sizeMismatch(let expected, let actual):
            let expectedText = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
            let actualText = ByteCountFormatter.string(fromByteCount: actual, countStyle: .file)
            return String(
                localized: "The downloaded model was incomplete (expected \(expectedText), received \(actualText)).",
                bundle: .main
            )
        }
    }
}

struct WhisperModelDownloadResult: Sendable {
    let fileURL: URL
    let response: HTTPURLResponse
}

enum WhisperModelDownloadValidator {
    static func validate(
        response: URLResponse,
        fileURL: URL,
        expectedByteCount: Int64
    ) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperModelDownloadValidationError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WhisperModelDownloadValidationError.httpStatus(httpResponse.statusCode)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let actualByteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualByteCount == expectedByteCount else {
            throw WhisperModelDownloadValidationError.sizeMismatch(
                expected: expectedByteCount,
                actual: max(0, actualByteCount)
            )
        }
        return httpResponse
    }
}

enum WhisperModelInstaller {
    /// Validation happens before any destination mutation. Because the staging
    /// file is on the models volume, move/replace completes without a cross-volume
    /// copy exposing a partially installed model.
    static func validateAndInstall(
        response: URLResponse,
        stagingURL: URL,
        destinationURL: URL,
        expectedByteCount: Int64
    ) throws {
        _ = try WhisperModelDownloadValidator.validate(
            response: response,
            fileURL: stagingURL,
            expectedByteCount: expectedByteCount
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(
                destinationURL,
                withItemAt: stagingURL
            )
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
        }
    }
}

/// Explicit URLSessionDownloadTask bridge. Foundation's async download(from:)
/// convenience does not forward incremental didWriteData callbacks to a session
/// delegate, so model downloads must drive a real download task.
enum WhisperModelDownloadTransport {
    static func download(
        request: URLRequest,
        stagingURL: URL,
        configuration: URLSessionConfiguration = .default,
        onProgress: @escaping @Sendable (_ received: Int64, _ expected: Int64) -> Void
    ) async throws -> WhisperModelDownloadResult {
        let delegate = WhisperDownloadTaskDelegate(
            stagingURL: stagingURL,
            onProgress: onProgress
        )
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request)
                delegate.attach(continuation: continuation, task: task)
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

final class WhisperDownloadTaskDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<WhisperModelDownloadResult, Error>?
        var task: URLSessionDownloadTask?
        var moveError: Error?
        var stagedFileExists = false
        var cancelledBeforeAttach = false
        var completed = false
    }

    private let stagingURL: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var state = State()

    init(
        stagingURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.stagingURL = stagingURL
        self.onProgress = onProgress
    }

    func attach(
        continuation: CheckedContinuation<WhisperModelDownloadResult, Error>,
        task: URLSessionDownloadTask
    ) {
        let shouldCancel = lock.withLock { () -> Bool in
            state.continuation = continuation
            state.task = task
            return state.cancelledBeforeAttach
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionDownloadTask? in
            state.cancelledBeforeAttach = true
            return state.task
        }
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.createDirectory(
                at: stagingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try FileManager.default.removeItem(at: stagingURL)
            }
            try FileManager.default.moveItem(at: location, to: stagingURL)
            lock.withLock { state.stagedFileExists = true }
        } catch {
            lock.withLock { state.moveError = error }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let completion = lock.withLock {
            () -> (CheckedContinuation<WhisperModelDownloadResult, Error>, Error?, Bool)? in
            guard !state.completed, let continuation = state.continuation else { return nil }
            state.completed = true
            state.continuation = nil
            return (continuation, state.moveError ?? error, state.stagedFileExists)
        }
        guard let (continuation, completionError, stagedFileExists) = completion else { return }

        if let completionError {
            if (completionError as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: completionError)
            }
            return
        }
        guard stagedFileExists, let response = task.response as? HTTPURLResponse else {
            continuation.resume(throwing: WhisperModelDownloadValidationError.invalidResponse)
            return
        }
        continuation.resume(returning: WhisperModelDownloadResult(
            fileURL: stagingURL,
            response: response
        ))
    }
}
