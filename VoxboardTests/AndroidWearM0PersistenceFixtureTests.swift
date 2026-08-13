import XCTest
import VoxboardShared
@testable import Voxboard

final class AndroidWearM0PersistenceFixtureTests: XCTestCase {
    func testCommittedWatchInboxFixturesUseProductionCodec() throws {
        let currentData = try fixtureData("watch-inbox/item-current.json")
        let current = try JSONDecoder().decode(WatchRecordingInboxItem.self, from: currentData)

        XCTAssertEqual(current.requestID, UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        XCTAssertEqual(current.phase, .failed)
        XCTAssertEqual(current.failureStage, .delivery)
        XCTAssertEqual(current.revision, 3)
        XCTAssertTrue(current.capturesRecordingWithoutTranscript)
        XCTAssertEqual(current.flowSnapshot?.id, "fixture")

        let legacyData = try fixtureData("watch-inbox/item-legacy.json")
        let legacy = try JSONDecoder().decode(WatchRecordingInboxItem.self, from: legacyData)
        XCTAssertEqual(legacy.id, "legacy-watch-fixture")
        XCTAssertEqual(legacy.filename, "legacy-watch.m4a")
        XCTAssertEqual(legacy.phase, .queued)
        XCTAssertEqual(legacy.revision, 1)
        XCTAssertFalse(legacy.capturesRecordingWithoutTranscript)
        XCTAssertFalse(legacy.requiresPresetSelection)
        XCTAssertNil(legacy.locationOutcome)
    }

    func testCommittedMalformedWatchInboxFixtureIsRejectedByProductionCodec() throws {
        let data = try fixtureData("negative/watch-inbox/malformed.json")
        XCTAssertThrowsError(try JSONDecoder().decode(WatchRecordingInboxItem.self, from: data))
    }

    func testCommittedWatchApplicationContextsUseProductionPayloadKeys() throws {
        let xml = try fixturePropertyList("watch-property-lists/application-context.xml")
        let binary = try fixturePropertyList("watch-property-lists/application-context.binary.plist")

        for dictionary in [xml, binary] {
            XCTAssertEqual(dictionary[WatchRecordingPayloadKey.phase] as? String, "recording")
            XCTAssertEqual(dictionary[WatchRecordingPayloadKey.isQuickRecordEnabled] as? Bool, true)
            XCTAssertEqual(dictionary[WatchRecordingPayloadKey.queuedCount] as? Int, 1)
            XCTAssertEqual(dictionary[WatchRecordingPayloadKey.selectedPresetID] as? String, "fixture")
            XCTAssertEqual(dictionary[WatchRecordingPayloadKey.stateRevision] as? Int, 3)
            let statuses = try XCTUnwrap(
                dictionary[WatchRecordingPayloadKey.recordingStatuses] as? [[String: Any]]
            )
            XCTAssertEqual(statuses.count, 1)
            XCTAssertEqual(statuses.first?[WatchRecordingPayloadKey.phase] as? String, "failed")
        }
    }

    func testCommittedLegacyWatchApplicationContextUsesProductionDefaults() throws {
        let dictionary = try fixturePropertyList(
            "watch-property-lists/application-context-legacy-minimal.xml"
        )
        XCTAssertEqual(dictionary[WatchRecordingPayloadKey.phase] as? String, "idle")
        XCTAssertEqual(dictionary[WatchRecordingPayloadKey.isQuickRecordEnabled] as? Bool, true)
        XCTAssertNil(dictionary[WatchRecordingPayloadKey.stateEpoch])
        XCTAssertNil(dictionary[WatchRecordingPayloadKey.stateRevision])
        XCTAssertNil(dictionary[WatchRecordingPayloadKey.recordingStatuses])
    }

    func testCommittedWatchFileMetadataUsesProductionConsumer() throws {
        let xml = try fixturePropertyList("watch-property-lists/file-metadata.xml")
        let binary = try fixturePropertyList("watch-property-lists/file-metadata.binary.plist")

        for metadata in [xml, binary] {
            XCTAssertEqual(
                metadata[WatchRecordingFileMetadataKey.kind] as? String,
                WatchRecordingFileMetadataKey.watchAudioRecordingKind
            )
            XCTAssertEqual(
                metadata[WatchRecordingFileMetadataKey.recordingID] as? String,
                "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )
            let presetData = try XCTUnwrap(
                metadata[WatchRecordingFileMetadataKey.presetSnapshot] as? Data
            )
            XCTAssertEqual(try JSONDecoder().decode(CapturePreset.self, from: presetData).id, "fixture")
            XCTAssertNotNil(WatchRecordingFileMetadataKey.decodeLocationOutcome(from: metadata))
            XCTAssertFalse(WatchRecordingFileMetadataKey.containsIncompatibleLocationOutcome(in: metadata))
        }
    }

    func testCommittedLegacyPhoneWatchCommandsAndPresetResponsesRemainPropertyListSafe() throws {
        let commands: [WatchRecordingCommand] = [.start, .stop, .toggle, .status, .acknowledge, .selectPreset]
        for command in commands {
            let decoded = try fixturePropertyList(
                "watch-property-lists/commands/\(command.rawValue).xml"
            )
            XCTAssertEqual(decoded[WatchRecordingPayloadKey.command] as? String, command.rawValue)
            switch command {
            case .acknowledge:
                XCTAssertNotNil(decoded[WatchRecordingPayloadKey.recordingID] as? String)
                XCTAssertEqual(decoded[WatchRecordingPayloadKey.revision] as? Int, 3)
            case .selectPreset:
                XCTAssertEqual(decoded[WatchRecordingPayloadKey.requestedPresetID] as? String, "fixture")
                XCTAssertNotNil(decoded[WatchRecordingPayloadKey.presetSelectionRequestID] as? String)
            default:
                break
            }
        }

        let outcomes: [WatchPresetSelectionOutcome] = [.accepted, .rejected, .stale]
        for outcome in outcomes {
            let decoded = try fixturePropertyList(
                "watch-property-lists/preset-acknowledgements/\(outcome.rawValue).xml"
            )
            XCTAssertEqual(
                decoded[WatchRecordingPayloadKey.presetSelectionResult] as? String,
                outcome.rawValue
            )
            let response = WatchPresetSelectionResponse(
                requestID: try XCTUnwrap(
                    decoded[WatchRecordingPayloadKey.presetSelectionRequestID] as? String
                ),
                presetID: try XCTUnwrap(
                    decoded[WatchRecordingPayloadKey.requestedPresetID] as? String
                ),
                epoch: Int64(try XCTUnwrap(
                    decoded[WatchRecordingPayloadKey.presetSelectionEpoch] as? Int
                )),
                sequence: Int64(try XCTUnwrap(
                    decoded[WatchRecordingPayloadKey.presetSelectionSequence] as? Int
                )),
                outcome: outcome,
                errorMessage: decoded[WatchRecordingPayloadKey.presetSelectionError] as? String
            )
            XCTAssertEqual(response.dictionary[WatchRecordingPayloadKey.presetSelectionResult] as? String, outcome.rawValue)
        }
    }

    func testWatchControllerPersistenceHandlesMissingWrongTypesUnknownEnumsAndReplay() throws {
        let suiteName = "AndroidWearM0WatchControllerPersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WatchRecordingControllerPersistence(defaults: defaults)

        XCTAssertTrue(store.transportFailures().isEmpty)
        XCTAssertNil(store.loadPresetSelectionAcknowledgement())
        defaults.set("wrong", forKey: WatchRecordingControllerPersistence.transportFailuresKey)
        defaults.set("wrong", forKey: WatchRecordingControllerPersistence.stateEpochKey)
        defaults.set("wrong", forKey: WatchRecordingControllerPersistence.stateRevisionKey)
        defaults.set(-9, forKey: WatchRecordingControllerPersistence.transportFailureCursorKey)
        XCTAssertTrue(store.transportFailures().isEmpty)
        XCTAssertEqual(store.nextStateRevision(now: Date(timeIntervalSince1970: 1)), 1)

        store.setTransportFailure(recordingID: "b", message: "second")
        store.setTransportFailure(recordingID: "a", message: "first")
        XCTAssertEqual(store.nextTransportFailureBatch(limit: 1).map(\.0), ["a"])
        XCTAssertEqual(store.nextTransportFailureBatch(limit: 1).map(\.0), ["b"])
        store.clearTransportFailure(recordingID: "a")
        XCTAssertEqual(store.transportFailures(), ["b": "second"])

        let response = WatchPresetSelectionResponse(
            requestID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            presetID: "fixture",
            epoch: 7,
            sequence: 9,
            outcome: .accepted,
            errorMessage: nil
        )
        store.savePresetSelectionAcknowledgement(response)
        let loadedResponse = try XCTUnwrap(store.loadPresetSelectionAcknowledgement())
        XCTAssertEqual(loadedResponse.requestID, response.requestID)
        XCTAssertEqual(loadedResponse.presetID, response.presetID)
        XCTAssertEqual(loadedResponse.epoch, response.epoch)
        XCTAssertEqual(loadedResponse.sequence, response.sequence)
        XCTAssertEqual(loadedResponse.outcome, response.outcome)
        defaults.set("futureOutcome", forKey: WatchRecordingControllerPersistence.presetSelectionResultKey)
        XCTAssertNil(store.loadPresetSelectionAcknowledgement())

        defaults.set(Int.max, forKey: WatchRecordingControllerPersistence.stateRevisionKey)
        defaults.set(Int.max, forKey: WatchRecordingControllerPersistence.stateEpochKey)
        XCTAssertEqual(store.nextStateRevision(now: Date(timeIntervalSince1970: 2)), 1)
        XCTAssertGreaterThan(store.stateEpoch(now: Date(timeIntervalSince1970: 2)), 0)
    }

    func testWatchInboxUnknownFieldsLoadAndUnknownEnumsStayPreserved() throws {
        let compatible = try JSONDecoder().decode(
            WatchRecordingInboxItem.self,
            from: fixtureData("compatibility/watch-inbox/unknown-field.json")
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidWearM0WatchInboxUnknown-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try fixtureData("compatibility/watch-inbox/unknown-field.json").write(
            to: root.appendingPathComponent("item-\(compatible.id).json")
        )
        XCTAssertEqual(
            WatchRecordingInbox(compatibilityFixtureDirectoryURL: root).load().map(\.id),
            [compatible.id]
        )

        let rejected = try fixtureData("negative/watch-inbox/unknown-phase-enum.json")
        let rejectedURL = root.appendingPathComponent("item-unknown-enum.json")
        try rejected.write(to: rejectedURL)
        XCTAssertThrowsError(
            try JSONDecoder().decode(WatchRecordingInboxItem.self, from: rejected)
        )
        _ = WatchRecordingInbox(compatibilityFixtureDirectoryURL: root).load()
        XCTAssertEqual(try Data(contentsOf: rejectedURL), rejected)
    }

    func testCommittedWatchInboxIndexSidecarsAndTombstonesUseProductionStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidWearM0WatchInbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let current = try JSONDecoder().decode(
            WatchRecordingInboxItem.self,
            from: fixtureData("watch-inbox/item-current.json")
        )
        var delivered = current
        delivered.phase = .delivered
        delivered.deliveredAt = Date(timeIntervalSince1970: 1_700_000_010)
        delivered.scrubSensitivePayloadForTombstone()
        try WatchRecordingInbox.writeCompatibilityFixture(
            items: [current, delivered],
            directoryURL: root
        )
        let store = WatchRecordingInbox(compatibilityFixtureDirectoryURL: root)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("item-\(current.id).json").path))
        let terminal = try XCTUnwrap(loaded.first(where: { $0.phase == .delivered }))
        XCTAssertNil(terminal.flowSnapshot)
        XCTAssertNil(terminal.locationOutcome)
        XCTAssertNil(terminal.reservedOutputFolderBookmark)
    }

    func testWatchInboxStoreBacksUpCorruptIndexAndRecoversCommittedSidecar() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidWearM0WatchInboxCorrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: root.appendingPathComponent("index.json"))
        let current = try JSONDecoder().decode(
            WatchRecordingInboxItem.self,
            from: fixtureData("watch-inbox/item-current.json")
        )
        try fixtureData("watch-inbox/item-current.json").write(
            to: root.appendingPathComponent("item-\(current.id).json")
        )

        let loaded = WatchRecordingInbox(compatibilityFixtureDirectoryURL: root).load()

        XCTAssertEqual(loaded.map(\.id), [current.id])
        let backups = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("index-corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), Data("not-json".utf8))
    }

    func testCommittedWatchInboxStoreRecoversNewerSidecarAndOrphanAudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidWearM0WatchInboxRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var stale = try JSONDecoder().decode(
            WatchRecordingInboxItem.self,
            from: fixtureData("watch-inbox/item-current.json")
        )
        stale.revision = 1
        var newer = stale
        newer.revision = 9
        newer.statusMessage = "Recovered newer sidecar"
        try JSONEncoder().encode([stale]).write(to: root.appendingPathComponent("index.json"))
        try JSONEncoder().encode(newer).write(
            to: root.appendingPathComponent("item-\(newer.id).json")
        )
        try Data(repeating: 3, count: 32).write(
            to: root.appendingPathComponent("watch-orphan-fixture.m4a")
        )

        let loaded = WatchRecordingInbox(compatibilityFixtureDirectoryURL: root).load()
        XCTAssertEqual(loaded.first(where: { $0.id == newer.id })?.revision, 9)
        let orphan = try XCTUnwrap(loaded.first(where: { $0.id == "orphan-fixture" }))
        XCTAssertEqual(orphan.phase, .failed)
        XCTAssertEqual(orphan.failureStage, .storage)
        XCTAssertTrue(orphan.requiresPresetSelection)
        let store = WatchRecordingInbox(compatibilityFixtureDirectoryURL: root)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.compatibilityFixtureAudioURL(for: orphan).path
            )
        )
    }

    func testInspirationQuoteCacheCompatibilityAndMalformedFallbackPreserveBytes() async throws {
        let suiteName = "AndroidWearM0InspirationQuoteCompatibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [M0FailingURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let compatible: [String: Any] = [
            "quotes": [["text": "Synthetic compatible quote", "author": "Fixture", "future": true]],
            "fetchedAt": Date().timeIntervalSinceReferenceDate,
            "nextIndex": 0,
            "futureFixtureField": ["ignored": true],
        ]
        let compatibleData = try JSONSerialization.data(withJSONObject: compatible)
        defaults.set(compatibleData, forKey: InspirationQuoteService.cacheKey)
        let compatibleQuote = await InspirationQuoteService(
            session: session,
            defaults: defaults
        ).nextQuote()
        XCTAssertEqual(
            compatibleQuote,
            InspirationQuote(text: "Synthetic compatible quote", author: "Fixture")
        )

        for rejected in [
            try JSONSerialization.data(withJSONObject: [
                "quotes": [["text": "Missing date", "author": "Fixture"]],
                "nextIndex": 0,
            ]),
            Data("{synthetic malformed quote cache".utf8),
        ] {
            defaults.set(rejected, forKey: InspirationQuoteService.cacheKey)
            let fallbackQuote = await InspirationQuoteService(
                session: session,
                defaults: defaults
            ).nextQuote()
            XCTAssertEqual(fallbackQuote, .fallback)
            XCTAssertEqual(defaults.data(forKey: InspirationQuoteService.cacheKey), rejected)
        }
    }

    func testInspirationQuoteStoreConsumesSyntheticDefaultsFixture() async throws {
        let suiteName = "AndroidWearM0InspirationQuote.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache: [String: Any] = [
            "quotes": [["text": "Synthetic local quote", "author": "Fixture"]],
            "fetchedAt": Date().timeIntervalSinceReferenceDate,
            "nextIndex": 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys])
        defaults.set(data, forKey: InspirationQuoteService.cacheKey)
        let quote = await InspirationQuoteService(defaults: defaults).nextQuote()
        XCTAssertEqual(quote, InspirationQuote(text: "Synthetic local quote", author: "Fixture"))
    }

    func testOnboardingAnalyticsCompletionMarkersAreOneShot() throws {
        let suiteName = "AndroidWearM0AnalyticsMarkers.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for key in [
            PersistentRecorder.modelSetupAnalyticsKey,
            PersistentRecorder.completionAnalyticsKey,
        ] {
            XCTAssertTrue(PersistentRecorder.claimOneShotAnalyticsMarker(key, defaults: defaults))
            XCTAssertTrue(defaults.bool(forKey: key))
            XCTAssertFalse(PersistentRecorder.claimOneShotAnalyticsMarker(key, defaults: defaults))
            defaults.set("malformed-marker", forKey: key)
            XCTAssertTrue(PersistentRecorder.claimOneShotAnalyticsMarker(key, defaults: defaults))
            XCTAssertTrue(defaults.bool(forKey: key))
        }
    }

    func testReviewPromptManagerPersistsAtomicEligibilityState() throws {
        let suiteName = "AndroidWearM0ReviewPrompt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let manager = ReviewPromptManager(defaults: defaults, calendar: Calendar(identifier: .gregorian), now: { now })
        manager.recordAppUsageDay()
        manager.recordSuccessfulCapture(totalCaptureCount: 3)
        XCTAssertEqual(defaults.integer(forKey: ReviewPromptManager.Keys.successfulCaptureCount), 3)
        XCTAssertEqual(defaults.stringArray(forKey: ReviewPromptManager.Keys.usageDayIdentifiers)?.count, 1)
        XCTAssertTrue(defaults.bool(forKey: ReviewPromptManager.Keys.pendingPrompt))
        XCTAssertEqual(defaults.double(forKey: ReviewPromptManager.Keys.lastPromptAttemptAt), 0)
    }

    func testCommittedSettingsSnapshotUsesProductionToolbarPersistence() throws {
        let snapshot = try fixtureSettingsSnapshot()
        let suiteName = "AndroidWearM0PersistenceFixtureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for (key, value) in snapshot {
            defaults.set(value, forKey: key)
        }

        let preferences = CaptureToolbarPreferences(defaults: defaults)
        XCTAssertEqual(
            Array(preferences.orderedActions.prefix(2)),
            [.addMedia, .currentLocation]
        )
        XCTAssertEqual(Set(preferences.orderedActions), Set(CaptureToolbarAction.allCases))
        XCTAssertFalse(preferences.isVisible(.paste))
        XCTAssertNoThrow(try XCTUnwrap(defaults.data(forKey: CaptureToolbarPreferences.storageKey)))
        XCTAssertFalse(preferences.confirmsVoiceNotesBeforeAdding)
        preferences.setConfirmsVoiceNotesBeforeAdding(true)
        XCTAssertTrue(preferences.confirmsVoiceNotesBeforeAdding)
        XCTAssertTrue(defaults.bool(forKey: CapturePreferenceKeys.confirmVoiceNoteBeforeAdding))
    }

    func testToolbarPreferencesUseProductionDefaultsForMissingAndMalformedBytes() throws {
        let suiteName = "AndroidWearM0ToolbarDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let missing = CaptureToolbarPreferences(defaults: defaults)
        XCTAssertEqual(missing.orderedActions, CaptureToolbarAction.allCases)
        XCTAssertTrue(missing.hiddenActions.isEmpty)

        defaults.set(Data("not-json".utf8), forKey: CaptureToolbarPreferences.storageKey)
        let malformed = CaptureToolbarPreferences(defaults: defaults)
        XCTAssertEqual(malformed.orderedActions, CaptureToolbarAction.allCases)
        XCTAssertTrue(malformed.hiddenActions.isEmpty)
    }

    func testCommittedLegacyAndIncompatibleWatchFileMetadataUseProductionFallbacks() throws {
        let legacy = try fixturePropertyList(
            "watch-property-lists/file-metadata-legacy-minimal.xml"
        )
        XCTAssertNil(legacy[WatchRecordingFileMetadataKey.presetSnapshot])
        XCTAssertNil(WatchRecordingFileMetadataKey.decodeLocationOutcome(from: legacy))
        XCTAssertFalse(WatchRecordingFileMetadataKey.containsIncompatibleLocationOutcome(in: legacy))

        let incompatible = try fixturePropertyList(
            "watch-property-lists/file-metadata-incompatible.xml"
        )
        XCTAssertThrowsError(try JSONDecoder().decode(
            CapturePreset.self,
            from: try XCTUnwrap(incompatible[WatchRecordingFileMetadataKey.presetSnapshot] as? Data)
        ))
        XCTAssertNil(WatchRecordingFileMetadataKey.decodeLocationOutcome(from: incompatible))
        XCTAssertTrue(WatchRecordingFileMetadataKey.containsIncompatibleLocationOutcome(in: incompatible))
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

    private func fixtureSettingsSnapshot() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(
            with: fixtureData("settings/allowlisted-settings-v1.json")
        )
        let root = try XCTUnwrap(object as? [String: Any])
        let values = try XCTUnwrap(root["values"] as? [String: [String: Any]])
        return try values.mapValues { encoded in
            let type = try XCTUnwrap(encoded["type"] as? String)
            let value = try XCTUnwrap(encoded["value"])
            switch type {
            case "string", "double", "int64", "bool", "stringDoubleDictionary":
                return value
            case "data":
                return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(value as? String)))
            default:
                throw NSError(
                    domain: "AndroidWearM0PersistenceFixtureTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown settings fixture type: \(type)"]
                )
            }
        }
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packages/VoxboardShared/Tests/Fixtures/Persistence/v1")
            .appendingPathComponent(relativePath)
    }
}

private final class M0FailingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
