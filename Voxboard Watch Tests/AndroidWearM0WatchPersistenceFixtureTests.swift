import XCTest

final class AndroidWearM0WatchPersistenceFixtureTests: XCTestCase {
    func testCommittedApplicationContextsUseProductionWatchDecoder() throws {
        let current = WatchRecordingSnapshot(
            dictionary: try fixturePropertyList("watch-property-lists/application-context.xml")
        )
        XCTAssertEqual(current.phase, .recording)
        XCTAssertEqual(current.stateRevision, 3)
        XCTAssertEqual(current.selectedPresetID, "fixture")
        XCTAssertEqual(
            current.recordingStatuses.first?.recordingID,
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )

        let legacy = WatchRecordingSnapshot(
            dictionary: try fixturePropertyList(
                "watch-property-lists/application-context-legacy-minimal.xml"
            )
        )
        XCTAssertEqual(legacy.phase, .idle)
        XCTAssertNil(legacy.stateEpoch)
        XCTAssertNil(legacy.stateRevision)
        XCTAssertTrue(legacy.recordingStatuses.isEmpty)
    }

    func testUnknownWatchPropertyListEnumsFailClosedAndReplayRemainsIdempotent() throws {
        var context = try fixturePropertyList("watch-property-lists/application-context.xml")
        context[WatchRecordingPayloadKey.phase] = "futurePhase"
        context[WatchRecordingPayloadKey.presetSelectionResult] = "futureOutcome"
        context[WatchRecordingPayloadKey.presetSelectionRequestID] = "fixture-request"
        context[WatchRecordingPayloadKey.requestedPresetID] = "fixture"
        context[WatchRecordingPayloadKey.presetSelectionEpoch] = 1
        context[WatchRecordingPayloadKey.presetSelectionSequence] = 1
        context[WatchRecordingPayloadKey.recordingStatuses] = [[
            WatchRecordingPayloadKey.recordingID: "fixture-recording",
            WatchRecordingPayloadKey.phase: "futureRemotePhase",
            WatchRecordingPayloadKey.revision: 1,
        ]]
        let snapshot = WatchRecordingSnapshot(dictionary: context)
        XCTAssertEqual(snapshot.phase, .unavailable)
        XCTAssertNil(snapshot.presetSelectionAcknowledgement)
        XCTAssertTrue(snapshot.recordingStatuses.isEmpty)

        let store = WatchLocalRecordingQueueStore(recordingsDirectoryURL: FileManager.default.temporaryDirectory)
        let recording = WatchLocalQueuedRecording(
            id: "fixture-recording",
            filename: "watch-fixture-recording.m4a",
            createdAt: Date(timeIntervalSince1970: 1),
            duration: 1,
            transportState: .uploaded,
            remotePhase: .queued,
            remoteRevision: 3
        )
        let stale = WatchRemoteRecordingStatus(dictionary: [
            WatchRecordingPayloadKey.recordingID: recording.id,
            WatchRecordingPayloadKey.phase: WatchRemoteRecordingPhase.delivered.rawValue,
            WatchRecordingPayloadKey.revision: 3,
        ])
        let fresh = WatchRemoteRecordingStatus(dictionary: [
            WatchRecordingPayloadKey.recordingID: recording.id,
            WatchRecordingPayloadKey.phase: WatchRemoteRecordingPhase.delivered.rawValue,
            WatchRecordingPayloadKey.revision: 4,
        ])
        XCTAssertEqual(
            store.reconcilingRemoteStatuses([try XCTUnwrap(stale)], recordings: [recording]).recordings,
            [recording]
        )
        let terminal = store.reconcilingRemoteStatuses([try XCTUnwrap(fresh)], recordings: [recording])
        XCTAssertTrue(terminal.recordings.isEmpty)
        XCTAssertEqual(terminal.terminalAcknowledgements.count, 1)
        let replay = store.reconcilingRemoteStatuses([try XCTUnwrap(fresh)], recordings: terminal.recordings)
        XCTAssertTrue(replay.recordings.isEmpty)
        XCTAssertEqual(replay.terminalAcknowledgements.count, 1)
    }

    func testLocalSnapshotStoreHandlesAbsentPartialAndWrongTypeDefaults() throws {
        let suiteName = "AndroidWearM0WatchSnapshotFallbacks.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertNil(WatchLocalSnapshotStore.load(defaults: defaults))

        defaults.set([
            WatchRecordingPayloadKey.phase: WatchRecordingPhase.paused.rawValue,
            WatchRecordingPayloadKey.recordingDuration: -3.0,
        ], forKey: WatchLocalSnapshotStore.snapshotKey)
        let partial = try XCTUnwrap(WatchLocalSnapshotStore.load(defaults: defaults))
        XCTAssertEqual(partial.phase, .paused)
        XCTAssertEqual(partial.recordingDuration, 0)
        XCTAssertTrue(partial.isQuickRecordEnabled)
        XCTAssertEqual(partial.queuedCount, 0)

        defaults.set([
            WatchRecordingPayloadKey.phase: 42,
            WatchRecordingPayloadKey.queuedCount: "wrong",
            WatchRecordingPayloadKey.isQuickRecordEnabled: "wrong",
        ], forKey: WatchLocalSnapshotStore.snapshotKey)
        let wrongType = try XCTUnwrap(WatchLocalSnapshotStore.load(defaults: defaults))
        XCTAssertEqual(wrongType.phase, .unavailable)
        XCTAssertEqual(wrongType.queuedCount, 0)
        XCTAssertTrue(wrongType.isQuickRecordEnabled)

        defaults.set([
            WatchRecordingPayloadKey.phase: WatchRecordingPhase.idle.rawValue,
            "futureFixtureField": "ignored",
        ], forKey: WatchLocalSnapshotStore.snapshotKey)
        let unknownField = try XCTUnwrap(WatchLocalSnapshotStore.load(defaults: defaults))
        XCTAssertEqual(unknownField.phase, .idle)
    }

    func testCommittedApplicationContextRoundTripsThroughLocalSnapshotStore() throws {
        let suiteName = "AndroidWearM0WatchSnapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = try fixturePropertyList("watch-property-lists/application-context.xml")
        let snapshot = WatchRecordingSnapshot(dictionary: fixture)

        WatchLocalSnapshotStore.save(snapshot, defaults: defaults)
        let loaded = try XCTUnwrap(WatchLocalSnapshotStore.load(defaults: defaults))

        XCTAssertEqual(loaded.phase, .recording)
        XCTAssertEqual(loaded.stateRevision, 3)
        XCTAssertEqual(loaded.selectedPresetID, "fixture")
        XCTAssertNotNil(defaults.dictionary(forKey: WatchLocalSnapshotStore.snapshotKey))
    }

    func testCommittedWatchPresetDefaultsUseProductionStoresAndRejectMalformedBytes() throws {
        let suiteName = "AndroidWearM0WatchPresetStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try fixtureData("watch-defaults/pending-v1.json"),
            forKey: WatchPresetSelectionStore.pendingKey
        )
        defaults.set(
            try fixtureData("watch-defaults/confirmed-v1.json"),
            forKey: WatchConfirmedPresetStore.confirmedKey
        )
        let pending = try XCTUnwrap(WatchPresetSelectionStore.loadPending(defaults: defaults))
        let confirmed = try XCTUnwrap(WatchConfirmedPresetStore.load(defaults: defaults))
        XCTAssertEqual(pending.presetID, "fixture")
        XCTAssertEqual(pending.epoch, 1_700_000_000_000)
        XCTAssertEqual(pending.sequence, 7)
        XCTAssertEqual(confirmed.id, "fixture")
        XCTAssertFalse(confirmed.snapshot.isEmpty)

        defaults.set(
            try fixtureData("negative/watch-defaults/pending-wrong-sequence.json"),
            forKey: WatchPresetSelectionStore.pendingKey
        )
        defaults.set(
            try fixtureData("negative/watch-defaults/confirmed-missing-id.json"),
            forKey: WatchConfirmedPresetStore.confirmedKey
        )
        XCTAssertNil(WatchPresetSelectionStore.loadPending(defaults: defaults))
        XCTAssertNil(WatchConfirmedPresetStore.load(defaults: defaults))

        var confirmedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData("watch-defaults/confirmed-v1.json")) as? [String: Any]
        )
        confirmedObject["futureFixtureField"] = true
        defaults.set(
            try JSONSerialization.data(withJSONObject: confirmedObject),
            forKey: WatchConfirmedPresetStore.confirmedKey
        )
        XCTAssertEqual(WatchConfirmedPresetStore.load(defaults: defaults)?.id, "fixture")
        confirmedObject["snapshot"] = "***"
        defaults.set(
            try JSONSerialization.data(withJSONObject: confirmedObject),
            forKey: WatchConfirmedPresetStore.confirmedKey
        )
        XCTAssertNil(WatchConfirmedPresetStore.load(defaults: defaults))

        var pendingObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData("watch-defaults/pending-v1.json")) as? [String: Any]
        )
        pendingObject["futureFixtureField"] = true
        defaults.set(
            try JSONSerialization.data(withJSONObject: pendingObject),
            forKey: WatchPresetSelectionStore.pendingKey
        )
        XCTAssertEqual(WatchPresetSelectionStore.loadPending(defaults: defaults)?.presetID, "fixture")
        pendingObject.removeValue(forKey: "epoch")
        defaults.set(
            try JSONSerialization.data(withJSONObject: pendingObject),
            forKey: WatchPresetSelectionStore.pendingKey
        )
        XCTAssertNil(WatchPresetSelectionStore.loadPending(defaults: defaults))

        defaults.removeObject(forKey: WatchPresetSelectionStore.pendingKey)
        defaults.removeObject(forKey: WatchConfirmedPresetStore.confirmedKey)
        XCTAssertNil(WatchPresetSelectionStore.loadPending(defaults: defaults))
        XCTAssertNil(WatchConfirmedPresetStore.load(defaults: defaults))
    }

    func testWatchPresetSequenceOverflowRollsEpochAndRestartsAtOne() throws {
        let suiteName = "AndroidWearM0WatchPresetOverflow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Int64(100), forKey: WatchPresetSelectionStore.epochKey)
        defaults.set(Int64.max, forKey: WatchPresetSelectionStore.sequenceKey)
        let pending = WatchPresetSelectionStore.makePending(
            presetID: "fixture",
            defaults: defaults,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            requestID: "overflow-request"
        )
        XCTAssertEqual(pending.sequence, 1)
        XCTAssertEqual(pending.epoch, 1_700_000_000_000)
    }

    func testCommittedWatchQueueStoreRecoversLegacyActiveAndOrphanAudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidWearM0WatchQueue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for filename in [
            "active-recording.json", "watch-active.m4a", "watch-orphan.m4a",
        ] {
            try fixtureData("watch-local-queue/\(filename)").write(
                to: root.appendingPathComponent(filename)
            )
        }
        try fixtureData("watch-local-queue/index-legacy.json").write(
            to: root.appendingPathComponent("index.json")
        )
        try Data(repeating: 1, count: 16).write(to: root.appendingPathComponent("watch-legacy.m4a"))
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = WatchLocalRecordingQueueStore(
            recordingsDirectoryURL: root,
            now: { fixedDate }
        )

        let recovered = store.loadRecoveringInterruptedCapture()
        XCTAssertEqual(Set(recovered.map(\.id)), ["legacy", "active", "orphan"])
        XCTAssertEqual(recovered.first(where: { $0.id == "legacy" })?.transportState, .local)
        XCTAssertEqual(recovered.first(where: { $0.id == "legacy" })?.remoteRevision, 0)
        XCTAssertEqual(recovered.first(where: { $0.id == "active" })?.transportState, .local)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-recording.json").path))
    }

    func testWatchQueueUnknownFieldsLoadAndUnknownEnumsPreserveAudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidWearM0WatchQueueEnums-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var index = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData("watch-local-queue/index-current.json")) as? [[String: Any]]
        )
        let filename = try XCTUnwrap(index.first?["filename"] as? String)
        try Data(repeating: 4, count: 16).write(to: root.appendingPathComponent(filename))
        index[0]["futureFixtureField"] = true
        try JSONSerialization.data(withJSONObject: index).write(to: root.appendingPathComponent("index.json"))
        let store = WatchLocalRecordingQueueStore(recordingsDirectoryURL: root)
        XCTAssertEqual(store.loadRecoveringInterruptedCapture().count, 1)

        index[0]["transportState"] = "futureTransport"
        let rejected = try JSONSerialization.data(withJSONObject: index)
        try rejected.write(to: root.appendingPathComponent("index.json"))
        let recovered = store.loadRecoveringInterruptedCapture()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].filename, filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(filename).path))
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("index-corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), rejected)
    }

    func testCommittedCurrentWatchQueueLoadsAllDurableFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidWearM0WatchQueueCurrent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let filename = "watch-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.m4a"
        try fixtureData("watch-local-queue/index-current.json").write(
            to: root.appendingPathComponent("index.json")
        )
        try Data(repeating: 4, count: 16).write(to: root.appendingPathComponent(filename))

        let item = try XCTUnwrap(
            WatchLocalRecordingQueueStore(recordingsDirectoryURL: root)
                .loadRecoveringInterruptedCapture().first
        )
        XCTAssertEqual(item.transportState, .transferring)
        XCTAssertEqual(item.remotePhase, .queued)
        XCTAssertEqual(item.remoteRevision, 3)
        XCTAssertEqual(item.presetID, "fixture")
        XCTAssertNotNil(item.locationOutcome)
    }

    func testWatchQueueStoreRejectsUnsafePersistedFilename() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidWearM0WatchQueueUnsafe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.m4a")
        try Data(repeating: 9, count: 16).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let unsafe = WatchLocalQueuedRecording(
            id: "unsafe",
            filename: "../outside.m4a",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1
        )
        try JSONEncoder().encode([unsafe]).write(to: root.appendingPathComponent("index.json"))

        let recovered = WatchLocalRecordingQueueStore(recordingsDirectoryURL: root)
            .loadRecoveringInterruptedCapture()

        XCTAssertTrue(recovered.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testWatchQueueReplayReconcilesFailureRetryAndUploadIdempotently() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidWearM0WatchReplay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WatchLocalRecordingQueueStore(recordingsDirectoryURL: root)
        let item = WatchLocalQueuedRecording(
            id: "replay",
            filename: "watch-replay.m4a",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1,
            transportState: .transferring
        )
        let failed = store.reconcilingTransferCompletion(
            recordings: [item], recordingID: item.id, didSucceed: false
        )
        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertEqual(failed.recordings[0].transportState, .local)

        var retryItem = item
        retryItem.remotePhase = .transportFailed
        let retry = store.reconcilingTransferCompletion(
            recordings: [retryItem], recordingID: item.id, didSucceed: true
        )
        XCTAssertEqual(retry.outcome, .retryRequired)
        XCTAssertEqual(retry.recordings[0].transportState, .local)

        let uploaded = store.reconcilingTransferCompletion(
            recordings: [item], recordingID: item.id, didSucceed: true
        )
        XCTAssertEqual(uploaded.outcome, .uploaded)
        XCTAssertEqual(uploaded.recordings[0].transportState, .uploaded)
        XCTAssertEqual(uploaded.recordings[0].remotePhase, .queued)
    }

    func testPersistedTerminalReconciliationSavesThenDeletesAudioAndReplays() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidWearM0WatchPersistedTerminal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WatchLocalRecordingQueueStore(recordingsDirectoryURL: root)
        let recording = WatchLocalQueuedRecording(
            id: "fixture-recording",
            filename: "watch-fixture-recording.m4a",
            createdAt: Date(timeIntervalSince1970: 1),
            duration: 1,
            transportState: .uploaded,
            remotePhase: .delivering,
            remoteRevision: 3
        )
        try store.save([recording])
        try Data(repeating: 7, count: 16).write(to: store.audioURL(for: recording))
        let terminal = try XCTUnwrap(WatchRemoteRecordingStatus(dictionary: [
            WatchRecordingPayloadKey.recordingID: recording.id,
            WatchRecordingPayloadKey.phase: WatchRemoteRecordingPhase.delivered.rawValue,
            WatchRecordingPayloadKey.revision: 4,
        ]))

        let persisted = try store.applyRemoteStatusesPersisting([terminal], recordings: [recording])
        XCTAssertTrue(persisted.reconciliation.recordings.isEmpty)
        XCTAssertEqual(persisted.deletedAudioRecordings, [recording])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: recording).path))
        XCTAssertTrue(store.loadRecoveringInterruptedCapture().isEmpty)

        let replay = try store.applyRemoteStatusesPersisting(
            [terminal],
            recordings: persisted.reconciliation.recordings
        )
        XCTAssertTrue(replay.reconciliation.recordings.isEmpty)
        XCTAssertEqual(replay.reconciliation.terminalAcknowledgements.count, 1)
        XCTAssertTrue(replay.deletedAudioRecordings.isEmpty)
    }

    func testWatchQueueRemoteReconciliationIgnoresStaleAndAcknowledgesTerminalReplay() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidWearM0WatchRemote-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WatchLocalRecordingQueueStore(recordingsDirectoryURL: root)
        var item = WatchLocalQueuedRecording(
            id: "remote",
            filename: "watch-remote.m4a",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1
        )
        item.remoteRevision = 3
        let stale = WatchRemoteRecordingStatus(dictionary: [
            WatchRecordingPayloadKey.recordingID: item.id,
            WatchRecordingPayloadKey.phase: WatchRemoteRecordingPhase.transcribing.rawValue,
            WatchRecordingPayloadKey.revision: 3,
            WatchRecordingPayloadKey.updatedAt: 1_700_000_001.0,
        ])!
        XCTAssertEqual(
            store.reconcilingRemoteStatuses([stale], recordings: [item]).recordings,
            [item]
        )
        let delivered = WatchRemoteRecordingStatus(dictionary: [
            WatchRecordingPayloadKey.recordingID: item.id,
            WatchRecordingPayloadKey.phase: WatchRemoteRecordingPhase.delivered.rawValue,
            WatchRecordingPayloadKey.revision: 4,
            WatchRecordingPayloadKey.updatedAt: 1_700_000_002.0,
        ])!
        let terminal = store.reconcilingRemoteStatuses([delivered], recordings: [item])
        XCTAssertTrue(terminal.recordings.isEmpty)
        XCTAssertEqual(terminal.removedRecordings, [item])
        XCTAssertEqual(
            terminal.terminalAcknowledgements,
            [WatchLocalTerminalAcknowledgement(recordingID: item.id, revision: 4)]
        )
        let replay = store.reconcilingRemoteStatuses([delivered], recordings: [])
        XCTAssertEqual(replay.terminalAcknowledgements.count, 1)
    }

    func testWatchQueueStoreBacksUpCorruptIndexAndPreservesAudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidWearM0WatchQueueCorrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: root.appendingPathComponent("index.json"))
        try Data(repeating: 4, count: 16).write(to: root.appendingPathComponent("watch-safe.m4a"))
        let store = WatchLocalRecordingQueueStore(
            recordingsDirectoryURL: root,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        XCTAssertEqual(store.loadRecoveringInterruptedCapture().map(\.id), ["safe"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("index-corrupt-1700000000.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("watch-safe.m4a").path))
    }

    func testWatchSnapshotDictionaryRoundTripPreservesDurableFields() {
        let snapshot = WatchRecordingSnapshot(
            phase: .paused,
            sentAt: 1_700_000_001,
            stateEpoch: 100,
            stateRevision: 7,
            isQuickRecordEnabled: true,
            recordingStartedAt: 1_700_000_000,
            recordingDuration: 42,
            message: "Synthetic paused snapshot",
            queuedCount: 2,
            selectedPresetID: "fixture",
            selectedPresetName: "Synthetic Fixture",
            selectedPresetSnapshot: Data([1, 2, 3])
        )
        let roundTrip = WatchRecordingSnapshot(dictionary: snapshot.dictionary)
        XCTAssertEqual(roundTrip.phase, .paused)
        XCTAssertEqual(roundTrip.stateEpoch, 100)
        XCTAssertEqual(roundTrip.stateRevision, 7)
        XCTAssertEqual(roundTrip.recordingDuration, 42)
        XCTAssertEqual(roundTrip.queuedCount, 2)
        XCTAssertEqual(roundTrip.selectedPresetSnapshot, Data([1, 2, 3]))
    }

    private func fixtureData(_ relativePath: String) throws -> Data {
        try Data(contentsOf: fixtureURL(relativePath))
    }

    private func fixturePropertyList(_ relativePath: String) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(
            from: fixtureData(relativePath),
            options: [],
            format: nil
        )
        return try XCTUnwrap(object as? [String: Any])
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packages/VoxboardShared/Tests/Fixtures/Persistence/v1")
            .appendingPathComponent(relativePath)
    }
}
