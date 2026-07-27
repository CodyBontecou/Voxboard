import XCTest
import VoxboardShared
@testable import Voxboard

@MainActor
final class QuickCaptureRecognizedTextTests: XCTestCase {
    func test_appendRecognizedTextPersistsEditableMarkdownWithoutAttachments() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickCaptureRecognizedTextTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let viewModel = QuickCaptureViewModel(captureRootURL: rootURL)
        await viewModel.load()

        let didAppend = await viewModel.appendRecognizedText(
            "First journal line\r\nSecond journal line"
        )

        XCTAssertTrue(didAppend)
        XCTAssertEqual(
            viewModel.draft.text,
            "First journal line\nSecond journal line"
        )
        XCTAssertTrue(viewModel.draft.additionalPayloads.isEmpty)

        let store = CaptureDraftStore(rootDirectoryURL: rootURL)
        let persisted = try await store.load(id: viewModel.draft.id)
        XCTAssertEqual(persisted?.text, viewModel.draft.text)
        XCTAssertTrue(persisted?.additionalPayloads.isEmpty == true)

        let stagingURL = rootURL.appendingPathComponent("staging", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    }
}
