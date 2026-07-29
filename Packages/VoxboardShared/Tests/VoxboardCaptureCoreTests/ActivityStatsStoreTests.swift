import Foundation
import XCTest
@testable import VoxboardCaptureCore

final class ActivityStatsStoreTests: XCTestCase {
    func test_recordingAndCaptureWritesAreIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.statsStore()
        let recordingID = UUID()
        let captureID = UUID()

        try store.record(RecordingActivityEvent(id: recordingID, date: date(10), duration: 30))
        try store.record(RecordingActivityEvent(id: recordingID, date: date(20), duration: 45))
        try store.record(CaptureActivityEvent(
            id: captureID,
            date: date(30),
            source: .app,
            attachmentCount: 1
        ))
        try store.record(CaptureActivityEvent(
            id: captureID,
            date: date(40),
            source: .shareExtension,
            attachmentCount: 2
        ))

        let ledger = try store.load()
        XCTAssertEqual(ledger.recordings, [
            RecordingActivityEvent(id: recordingID, date: date(20), duration: 45)
        ])
        XCTAssertEqual(ledger.captures, [
            CaptureActivityEvent(
                id: captureID,
                date: date(40),
                source: .shareExtension,
                attachmentCount: 2
            )
        ])
    }

    func test_captureHistoryTracksOnlyDeliveredRecordsAndSurvivesHistoryClear() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let history = fixture.historyStore()
        let failedID = UUID()
        let deliveredID = UUID()

        try await history.upsert(try historyRecord(id: failedID, outcome: .failed))
        try await history.upsert(try historyRecord(id: deliveredID, outcome: .delivered))
        try await history.clear()

        let visibleHistory = try await history.list()
        XCTAssertEqual(visibleHistory, [])
        let ledger = try fixture.statsStore().load()
        XCTAssertEqual(ledger.captures.map(\.id), [deliveredID])
    }

    func test_reconcileBackfillsWithoutReplacingNewerEvents() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.statsStore()
        let recordingID = UUID()
        let captureID = UUID()
        try store.record(RecordingActivityEvent(id: recordingID, date: date(50), duration: 60))
        try store.record(CaptureActivityEvent(
            id: captureID,
            date: date(50),
            source: .widget,
            attachmentCount: 3
        ))

        let reconciled = try store.reconcile(
            recordings: [RecordingActivityEvent(id: recordingID, date: date(10), duration: 5)],
            captures: [CaptureActivityEvent(
                id: captureID,
                date: date(10),
                source: .app,
                attachmentCount: 0
            )]
        )

        XCTAssertEqual(reconciled.recordings.first?.duration, 60)
        XCTAssertEqual(reconciled.captures.first?.source, .widget)
        XCTAssertEqual(reconciled.captures.first?.attachmentCount, 3)
    }

    func test_corruptLedgerIsQuarantinedBeforeStartingFresh() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let corrupt = Data("private bytes that are not JSON".utf8)
        try corrupt.write(to: fixture.statsURL)
        let store = fixture.statsStore()

        XCTAssertEqual(try store.load(), .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.statsURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: store.quarantineDirectoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantined.first)), corrupt)
    }

    func test_ledgerEncodingContainsNoCapturedContentFields() throws {
        let ledger = ActivityStatsLedger(
            recordings: [RecordingActivityEvent(id: UUID(), date: date(10), duration: 20)],
            captures: [CaptureActivityEvent(
                id: UUID(),
                date: date(20),
                source: .shortcut,
                attachmentCount: 1
            )]
        )
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(ledger), encoding: .utf8))

        for forbidden in ["text", "audio", "filename", "url", "path", "bookmark"] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(forbidden))
        }
    }

    private func historyRecord(
        id: UUID,
        outcome: CaptureHistoryOutcome
    ) throws -> CaptureHistoryRecord {
        try CaptureHistoryRecord(
            requestID: id,
            createdAt: date(10),
            deliveredAt: date(20),
            source: .app,
            outcome: outcome,
            destinationID: UUID(),
            destinationName: "Inbox",
            relativeNotePath: "Notes/capture.md",
            attachmentCount: 1,
            failureCategory: outcome == .failed ? .fileWrite : nil
        )
    }

    private func date(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }
}

private struct Fixture {
    let folderURL: URL
    let historyURL: URL
    let statsURL: URL
    let coordinator = ProcessLocalCaptureFileCoordinator()

    init() throws {
        folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStatsStoreTests-\(UUID().uuidString)", isDirectory: true)
        historyURL = folderURL.appendingPathComponent("capture-history-v1.json")
        statsURL = folderURL.appendingPathComponent(ActivityStatsStore.defaultFilename)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    func statsStore() -> ActivityStatsStore {
        ActivityStatsStore(fileURL: statsURL, coordinator: coordinator)
    }

    func historyStore() -> CaptureHistoryStore {
        CaptureHistoryStore(fileURL: historyURL, coordinator: coordinator)
    }

    func remove() {
        try? FileManager.default.removeItem(at: folderURL)
    }
}
