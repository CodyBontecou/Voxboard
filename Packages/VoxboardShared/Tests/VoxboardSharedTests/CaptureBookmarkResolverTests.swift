import XCTest
@testable import VoxboardShared

final class CaptureBookmarkResolverTests: XCTestCase {
    func testResolvesOrdinaryBookmarkUsedByLegacyAndTests() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let bookmark = try folder.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let resolution = try CaptureBookmarkResolver.resolve(bookmark)

        XCTAssertEqual(resolution.url.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertFalse(resolution.isStale)
    }

    func testInvalidBookmarkThrows() {
        XCTAssertThrowsError(try CaptureBookmarkResolver.resolve(Data("invalid".utf8)))
    }
}
