import XCTest
@testable import VoxboardShared

final class CaptureRecordingOriginStoreTests: XCTestCase {
    func test_snapshotPersistsExactUnavailableOutcomeUntilRemoved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureRecordingOriginStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureRecordingOriginStore(rootDirectoryURL: root)
        let snapshot = CaptureRecordingOriginSnapshot(
            presetID: "voice",
            source: .widget,
            outcome: .unavailable(.timeout, attemptedAt: Date(timeIntervalSince1970: 1_700_000_000))
        )

        try await store.save(snapshot, recordingID: "control/request unsafe")
        let loaded = try await store.load(recordingID: "control/request unsafe")
        XCTAssertEqual(loaded, snapshot)
        try await store.remove(recordingID: "control/request unsafe")
        let removed = try await store.load(recordingID: "control/request unsafe")
        XCTAssertNil(removed)

        try await store.save(snapshot, recordingID: "stale")
        let purged = try await store.purge(
            olderThan: 24 * 60 * 60,
            now: Date().addingTimeInterval(2 * 24 * 60 * 60)
        )
        XCTAssertEqual(purged, 1)
    }

    func test_interruptedStopPlaceholderIsAtomicallyReplacedAndReusable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureRecordingOriginReplacementTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureRecordingOriginStore(rootDirectoryURL: root)
        let stoppedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let placeholder = CaptureRecordingOriginSnapshot(
            presetID: "mac-preset",
            source: .mac,
            outcome: .unavailable(.unavailable, attemptedAt: stoppedAt)
        )
        try await store.save(placeholder, recordingID: "retained-recording.m4a")
        let loadedPlaceholder = try await store.load(recordingID: "retained-recording.m4a")
        XCTAssertEqual(loadedPlaceholder, placeholder)

        let final = CaptureRecordingOriginSnapshot(
            presetID: "mac-preset",
            source: .mac,
            outcome: .available(CaptureLocationSnapshot(
                latitude: 45.501234,
                longitude: -73.567891,
                timestamp: stoppedAt,
                source: .mac,
                precision: .exact
            ))
        )
        try await store.save(final, recordingID: "retained-recording.m4a")
        let loadedFinal = try await store.load(recordingID: "retained-recording.m4a")
        XCTAssertEqual(loadedFinal, final)
    }

    func test_recordingOriginsPropagateIncludingKeyboardPresetCapture() {
        XCTAssertEqual(CaptureSource.recordingSource(for: .keyboardExtension), .keyboard)
        XCTAssertEqual(CaptureSource.recordingSource(for: .quickRecord), .widget)
        XCTAssertEqual(CaptureSource.recordingSource(for: .liveActivity), .widget)
        XCTAssertEqual(CaptureSource.recordingSource(for: .inAppImmediate), .voice)
        XCTAssertEqual(CaptureSource.recordingSource(for: .inAppDraft), .app)
        XCTAssertEqual(CaptureSource.recordingSource(for: .watch), .watch)
        XCTAssertEqual(
            CaptureSource.recordingSource(for: .inAppImmediate, overriding: .fileImport),
            .fileImport
        )
    }
}
