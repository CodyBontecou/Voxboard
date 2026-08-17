import Foundation
import XCTest
@testable import VoxboardShared

final class ModelDownloadSupportTests: XCTestCase {
    func testDownloadStateKeepsFileProgressIndeterminate() {
        let state = ModelDownloadState(
            phase: .transferring,
            completedFiles: 6,
            totalFiles: 23
        )

        XCTAssertNil(state.fractionCompleted)
        XCTAssertEqual(state.fileProgressDescription, "6 of 23 files complete")
    }

    func testDownloadStateClampsRealByteFractions() {
        XCTAssertEqual(
            ModelDownloadState(phase: .transferring, fractionCompleted: -0.5).fractionCompleted,
            0
        )
        XCTAssertEqual(
            ModelDownloadState(phase: .transferring, fractionCompleted: 1.5).fractionCompleted,
            1
        )
    }

    func testQueuedProgressCannotRegressVerifyingOrCancellingPhase() {
        let transferring = ModelDownloadState(phase: .transferring, fractionCompleted: 0.5)
        let verifying = ModelDownloadState(phase: .verifying, fractionCompleted: 1)
        let cancelling = ModelDownloadState(phase: .cancelling)

        XCTAssertEqual(verifying.accepting(transferring), verifying)
        XCTAssertEqual(cancelling.accepting(transferring), cancelling)
        XCTAssertEqual(transferring.accepting(cancelling), cancelling)
    }

    func testOperationRegistryRejectsRetryAndStaleCompletionUntilOwnerReleases() throws {
        var registry = ModelDownloadOperationRegistry()
        let first = try XCTUnwrap(registry.reserve(modelID: "medium"))

        XCTAssertNil(registry.reserve(modelID: "medium"))
        XCTAssertFalse(registry.release(modelID: "medium", operationID: UUID()))
        XCTAssertTrue(registry.owns(modelID: "medium", operationID: first))

        XCTAssertTrue(registry.release(modelID: "medium", operationID: first))
        let retry = try XCTUnwrap(registry.reserve(modelID: "medium"))
        XCTAssertNotEqual(first, retry)
        XCTAssertFalse(registry.owns(modelID: "medium", operationID: first))
        XCTAssertTrue(registry.owns(modelID: "medium", operationID: retry))
    }

    func testWhisperValidatorAcceptsOnlyExactSuccessfulResponse() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("model.bin")
        try Data([0, 1, 2, 3]).write(to: fileURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.test/model.bin")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))

        XCTAssertNoThrow(try WhisperModelDownloadValidator.validate(
            response: response,
            fileURL: fileURL,
            expectedByteCount: 4
        ))
    }

    func testWhisperValidatorRejectsHTTPError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("error-body.bin")
        try Data([0, 1, 2, 3]).write(to: fileURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.test/model.bin")!,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        ))

        XCTAssertThrowsError(try WhisperModelDownloadValidator.validate(
            response: response,
            fileURL: fileURL,
            expectedByteCount: 4
        )) { error in
            XCTAssertEqual(error as? WhisperModelDownloadValidationError, .httpStatus(404))
        }
    }

    func testWhisperValidatorRejectsTruncatedFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("truncated.bin")
        try Data([0, 1]).write(to: fileURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.test/model.bin")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))

        XCTAssertThrowsError(try WhisperModelDownloadValidator.validate(
            response: response,
            fileURL: fileURL,
            expectedByteCount: 4
        )) { error in
            XCTAssertEqual(
                error as? WhisperModelDownloadValidationError,
                .sizeMismatch(expected: 4, actual: 2)
            )
        }
    }

    func testFailedValidationPreservesExistingInstalledWhisperFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagingURL = directory.appendingPathComponent("staging.bin")
        let destinationURL = directory.appendingPathComponent("installed.bin")
        let installedData = Data("known-good".utf8)
        try Data("bad".utf8).write(to: stagingURL)
        try installedData.write(to: destinationURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.test/model.bin")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))

        XCTAssertThrowsError(try WhisperModelInstaller.validateAndInstall(
            response: response,
            stagingURL: stagingURL,
            destinationURL: destinationURL,
            expectedByteCount: 100
        ))
        XCTAssertEqual(try Data(contentsOf: destinationURL), installedData)
    }

    func testFailedHeaderValidationPreservesExistingInstalledWhisperFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagingURL = directory.appendingPathComponent("staging.bin")
        let destinationURL = directory.appendingPathComponent("installed.bin")
        let installedData = Data("good".utf8)
        try Data("nope".utf8).write(to: stagingURL)
        try installedData.write(to: destinationURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.test/model.bin")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))

        XCTAssertThrowsError(try WhisperModelInstaller.validateAndInstall(
            response: response,
            stagingURL: stagingURL,
            destinationURL: destinationURL,
            expectedByteCount: 4,
            expectedHeader: Data("good".utf8)
        )) { error in
            XCTAssertEqual(error as? WhisperModelDownloadValidationError, .contentMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: destinationURL), installedData)
    }

    func testWhisperInstalledCheckRequiresExactExpectedSize() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WhisperModelInfo(
            id: "fixture",
            name: "Fixture",
            fileName: "fixture.bin",
            sizeLabel: "4 bytes",
            downloadSizeBytes: 4,
            downloadURL: URL(string: "https://example.test/fixture.bin")!,
            isBundled: false
        )
        let fileURL = directory.appendingPathComponent(model.fileName)

        try Data([0, 1]).write(to: fileURL)
        XCTAssertFalse(model.isDownloaded(in: directory))

        try Data([0, 1, 2, 3]).write(to: fileURL)
        XCTAssertTrue(model.isDownloaded(in: directory))
    }

    func testParakeetInstalledCheckRequiresEveryNonemptyBundleArtifact() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WhisperModelInfo(
            id: "parakeet-fixture",
            name: "Parakeet Fixture",
            fileName: "parakeet-fixture",
            sizeLabel: "fixture",
            downloadSizeBytes: 100,
            downloadURL: URL(string: "https://example.test/parakeet")!,
            isBundled: false,
            engine: .parakeetV3
        )
        let repoDirectory = directory.appendingPathComponent(
            try XCTUnwrap(model.engine.parakeetRepoFolderName),
            isDirectory: true
        )

        let expectedArtifacts = try XCTUnwrap(model.engine.parakeetExpectedArtifactSizes)
        for (relativePath, expectedByteCount) in expectedArtifacts {
            let url = repoDirectory.appendingPathComponent(relativePath)
            if URL(fileURLWithPath: relativePath).pathExtension.lowercased() == "json" {
                try createValidJSONFile(at: url, byteCount: expectedByteCount)
            } else {
                try createSparseFile(at: url, byteCount: expectedByteCount)
            }
        }
        XCTAssertTrue(model.isDownloaded(in: directory))

        let corruptRelativePath = try XCTUnwrap(expectedArtifacts.keys.sorted().first)
        let corruptURL = repoDirectory.appendingPathComponent(corruptRelativePath)
        try createSparseFile(at: corruptURL, byteCount: 1)
        XCTAssertFalse(model.isDownloaded(in: directory))

        try model.removeInvalidExistingParakeetArtifacts(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
        XCTAssertTrue(expectedArtifacts.keys
            .filter { $0 != corruptRelativePath }
            .allSatisfy { FileManager.default.fileExists(
                atPath: repoDirectory.appendingPathComponent($0).path
            ) })

        let metadataRelativePath = try XCTUnwrap(
            expectedArtifacts.keys.first { $0.hasSuffix("metadata.json") }
        )
        let metadataURL = repoDirectory.appendingPathComponent(metadataRelativePath)
        try createSparseFile(
            at: metadataURL,
            byteCount: try XCTUnwrap(expectedArtifacts[metadataRelativePath])
        )
        XCTAssertFalse(model.isDownloaded(in: directory))
        try model.removeInvalidExistingParakeetArtifacts(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func testCapacityPreflightIncludesProportionalHeadroom() {
        XCTAssertEqual(
            ModelDownloadStorage.requiredCapacity(forDownloadSize: 1_000_000_000),
            1_200_000_000
        )
        XCTAssertEqual(
            ModelDownloadStorage.requiredCapacity(forDownloadSize: 10_000_000),
            138_000_000
        )
    }

    func testExplicitDownloadTaskCancellationThrowsAndDoesNotStagePartialFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagingURL = directory.appendingPathComponent("cancelled.partial")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadStubURLProtocol.self]

        let download = Task {
            try await WhisperModelDownloadTransport.download(
                request: URLRequest(url: URL(string: "https://example.test/slow-model.bin")!),
                stagingURL: stagingURL,
                configuration: configuration
            ) { _, _ in }
        }
        try await Task.sleep(for: .milliseconds(50))
        download.cancel()

        do {
            _ = try await download.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    }

    func testDownloadDelegateForwardsIntermediateByteProgress() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let progress = LockedProgressValues()
        let delegate = WhisperDownloadTaskDelegate(
            stagingURL: directory.appendingPathComponent("unused.bin")
        ) { received, expected in
            progress.append(received: received, expected: expected)
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(
            with: URL(string: "https://example.test/model.bin")!
        )

        delegate.urlSession(
            session,
            downloadTask: task,
            didWriteData: 4,
            totalBytesWritten: 4,
            totalBytesExpectedToWrite: 10
        )

        XCTAssertEqual(progress.values.first?.received, 4)
        XCTAssertEqual(progress.values.first?.expected, 10)
        session.invalidateAndCancel()
    }

    func testExplicitDownloadTaskReportsProgressAndStagesFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagingURL = directory.appendingPathComponent("staged.bin")
        let progress = LockedProgressValues()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadStubURLProtocol.self]

        let result = try await WhisperModelDownloadTransport.download(
            request: URLRequest(url: URL(string: "https://example.test/model.bin")!),
            stagingURL: stagingURL,
            configuration: configuration
        ) { received, expected in
            progress.append(received: received, expected: expected)
        }

        XCTAssertEqual(try Data(contentsOf: result.fileURL), ModelDownloadStubURLProtocol.body)
        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertFalse(progress.values.isEmpty)
        XCTAssertEqual(progress.values.last?.received, Int64(ModelDownloadStubURLProtocol.body.count))
        XCTAssertEqual(progress.values.last?.expected, Int64(ModelDownloadStubURLProtocol.body.count))
    }

    private func createValidJSONFile(at url: URL, byteCount: Int64) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let json = url.lastPathComponent == ModelEngine.parakeetVocabularyFile
            ? "{\"0\":\"fixture\"}"
            : "[{\"fixture\":true}]"
        var data = Data(json.utf8)
        data.append(Data(repeating: 0x20, count: Int(byteCount) - data.count))
        try data.write(to: url)
    }

    private func createSparseFile(at url: URL, byteCount: Int64) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class LockedProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(received: Int64, expected: Int64)] = []

    var values: [(received: Int64, expected: Int64)] {
        lock.withLock { storage }
    }

    func append(received: Int64, expected: Int64) {
        lock.withLock { storage.append((received, expected)) }
    }
}

private final class ModelDownloadStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data("deterministic model body".utf8)
    private var pendingCompletion: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(Self.body.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let midpoint = Self.body.count / 2
        client?.urlProtocol(self, didLoad: Self.body.prefix(midpoint))

        if request.url?.lastPathComponent == "slow-model.bin" {
            let completion = DispatchWorkItem { [weak self] in
                guard let self, self.pendingCompletion?.isCancelled == false else { return }
                self.client?.urlProtocol(self, didLoad: Self.body.suffix(from: midpoint))
                self.client?.urlProtocolDidFinishLoading(self)
            }
            pendingCompletion = completion
            DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: completion)
        } else {
            Thread.sleep(forTimeInterval: 0.03)
            client?.urlProtocol(self, didLoad: Self.body.suffix(from: midpoint))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        pendingCompletion?.cancel()
    }
}
