import XCTest
@testable import VoxboardCaptureCore

final class CaptureLibraryStoreTests: XCTestCase {
    func test_atomicRoundTripPreservesBookmarksAndRoutes() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("capture-library-v1.json")
        let destination = CaptureDestination(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Daily",
            rootBookmark: Data([0, 1, 2, 3, 4]),
            rootName: "Vault",
            noteTarget: .rollingNote(pathTemplate: "Daily/{date}.md", period: .daily),
            placement: .prepend,
            entryPrefix: "- ",
            entrySuffix: " #inbox"
        )
        let library = CaptureLibraryEnvelope(
            destinations: [destination],
            defaultDestinationID: destination.id
        )
        let store = CaptureLibraryStore(
            fileURL: url,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )

        try await store.save(library)
        let loaded = try await store.load()

        XCTAssertEqual(loaded, library)
    }

    func test_legacyFlowBindingsDecodeForMigrationButAreNotWrittenAgain() throws {
        let destinationID = UUID()
        let data = Data("""
        {"schemaVersion":1,"destinations":[],"flowBindings":{"journal":"\(destinationID.uuidString)"}}
        """.utf8)

        let decoded = try CaptureLibraryEnvelope.decodeValidated(from: data)
        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(decoded.legacyFlowBindings["journal"], destinationID)
        XCTAssertNil(object["flowBindings"])
    }

    func test_corruptLibraryReportsErrorWithoutOverwritingSource() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("capture-library-v1.json")
        let corrupt = Data("{ definitely-not-json".utf8)
        try corrupt.write(to: url)
        let store = CaptureLibraryStore(
            fileURL: url,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )

        do {
            try await store.update { library in
                library.defaultDestinationID = UUID()
            }
            XCTFail("Expected corrupt library update to fail")
        } catch {
            // The exact DecodingError remains available to the UI.
        }

        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func test_unknownVersionIsNotReplacedWithDefaults() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("capture-library-v1.json")
        let future = Data("{\"schemaVersion\":2,\"destinations\":[],\"flowBindings\":{}}".utf8)
        try future.write(to: url)
        let store = CaptureLibraryStore(
            fileURL: url,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )

        await XCTAssertThrowsErrorAsync(try await store.load()) { error in
            XCTAssertEqual(error as? CaptureModelError, .unsupportedSchemaVersion(2))
        }
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLibraryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
