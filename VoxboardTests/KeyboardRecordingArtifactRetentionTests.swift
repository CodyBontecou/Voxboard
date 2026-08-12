import XCTest
import VoxboardShared
@testable import Voxboard

final class KeyboardRecordingArtifactRetentionTests: XCTestCase {
    func testDeliveryFailurePreservesWAVAndJournal() async throws {
        let fixture = try KeyboardArtifactFixture()
        defer { fixture.cleanup() }

        do {
            try await KeyboardRecordingArtifactRetention.perform(
                wavURL: fixture.wavURL,
                journalURL: fixture.journalURL
            ) {
                throw ExpectedDeliveryFailure()
            }
            XCTFail("Expected delivery failure")
        } catch is ExpectedDeliveryFailure {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.wavURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journalURL.path))
            XCTAssertFalse(RecordingArtifactDeliveryReceipt.exists(for: fixture.wavURL))
            XCTAssertFalse(RecordingArtifactDeliveryReceipt.exists(for: fixture.journalURL))
        }
    }

    func testSuccessfulDeliveryRemovesWAVAndJournal() async throws {
        let fixture = try KeyboardArtifactFixture()
        defer { fixture.cleanup() }

        let cleanupResult = try await KeyboardRecordingArtifactRetention.perform(
            wavURL: fixture.wavURL,
            journalURL: fixture.journalURL
        ) {}

        XCTAssertTrue(cleanupResult.didRemoveAllArtifacts)
        XCTAssertEqual(cleanupResult.retainedArtifactCount, 0)
        XCTAssertEqual(cleanupResult.unprotectedRetainedArtifactCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.wavURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    func testJournalCleanupFailurePreservesRecoverablePairAndReportsRetention() async throws {
        let fixture = try KeyboardArtifactFixture()
        defer { fixture.cleanup() }

        let cleanupResult = try await KeyboardRecordingArtifactRetention.perform(
            wavURL: fixture.wavURL,
            journalURL: fixture.journalURL,
            removeItem: { url in
                if url == fixture.journalURL {
                    throw ExpectedCleanupFailure()
                }
                try FileManager.default.removeItem(at: url)
            }
        ) {}

        XCTAssertEqual(cleanupResult.retainedArtifactCount, 2)
        XCTAssertEqual(cleanupResult.unprotectedRetainedArtifactCount, 0)
        XCTAssertTrue(RecordingArtifactDeliveryReceipt.exists(for: fixture.wavURL))
        XCTAssertTrue(RecordingArtifactDeliveryReceipt.exists(for: fixture.journalURL))
        XCTAssertFalse(cleanupResult.didRemoveAllArtifacts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.wavURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    func testWAVCleanupFailureReportsRetainedSourceAfterJournalRemoval() async throws {
        let fixture = try KeyboardArtifactFixture()
        defer { fixture.cleanup() }

        let cleanupResult = try await KeyboardRecordingArtifactRetention.perform(
            wavURL: fixture.wavURL,
            journalURL: fixture.journalURL,
            removeItem: { url in
                if url == fixture.wavURL {
                    throw ExpectedCleanupFailure()
                }
                try FileManager.default.removeItem(at: url)
            }
        ) {}

        XCTAssertEqual(cleanupResult.retainedArtifactCount, 1)
        XCTAssertEqual(cleanupResult.unprotectedRetainedArtifactCount, 0)
        XCTAssertTrue(RecordingArtifactDeliveryReceipt.exists(for: fixture.wavURL))
        XCTAssertFalse(RecordingArtifactDeliveryReceipt.exists(for: fixture.journalURL))
        XCTAssertFalse(cleanupResult.didRemoveAllArtifacts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.wavURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    func testReceiptWriteFailurePreservesSourcesAndReportsUnprotectedArtifacts() async throws {
        let fixture = try KeyboardArtifactFixture()
        defer { fixture.cleanup() }

        let cleanupResult = try await KeyboardRecordingArtifactRetention.perform(
            wavURL: fixture.wavURL,
            journalURL: fixture.journalURL,
            writeDeliveryReceipt: { _ in throw ExpectedReceiptFailure() }
        ) {}

        XCTAssertEqual(cleanupResult.retainedArtifactCount, 2)
        XCTAssertEqual(cleanupResult.unprotectedRetainedArtifactCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.wavURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }
}

private struct ExpectedDeliveryFailure: Error {}
private struct ExpectedCleanupFailure: Error {}
private struct ExpectedReceiptFailure: Error {}

private struct KeyboardArtifactFixture {
    let rootURL: URL
    let wavURL: URL
    let journalURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KeyboardRecordingArtifactRetentionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        wavURL = rootURL.appendingPathComponent("keyboard.wav")
        journalURL = rootURL.appendingPathComponent("keyboard-journal.wav")
        try Data(repeating: 1, count: 128).write(to: wavURL)
        try Data(repeating: 2, count: 128).write(to: journalURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
