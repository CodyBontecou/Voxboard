#if canImport(AVFoundation)
import Foundation
import XCTest
@testable import VoxboardShared

final class CheckpointedAudioDeliveryTests: XCTestCase {
    func test_zeroLengthCheckpointIsRepairedRecheckpointedAndReplacesStaleReference() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let emptyCheckpoint = fixture.notes.appendingPathComponent("Meeting.wav")
        try Data().write(to: emptyCheckpoint)
        try "Transcript\n\nAudio: Meeting.wav".write(
            to: fixture.note,
            atomically: true,
            encoding: .utf8
        )
        let probe = DeliveryProbe()

        let delivered = try await CheckpointedAudioDelivery.deliver(
            sourceAudioURL: fixture.source,
            transcriptFileURL: fixture.note,
            flow: fixture.flow,
            transcriptFolderScopeURL: fixture.notes,
            previouslyExportedURL: emptyCheckpoint,
            audioReferenceAlreadyAttached: true,
            audioDeliveryTransactionDirectoryURL: fixture.root.appendingPathComponent("transactions/audio"),
            audioReferenceDeliveryTransactionDirectoryURL: fixture.root.appendingPathComponent("transactions/reference"),
            checkpointExport: { probe.recordExport($0) },
            checkpointReference: { probe.recordReferenceCheckpoint() }
        )

        let repaired = try XCTUnwrap(delivered)
        XCTAssertNotEqual(repaired, emptyCheckpoint)
        XCTAssertGreaterThan(try fileSize(repaired), 0)
        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.exportedURLs, [repaired])
        XCTAssertEqual(snapshot.events, ["audio-checkpoint", "reference-checkpoint"])
        let relativePath = AudioAttachmentExporter.relativePath(from: fixture.note, to: repaired)
        let content = try String(contentsOf: fixture.note, encoding: .utf8)
        XCTAssertFalse(content.contains("Audio: Meeting.wav"))
        XCTAssertEqual(content.components(separatedBy: "Audio: \(relativePath)").count - 1, 1)
    }

    func test_missingCheckpointIsRepairedAndExactReturnedURLReplacesStaleState() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let missingCheckpoint = fixture.notes.appendingPathComponent("missing.wav")
        try "Transcript\n\nAudio: missing.wav".write(
            to: fixture.note,
            atomically: true,
            encoding: .utf8
        )
        let probe = DeliveryProbe()

        let delivered = try await CheckpointedAudioDelivery.deliver(
            sourceAudioURL: fixture.source,
            transcriptFileURL: fixture.note,
            flow: fixture.flow,
            transcriptFolderScopeURL: fixture.notes,
            previouslyExportedURL: missingCheckpoint,
            audioReferenceAlreadyAttached: true,
            audioDeliveryTransactionDirectoryURL: fixture.root.appendingPathComponent("transactions/audio"),
            checkpointExport: { probe.recordExport($0) },
            checkpointReference: { probe.recordReferenceCheckpoint() }
        )

        let repaired = try XCTUnwrap(delivered)
        XCTAssertNotEqual(repaired, missingCheckpoint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingCheckpoint.path))
        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.exportedURLs, [repaired])
        XCTAssertEqual(snapshot.events, ["audio-checkpoint", "reference-checkpoint"])
        let relativePath = AudioAttachmentExporter.relativePath(from: fixture.note, to: repaired)
        let content = try String(contentsOf: fixture.note, encoding: .utf8)
        XCTAssertFalse(content.contains("Audio: missing.wav"))
        XCTAssertEqual(content.components(separatedBy: "Audio: \(relativePath)").count - 1, 1)
    }

    func test_usableCheckpointIsStillDurablyRecheckpointedWithoutRepeatingReference() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let usableCheckpoint = fixture.notes.appendingPathComponent("existing.wav")
        try Data("existing-audio".utf8).write(to: usableCheckpoint)
        try "Transcript\n\nAudio: existing.wav".write(
            to: fixture.note,
            atomically: true,
            encoding: .utf8
        )
        let probe = DeliveryProbe()

        let delivered = try await CheckpointedAudioDelivery.deliver(
            sourceAudioURL: fixture.source,
            transcriptFileURL: fixture.note,
            flow: fixture.flow,
            previouslyExportedURL: usableCheckpoint,
            audioReferenceAlreadyAttached: true,
            checkpointExport: { probe.recordExport($0) },
            checkpointReference: { probe.recordReferenceCheckpoint() }
        )

        XCTAssertEqual(delivered, usableCheckpoint)
        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.exportedURLs, [usableCheckpoint])
        XCTAssertEqual(snapshot.events, ["audio-checkpoint"])
        XCTAssertEqual(
            try String(contentsOf: fixture.note, encoding: .utf8),
            "Transcript\n\nAudio: existing.wav"
        )
    }

    func test_audioCheckpointFailureStopsReferenceAndPreservesSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = DeliveryProbe()
        let originalSource = try Data(contentsOf: fixture.source)
        let originalNote = try String(contentsOf: fixture.note, encoding: .utf8)

        await XCTAssertThrowsErrorAsync {
            _ = try await CheckpointedAudioDelivery.deliver(
                sourceAudioURL: fixture.source,
                transcriptFileURL: fixture.note,
                flow: fixture.flow,
                checkpointExport: { url in
                    probe.recordExport(url)
                    throw TestError.checkpoint
                },
                checkpointReference: { probe.recordReferenceCheckpoint() }
            )
        }

        XCTAssertEqual(try Data(contentsOf: fixture.source), originalSource)
        XCTAssertEqual(try String(contentsOf: fixture.note, encoding: .utf8), originalNote)
        XCTAssertEqual(probe.snapshot().events, ["audio-checkpoint"])
    }

    func test_referenceCheckpointFailureKeepsExportCheckpointAndPreservesSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = DeliveryProbe()
        let originalSource = try Data(contentsOf: fixture.source)

        await XCTAssertThrowsErrorAsync {
            _ = try await CheckpointedAudioDelivery.deliver(
                sourceAudioURL: fixture.source,
                transcriptFileURL: fixture.note,
                flow: fixture.flow,
                checkpointExport: { probe.recordExport($0) },
                checkpointReference: {
                    probe.recordReferenceCheckpoint()
                    throw TestError.checkpoint
                }
            )
        }

        XCTAssertEqual(try Data(contentsOf: fixture.source), originalSource)
        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.exportedURLs.count, 1)
        XCTAssertEqual(snapshot.events, ["audio-checkpoint", "reference-checkpoint"])
        let exported = try XCTUnwrap(snapshot.exportedURLs.first)
        let relativePath = AudioAttachmentExporter.relativePath(from: fixture.note, to: exported)
        XCTAssertTrue(
            try String(contentsOf: fixture.note, encoding: .utf8)
                .contains("Audio: \(relativePath)")
        )
    }

    private func fileSize(_ url: URL) throws -> Int {
        try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }
}

private enum TestError: Error {
    case checkpoint
}

private struct Fixture {
    let root: URL
    let notes: URL
    let source: URL
    let note: URL
    let flow: CapturePreset

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckpointedAudioDeliveryTests-\(UUID().uuidString)")
        notes = root.appendingPathComponent("Notes", isDirectory: true)
        source = root.appendingPathComponent("recording.wav")
        note = notes.appendingPathComponent("Meeting.txt")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data("recoverable-source-audio".utf8).write(to: source)
        try "Transcript".write(to: note, atomically: true, encoding: .utf8)
        var flow = CapturePresetStore.makeCustomFlow()
        flow.audioSaveMode = .alongsideTranscript
        self.flow = flow
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class DeliveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var exportedURLs: [URL] = []
    private var events: [String] = []

    func recordExport(_ url: URL) {
        lock.withLock {
            exportedURLs.append(url)
            events.append("audio-checkpoint")
        }
    }

    func recordReferenceCheckpoint() {
        lock.withLock { events.append("reference-checkpoint") }
    }

    func snapshot() -> Snapshot {
        lock.withLock { Snapshot(exportedURLs: exportedURLs, events: events) }
    }

    struct Snapshot {
        let exportedURLs: [URL]
        let events: [String]
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
#endif
