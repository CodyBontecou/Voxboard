import XCTest
import UIKit
import VoxboardShared
@testable import Voxboard

@MainActor
final class WatchRecordingBackgroundLeaseTests: XCTestCase {
    func testBackgroundExecutionPolicyRequiresForegroundOrActiveLease() {
        XCTAssertTrue(WatchRecordingBackgroundExecutionPolicy.shouldStart(
            leaseIsActive: true,
            applicationIsActive: false
        ))
        XCTAssertTrue(WatchRecordingBackgroundExecutionPolicy.shouldStart(
            leaseIsActive: false,
            applicationIsActive: true
        ))
        XCTAssertFalse(WatchRecordingBackgroundExecutionPolicy.shouldStart(
            leaseIsActive: false,
            applicationIsActive: false
        ))
    }

    func testNormalCompletionEndsValidIdentifierExactlyOnce() {
        let service = FakeBackgroundTaskService(identifier: identifier(41))
        let lease = makeLease(service: service)

        XCTAssertTrue(lease.isActive)
        lease.end(.completed)
        lease.end(.coalesced)

        XCTAssertFalse(lease.isActive)
        XCTAssertEqual(lease.endReason, .completed)
        XCTAssertEqual(service.beginCount, 1)
        XCTAssertEqual(service.endedIdentifiers, [identifier(41)])
    }

    func testExpirationCancelsAndEndsExactlyOnce() {
        let service = FakeBackgroundTaskService(identifier: identifier(42))
        var expiredTokens: [UUID] = []
        let lease = WatchRecordingBackgroundLease.begin(
            recordingID: "recording-expiration",
            service: service
        ) { token in
            expiredTokens.append(token)
        }

        service.expire()
        service.expire()
        lease.end(.completed)

        XCTAssertEqual(expiredTokens, [lease.token])
        XCTAssertEqual(lease.endReason, .expired)
        XCTAssertEqual(service.endedIdentifiers, [identifier(42)])
    }

    func testExpirationDuringBeginEndsReturnedIdentifier() {
        let service = FakeBackgroundTaskService(
            identifier: identifier(43),
            expiresSynchronouslyDuringBegin: true
        )
        var expirationCount = 0

        let lease = WatchRecordingBackgroundLease.begin(
            recordingID: "recording-early-expiration",
            service: service
        ) { _ in
            expirationCount += 1
        }

        XCTAssertFalse(lease.isActive)
        XCTAssertEqual(lease.endReason, .expired)
        XCTAssertEqual(expirationCount, 1)
        XCTAssertEqual(service.endedIdentifiers, [identifier(43)])
    }

    func testInvalidIdentifierNeverAttemptsUIKitEnd() {
        let service = FakeBackgroundTaskService(identifier: .invalid)
        let lease = makeLease(service: service)

        XCTAssertFalse(lease.isActive)
        XCTAssertEqual(lease.endReason, .unavailable)
        lease.end(.completed)
        XCTAssertTrue(service.endedIdentifiers.isEmpty)
    }

    func testCompletionBeforeLateExpirationSuppressesCallback() {
        let service = FakeBackgroundTaskService(identifier: identifier(44))
        var expirationCount = 0
        let lease = WatchRecordingBackgroundLease.begin(
            recordingID: "recording-late-expiration",
            service: service
        ) { _ in
            expirationCount += 1
        }

        lease.end(.completed)
        service.expire()

        XCTAssertEqual(expirationCount, 0)
        XCTAssertEqual(service.endedIdentifiers, [identifier(44)])
    }

    func testRecordingOnlyPipelineCopiesQueuedWatchFileWithoutUIResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WatchRecordingPipelineTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let destination = root.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingID = UUID().uuidString
        let source = root.appendingPathComponent("source.m4a")
        let sourceData = Data((0..<4_096).map { UInt8($0 % 251) })
        try sourceData.write(to: source)
        let bookmark = try destination.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let preset = CapturePreset(
            id: UUID().uuidString,
            name: "Unattended Test",
            symbolName: "waveform",
            watchOutputMode: .recordingOnly,
            watchRecordingSettings: CapturePresetWatchRecordingSettings(
                folderBookmark: bookmark,
                folderName: "Files",
                filenameTemplate: "unattended-{id8}"
            )
        )
        let snapshot = try JSONEncoder().encode(preset)
        let item = try WatchRecordingInbox.shared.enqueue(
            fileURL: source,
            metadata: [
                WatchRecordingFileMetadataKey.kind: WatchRecordingFileMetadataKey.watchAudioRecordingKind,
                WatchRecordingFileMetadataKey.recordingID: recordingID,
                WatchRecordingFileMetadataKey.createdAt: Date().timeIntervalSince1970,
                WatchRecordingFileMetadataKey.duration: 1.0,
                WatchRecordingFileMetadataKey.originalFilename: source.lastPathComponent,
                WatchRecordingFileMetadataKey.presetSnapshot: snapshot,
            ]
        )
        let service = FakeBackgroundTaskService(identifier: identifier(46))
        let pipeline = WatchRecordingPipeline(
            transcriptStore: TranscriptStore(),
            usageTracker: UsageTracker(),
            transcriptionService: AppTranscriptionServices.shared,
            transcriptEnricher: nil,
            backgroundTaskService: service
        )
        let lease = makeLease(service: service)

        pipeline.recordingDidArrive(
            recordingID: item.id,
            backgroundLease: lease
        )

        let expected = destination.appendingPathComponent(
            "unattended-\(recordingID.lowercased().prefix(8)).m4a"
        )
        try await waitUntil {
            WatchRecordingInbox.shared.load().first(where: { $0.id == recordingID })?.phase == .delivered
                && FileManager.default.fileExists(atPath: expected.path)
                && service.endedIdentifiers == [self.identifier(46)]
        }

        XCTAssertEqual(try Data(contentsOf: expected), sourceData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL.path))
    }

    func testConcurrentCompletionCallsStillEndOnce() async {
        let service = FakeBackgroundTaskService(identifier: identifier(45))
        let lease = makeLease(service: service)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    lease.end(.completed)
                }
            }
        }

        XCTAssertEqual(service.endedIdentifiers, [identifier(45)])
    }

    private func waitUntil(
        timeout: TimeInterval = 15,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for Watch recording delivery")
    }

    private func makeLease(
        service: FakeBackgroundTaskService
    ) -> WatchRecordingBackgroundLease {
        WatchRecordingBackgroundLease.begin(
            recordingID: "recording-test",
            service: service
        ) { _ in }
    }

    private func identifier(_ rawValue: Int) -> UIBackgroundTaskIdentifier {
        UIBackgroundTaskIdentifier(rawValue: rawValue)
    }
}

nonisolated private final class FakeBackgroundTaskService: WatchRecordingBackgroundTaskServicing, @unchecked Sendable {
    private let lock = NSLock()
    private let identifier: UIBackgroundTaskIdentifier
    private let expiresSynchronouslyDuringBegin: Bool
    private var storedExpirationHandler: (@MainActor @Sendable () -> Void)?
    private var mutableBeginCount = 0
    private var mutableEndedIdentifiers: [UIBackgroundTaskIdentifier] = []

    init(
        identifier: UIBackgroundTaskIdentifier,
        expiresSynchronouslyDuringBegin: Bool = false
    ) {
        self.identifier = identifier
        self.expiresSynchronouslyDuringBegin = expiresSynchronouslyDuringBegin
    }

    var beginCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mutableBeginCount
    }

    var endedIdentifiers: [UIBackgroundTaskIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        return mutableEndedIdentifiers
    }

    func begin(
        name: String,
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier {
        lock.lock()
        mutableBeginCount += 1
        storedExpirationHandler = expirationHandler
        lock.unlock()

        if expiresSynchronouslyDuringBegin {
            MainActor.assumeIsolated {
                expirationHandler()
            }
        }
        return identifier
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        lock.lock()
        mutableEndedIdentifiers.append(identifier)
        lock.unlock()
    }

    @MainActor
    func expire() {
        lock.lock()
        let handler = storedExpirationHandler
        lock.unlock()
        handler?()
    }
}
