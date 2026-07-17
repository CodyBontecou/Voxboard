import Foundation
import XCTest
@testable import VoxboardCaptureCore

final class CaptureHistoryStoreTests: XCTestCase {
    func test_idempotentUpsertKeepsOneRecordPerRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let record = try makeRecord(requestID: fixture.firstID, deliveredAt: date(20))

        try await store.upsert(record)
        try await store.upsert(record)

        let records = try await store.list()
        XCTAssertEqual(records, [record])
    }

    func test_retryUpsertReplacesFailureWithLatestDelivery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let failed = try makeRecord(
            requestID: fixture.firstID,
            deliveredAt: date(20),
            outcome: .failed,
            failureCategory: .destinationUnavailable
        )
        let delivered = try makeRecord(
            requestID: fixture.firstID,
            deliveredAt: date(40),
            outcome: .delivered,
            attachmentCount: 2
        )

        try await store.upsert(failed)
        try await store.upsert(delivered)

        let records = try await store.load()
        XCTAssertEqual(records, [delivered])
        XCTAssertNil(records.first?.failureCategory)
    }

    func test_listSortsNewestFirstAndPrunesToMaximumCount() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store(maximumRecordCount: 2)
        let oldest = try makeRecord(requestID: fixture.firstID, deliveredAt: date(20))
        let newest = try makeRecord(requestID: fixture.secondID, deliveredAt: date(60))
        let middle = try makeRecord(requestID: fixture.thirdID, deliveredAt: date(40))

        try await store.upsert(oldest)
        try await store.upsert(newest)
        try await store.upsert(middle)

        let records = try await store.list()
        XCTAssertEqual(records, [newest, middle])
    }

    func test_clearRemovesAllHistoryAndIsIdempotent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        try await store.upsert(try makeRecord(requestID: fixture.firstID, deliveredAt: date(20)))

        try await store.clear()
        try await store.clear()

        let records = try await store.list()
        XCTAssertEqual(records, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    func test_missingFileLoadsAsEmptyHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let records = try await fixture.store().load()
        XCTAssertEqual(records, [])
    }

    func test_legacyBareRecordArrayLoadsNewestFirst() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let older = try makeRecord(requestID: fixture.firstID, deliveredAt: date(20))
        let newer = try makeRecord(requestID: fixture.secondID, deliveredAt: date(40))
        try JSONEncoder().encode([older, newer]).write(to: fixture.fileURL)

        let records = try await fixture.store().load()
        XCTAssertEqual(records, [newer, older])
    }

    func test_codableRecordContainsOnlyPrivacySafeDeliveryMetadata() throws {
        let sensitiveDraft = "private draft sentence that must never persist"
        let sensitiveURL = "https://secret.example/private?q=coordinates"
        let sensitiveCoordinates = "21.3069,-157.8583"
        let sensitiveAbsolutePath = "/Users/alice/Secret Vault/Inbox.md"
        let sensitiveBookmark = "c2VjdXJlLWJvb2ttYXJrLWRhdGE="
        let sensitiveAttachmentFilename = "medical-scan-private-name.pdf"
        let record = try CaptureHistoryRecord(
            requestID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            createdAt: date(10),
            deliveredAt: date(20),
            source: .shareExtension,
            outcome: .failed,
            destinationID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            destinationName: "Inbox",
            relativeNotePath: "Daily/2026-07-16.md",
            attachmentCount: 1,
            failureCategory: .fileWrite
        )

        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let roundTripped = try JSONDecoder().decode(CaptureHistoryRecord.self, from: data)

        XCTAssertEqual(roundTripped, record)
        XCTAssertTrue(json.contains("\"schemaVersion\":1"))
        for forbidden in [
            sensitiveDraft,
            sensitiveURL,
            sensitiveCoordinates,
            sensitiveAbsolutePath,
            sensitiveBookmark,
            sensitiveAttachmentFilename,
            "draftText",
            "noteText",
            "bookmarkData",
            "attachmentFilenames",
            "coordinates",
            "url"
        ] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(forbidden), "Leaked \(forbidden)")
        }
    }

    func test_relativeNotePathDerivesNestedPathOnlyInsideRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/Vault", isDirectory: true)
        XCTAssertEqual(
            CaptureHistoryRecord.relativeNotePath(
                noteURL: root.appendingPathComponent("Projects/Now.md"),
                rootURL: root
            ),
            "Projects/Now.md"
        )
        XCTAssertNil(CaptureHistoryRecord.relativeNotePath(
            noteURL: URL(fileURLWithPath: "/tmp/Other/Secret.md"),
            rootURL: root
        ))
    }

    func test_recordRejectsAbsoluteAndURLNotePaths() {
        XCTAssertThrowsError(try makeRecord(
            requestID: UUID(),
            deliveredAt: date(20),
            relativeNotePath: "/private/Inbox.md"
        ))
        XCTAssertThrowsError(try makeRecord(
            requestID: UUID(),
            deliveredAt: date(20),
            relativeNotePath: "https://secret.example/Inbox.md"
        ))
    }

    func test_corruptFileIsQuarantinedBeforeHistoryStartsFresh() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let corrupt = Data("{contains private old bytes, not JSON".utf8)
        try corrupt.write(to: fixture.fileURL)
        let store = fixture.store()

        let initialRecords = try await store.load()
        XCTAssertEqual(initialRecords, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: store.quarantineDirectoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(quarantined.first)), corrupt)

        let replacement = try makeRecord(requestID: fixture.firstID, deliveredAt: date(20))
        try await store.upsert(replacement)
        let replacementRecords = try await store.list()
        XCTAssertEqual(replacementRecords, [replacement])
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(quarantined.first)), corrupt)
    }

    func test_concurrentStoresUsingSharedCoordinatorDoNotLoseUpdates() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let coordinator = ProcessLocalCaptureFileCoordinator()
        let firstStore = fixture.store(coordinator: coordinator)
        let secondStore = fixture.store(coordinator: coordinator)
        let records = try (0..<24).map { index in
            try makeRecord(
                requestID: UUID(),
                deliveredAt: date(TimeInterval(index + 1))
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, record) in records.enumerated() {
                let store = index.isMultiple(of: 2) ? firstStore : secondStore
                group.addTask {
                    try await store.upsert(record)
                }
            }
            try await group.waitForAll()
        }

        let loaded = try await firstStore.list()
        XCTAssertEqual(loaded.count, records.count)
        XCTAssertEqual(Set(loaded.map(\.requestID)), Set(records.map(\.requestID)))
    }

    func test_writeFailuresUseDedicatedErrorForBestEffortCallSites() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store(coordinator: FailingHistoryCoordinator())
        let record = try makeRecord(requestID: fixture.firstID, deliveredAt: date(20))

        do {
            try await store.upsert(record)
            XCTFail("Expected a dedicated history write error")
        } catch let error as CaptureHistoryWriteError {
            XCTAssertEqual(error.operation, .upsert)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    private func makeRecord(
        requestID: UUID,
        deliveredAt: Date?,
        outcome: CaptureHistoryOutcome = .delivered,
        relativeNotePath: String? = "Daily/2026-07-16.md",
        attachmentCount: Int = 0,
        failureCategory: CaptureHistoryFailureCategory? = nil
    ) throws -> CaptureHistoryRecord {
        try CaptureHistoryRecord(
            requestID: requestID,
            createdAt: date(10),
            deliveredAt: deliveredAt,
            source: .app,
            outcome: outcome,
            destinationID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            destinationName: "Inbox",
            relativeNotePath: relativeNotePath,
            attachmentCount: attachmentCount,
            failureCategory: failureCategory
        )
    }

    private func date(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }
}

private struct Fixture {
    let folderURL: URL
    let fileURL: URL
    let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    init() throws {
        folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = folderURL.appendingPathComponent("capture-history-v1.json")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    func store(
        coordinator: any CaptureFileCoordinating = ProcessLocalCaptureFileCoordinator.shared,
        maximumRecordCount: Int = CaptureHistoryStore.defaultMaximumRecordCount
    ) -> CaptureHistoryStore {
        CaptureHistoryStore(
            fileURL: fileURL,
            coordinator: coordinator,
            maximumRecordCount: maximumRecordCount
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: folderURL)
    }
}

private struct ExpectedHistoryCoordinatorError: Error {}

private final class FailingHistoryCoordinator: CaptureFileCoordinating, @unchecked Sendable {
    func coordinateWriting<T>(at url: URL, _ accessor: (URL) throws -> T) throws -> T {
        throw ExpectedHistoryCoordinatorError()
    }
}
