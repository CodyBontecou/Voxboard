import XCTest
@testable import VoxboardShared

final class CapturePresetTests: XCTestCase {

    func test_defaultFlows_includeOnlyDefaultFlow() {
        XCTAssertEqual(CapturePresetStore.flowsKey, "recordingFlows")
        XCTAssertEqual(CapturePresetStore.selectedFlowIdKey, "selectedRecordingFlowId")
        XCTAssertEqual(CapturePresetProfileStore.selectedCaptureProfileIDKey, "selectedCaptureVoxId")

        let flows = CapturePresetStore.defaultFlows

        XCTAssertEqual(flows.map(\.id), [CapturePresetStore.generalId])
        XCTAssertEqual(flows.first?.displayName, "Default")
        XCTAssertEqual(flows.first?.symbolName, CapturePresetStore.defaultSymbolName)
        XCTAssertEqual(flows.first?.kind, .general)
        XCTAssertEqual(flows.first?.captureProcessingEnabled, false)
        XCTAssertEqual(flows.first?.speakerDiarizationEnabled, false)
        XCTAssertFalse(CapturePresetStore.makeCustomFlow().captureProcessingEnabled)
        XCTAssertFalse(CapturePresetStore.makeCustomFlow().speakerDiarizationEnabled)
    }

    func test_locationPolicyDefaultsDisabledAndRoundTripsIntoCaptureProfile() throws {
        var preset = CapturePresetStore.makeCustomFlow()
        XCTAssertFalse(preset.locationPolicy.isEnabled)

        preset.locationPolicy = CapturePresetLocationPolicy(
            isEnabled: true,
            precision: .city,
            unavailableBehavior: .sendWithoutLocation,
            outputMode: .advancedTemplate,
            structuredFields: [.city, .geoURI],
            collectionKey: "visits",
            advancedTemplate: "city: {{city}}"
        )
        let decoded = try JSONDecoder().decode(
            CapturePreset.self,
            from: JSONEncoder().encode(preset)
        )
        XCTAssertEqual(decoded.locationPolicy, preset.locationPolicy)
        XCTAssertEqual(decoded.captureProfile.locationPolicy, preset.locationPolicy)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "locationPolicy")
        let legacy = try JSONDecoder().decode(
            CapturePreset.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertFalse(legacy.locationPolicy.isEnabled)
        XCTAssertEqual(legacy.locationPolicy.structuredFields, CapturePresetLocationPolicy.defaultStructuredFields)
    }

    func test_alwaysSendWithoutLocationDecisionPersistsAndCanBeReset() throws {
        let suite = "RecordingFlowLocationPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preset = CapturePresetStore.makeCustomFlow()
        preset.locationPolicy = CapturePresetLocationPolicy(isEnabled: true, unavailableBehavior: .ask)
        CapturePresetStore.saveFlows([CapturePresetStore.defaultFlow, preset], defaults: defaults)

        CapturePresetStore.setLocationUnavailableBehavior(
            .sendWithoutLocation,
            presetID: preset.id,
            defaults: defaults
        )
        XCTAssertEqual(
            CapturePresetStore.loadFlows(defaults: defaults).first(where: { $0.id == preset.id })?
                .locationPolicy.unavailableBehavior,
            .sendWithoutLocation
        )

        CapturePresetStore.setLocationUnavailableBehavior(.ask, presetID: preset.id, defaults: defaults)
        XCTAssertEqual(
            CapturePresetStore.loadFlows(defaults: defaults).first(where: { $0.id == preset.id })?
                .locationPolicy.unavailableBehavior,
            .ask
        )
    }

    func test_concurrentUnavailableBehaviorUpdatesDoNotLoseAnotherPreset() throws {
        let suite = "RecordingFlowLocationLockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = CapturePresetStore.makeCustomFlow()
        let second = CapturePresetStore.makeCustomFlow()
        CapturePresetStore.saveFlows([CapturePresetStore.defaultFlow, first, second], defaults: defaults)

        DispatchQueue.concurrentPerform(iterations: 2) { index in
            CapturePresetStore.setLocationUnavailableBehavior(
                .sendWithoutLocation,
                presetID: index == 0 ? first.id : second.id,
                defaults: defaults
            )
        }
        let loaded = CapturePresetStore.loadFlows(defaults: defaults)
        XCTAssertEqual(
            loaded.first(where: { $0.id == first.id })?.locationPolicy.unavailableBehavior,
            .sendWithoutLocation
        )
        XCTAssertEqual(
            loaded.first(where: { $0.id == second.id })?.locationPolicy.unavailableBehavior,
            .sendWithoutLocation
        )
    }

    func test_speakerDiarizationIsOptInAndRoundTrips() throws {
        var flow = CapturePresetStore.makeCustomFlow()
        flow.speakerDiarizationEnabled = true

        let encoded = try JSONEncoder().encode(flow)
        XCTAssertTrue(try JSONDecoder().decode(CapturePreset.self, from: encoded).speakerDiarizationEnabled)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "speakerDiarizationEnabled")
        let legacy = try JSONDecoder().decode(
            CapturePreset.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertFalse(legacy.speakerDiarizationEnabled)
    }

    func test_usesAIEnrichment_isControlledByPostProcessingMode() {
        var flow = CapturePresetStore.defaultFlow
        XCTAssertTrue(flow.usesAIEnrichment)

        flow.postProcessingMode = .none
        XCTAssertFalse(flow.usesAIEnrichment)

        flow.postProcessingMode = .todoList
        XCTAssertTrue(flow.usesAIEnrichment)
    }

    func test_watchOutputDefaultsToTranscriptForExistingPresets() throws {
        XCTAssertEqual(CapturePresetStore.defaultFlow.watchOutputMode, .transcript)
        XCTAssertEqual(CapturePresetStore.makeCustomFlow().watchOutputMode, .transcript)

        let encoded = try JSONEncoder().encode(CapturePresetStore.makeCustomFlow())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "watchOutputMode")
        object.removeValue(forKey: "watchRecordingSettings")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CapturePreset.self, from: legacyData)

        XCTAssertEqual(decoded.watchOutputMode, .transcript)
        XCTAssertEqual(
            decoded.watchRecordingSettings.filenameTemplate,
            CapturePresetWatchRecordingSettings.defaultFilenameTemplate
        )
        XCTAssertNil(decoded.watchRecordingSettings.folderBookmark)
    }

    func test_recordingOnlyWatchSettingsRoundTrip() throws {
        var flow = CapturePresetStore.makeCustomFlow()
        flow.watchOutputMode = .recordingOnly
        flow.watchRecordingSettings = CapturePresetWatchRecordingSettings(
            folderBookmark: Data([7, 8, 9]),
            folderName: "Voice Notes",
            filenameTemplate: "{preset}-{date}-{id8}"
        )

        let decoded = try JSONDecoder().decode(
            CapturePreset.self,
            from: JSONEncoder().encode(flow)
        )

        XCTAssertEqual(decoded, flow)
        XCTAssertEqual(decoded.watchOutputMode, .recordingOnly)
        XCTAssertEqual(decoded.watchRecordingSettings.folderBookmark, Data([7, 8, 9]))
    }

    func test_capturePolicyRoundTripsAndMapsToLightweightProfile() throws {
        let destinationID = UUID()
        let templateID = UUID()
        var flow = CapturePresetStore.makeCustomFlow()
        flow.captureProcessingEnabled = true
        flow.capturePrompt = "What happened in the meeting?"
        flow.metadataScope = .entry
        flow.captureDestinationID = destinationID
        flow.captureEntryTemplateID = templateID
        flow.capturePlacementOverride = .prepend
        flow.staticFrontmatter = ["type": "meeting"]
        flow.postProcessingMode = .meetingNotes

        let decoded = try JSONDecoder().decode(
            CapturePreset.self,
            from: JSONEncoder().encode(flow)
        )

        XCTAssertEqual(decoded, flow)
        XCTAssertEqual(decoded.captureProfile.captureDestinationID, destinationID)
        XCTAssertEqual(decoded.captureProfile.captureEntryTemplateID, templateID)
        XCTAssertEqual(decoded.captureProfile.capturePlacementOverride, .prepend)
        XCTAssertTrue(decoded.captureProfile.captureProcessingEnabled)
        XCTAssertEqual(decoded.captureProfile.metadataScope, .entry)
    }

    func test_migrateLegacyCaptureBindingsDoesNotOverrideNewerVoxRoute() throws {
        let suiteName = "test.flow.migrate-route.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyDestinationID = UUID()
        let newerDestinationID = UUID()
        var legacyFlow = CapturePresetStore.makeCustomFlow()
        legacyFlow.id = "legacy"
        legacyFlow.captureDestinationID = nil
        var newerFlow = CapturePresetStore.makeCustomFlow()
        newerFlow.id = "newer"
        newerFlow.captureDestinationID = newerDestinationID
        CapturePresetStore.saveFlows([legacyFlow, newerFlow], defaults: defaults)

        let migrated = CapturePresetStore.migrateLegacyCaptureBindings(
            ["legacy": legacyDestinationID, "newer": legacyDestinationID],
            defaults: defaults
        )
        let loaded = CapturePresetStore.loadFlows(defaults: defaults)

        XCTAssertEqual(migrated, 1)
        XCTAssertEqual(loaded.first(where: { $0.id == "legacy" })?.captureDestinationID, legacyDestinationID)
        XCTAssertEqual(loaded.first(where: { $0.id == "newer" })?.captureDestinationID, newerDestinationID)
    }

    func test_ownedPresetRouteMigrationClonesSharedRouteAndFoldsOverrides() throws {
        let suiteName = "test.preset.owned-route.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sharedRoute = CaptureDestination(
            name: "Shared Inbox",
            rootBookmark: Data([1, 2, 3]),
            rootName: "Vault",
            noteTarget: .rollingNote(pathTemplate: "Journal/{period}.md", period: .daily),
            placement: .append
        )
        let templateID = UUID()
        var journal = CapturePresetStore.defaultFlow
        journal.name = "Journal"
        journal.captureDestinationID = sharedRoute.id
        var tasks = CapturePresetStore.makeCustomFlow()
        tasks.id = "tasks"
        tasks.name = "Tasks"
        tasks.captureDestinationID = sharedRoute.id
        tasks.capturePlacementOverride = .prepend
        tasks.captureEntryTemplateID = templateID
        CapturePresetStore.saveFlows([journal, tasks], defaults: defaults)
        defaults.set(tasks.id, forKey: CapturePresetProfileStore.selectedCaptureProfileIDKey)
        var library = CaptureLibraryEnvelope(
            destinations: [sharedRoute],
            defaultDestinationID: sharedRoute.id,
            entryTemplates: [CaptureEntryTemplate(id: templateID, name: "Task", entryPrefix: "- [ ] ")]
        )

        XCTAssertTrue(CapturePresetStore.migrateToOwnedPresetRoutes(library: &library, defaults: defaults))
        let migrated = CapturePresetStore.loadFlows(defaults: defaults)
        let journalPreset = try XCTUnwrap(migrated.first(where: { $0.id == journal.id }))
        let tasksPreset = try XCTUnwrap(migrated.first(where: { $0.id == tasks.id }))
        let journalRoute = try XCTUnwrap(library.destinations.first(where: { $0.id == journalPreset.captureDestinationID }))
        let tasksRoute = try XCTUnwrap(library.destinations.first(where: { $0.id == tasksPreset.captureDestinationID }))

        XCTAssertNotEqual(journalRoute.id, tasksRoute.id)
        XCTAssertEqual(journalRoute.name, "Journal")
        XCTAssertEqual(tasksRoute.name, "Tasks")
        XCTAssertEqual(tasksRoute.placement, .prepend)
        XCTAssertEqual(tasksRoute.entryTemplateID, templateID)
        XCTAssertNil(tasksPreset.capturePlacementOverride)
        XCTAssertNil(tasksPreset.captureEntryTemplateID)
        XCTAssertEqual(library.defaultDestinationID, tasksRoute.id)

        let stableLibrary = library
        let stablePresets = migrated
        XCTAssertFalse(CapturePresetStore.migrateToOwnedPresetRoutes(library: &library, defaults: defaults))
        XCTAssertEqual(library, stableLibrary)
        XCTAssertEqual(CapturePresetStore.loadFlows(defaults: defaults), stablePresets)
    }

    func test_ownedRouteMigrationCarriesLegacyVaultTemplateIntoDestination() throws {
        let suiteName = "test.preset.vault-template.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxboardVaultTemplate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Templates"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let templateURL = root.appendingPathComponent("Templates/Meeting.md")
        try "# Meeting".write(to: templateURL, atomically: true, encoding: .utf8)

        let route = CaptureDestination(
            name: "Meeting",
            rootBookmark: try root.bookmarkData(),
            rootName: root.lastPathComponent,
            noteTarget: .newNote(pathTemplate: "Meetings/{date}.md")
        )
        var preset = CapturePresetStore.makeCustomFlow()
        preset.id = "meeting-template"
        preset.captureDestinationID = route.id
        preset.exportSettings.markdownTemplateEnabled = true
        preset.exportSettings.markdownTemplateBookmark = try templateURL.bookmarkData()
        preset.exportSettings.markdownTemplateName = templateURL.lastPathComponent
        CapturePresetStore.saveFlows([preset], defaults: defaults)
        // Reproduce an install whose Custom Presets already completed the
        // owned-destination migration before vault templates were restored.
        defaults.set(
            CapturePresetProfileStore.currentOwnedRouteMigrationVersion,
            forKey: CapturePresetProfileStore.ownedRouteMigrationVersionKey
        )
        var library = CaptureLibraryEnvelope(destinations: [route], defaultDestinationID: route.id)

        XCTAssertTrue(CapturePresetStore.migrateToOwnedPresetRoutes(library: &library, defaults: defaults))

        let migratedPreset = try XCTUnwrap(
            CapturePresetStore.flow(id: preset.id, defaults: defaults)
        )
        let migratedRoute = try XCTUnwrap(
            library.destinations.first(where: { $0.id == migratedPreset.captureDestinationID })
        )
        XCTAssertEqual(migratedRoute.markdownTemplatePath, "Templates/Meeting.md")
        XCTAssertFalse(migratedPreset.exportSettings.markdownTemplateEnabled)
        XCTAssertNil(migratedPreset.exportSettings.markdownTemplateBookmark)
        XCTAssertEqual(migratedPreset.exportSettings.markdownTemplateName, "")
    }

    func test_stalePresetWriterPreservesRouteOwnershipAfterMigration() throws {
        let suiteName = "test.preset.stale-writer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sharedRoute = CaptureDestination(
            name: "Shared",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        var first = CapturePresetStore.defaultFlow
        first.captureDestinationID = sharedRoute.id
        var second = CapturePresetStore.makeCustomFlow()
        second.id = "second"
        second.captureDestinationID = sharedRoute.id
        second.capturePlacementOverride = .prepend
        let staleSnapshot = [first, second]
        CapturePresetStore.saveFlows(staleSnapshot, defaults: defaults)
        var library = CaptureLibraryEnvelope(
            destinations: [sharedRoute],
            defaultDestinationID: sharedRoute.id
        )
        XCTAssertTrue(CapturePresetStore.migrateToOwnedPresetRoutes(library: &library, defaults: defaults))
        let migratedSecond = try XCTUnwrap(
            CapturePresetStore.flow(id: second.id, defaults: defaults)
        )
        XCTAssertNotEqual(migratedSecond.captureDestinationID, sharedRoute.id)

        var staleEdit = staleSnapshot
        staleEdit[1].name = "Edited During Migration"
        CapturePresetStore.saveFlows(staleEdit, defaults: defaults)

        let savedSecond = try XCTUnwrap(
            CapturePresetStore.flow(id: second.id, defaults: defaults)
        )
        XCTAssertEqual(savedSecond.name, "Edited During Migration")
        XCTAssertEqual(savedSecond.captureDestinationID, migratedSecond.captureDestinationID)
        XCTAssertNil(savedSecond.capturePlacementOverride)
    }

    func test_stalePresetWriterPreservesFallbackOwnershipAndPromotedOrphans() throws {
        let suiteName = "test.preset.stale-fallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fallback = CaptureDestination(
            name: "Fallback",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        let orphan = CaptureDestination(
            name: "Archive",
            rootBookmark: Data([2]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Archive.md")
        )
        var stalePreset = CapturePresetStore.defaultFlow
        stalePreset.captureDestinationID = nil
        let staleSnapshot = [stalePreset]
        CapturePresetStore.saveFlows(staleSnapshot, defaults: defaults)
        var library = CaptureLibraryEnvelope(
            destinations: [fallback, orphan],
            defaultDestinationID: fallback.id
        )
        XCTAssertTrue(CapturePresetStore.migrateToOwnedPresetRoutes(library: &library, defaults: defaults))
        let migratedDefault = try XCTUnwrap(
            CapturePresetStore.flow(id: stalePreset.id, defaults: defaults)
        )
        XCTAssertEqual(migratedDefault.captureDestinationID, fallback.id)
        let orphanPresetID = "route-\(orphan.id.uuidString.lowercased())"
        XCTAssertNotNil(CapturePresetStore.flow(id: orphanPresetID, defaults: defaults))

        CapturePresetStore.saveFlows(staleSnapshot, defaults: defaults)

        XCTAssertEqual(
            CapturePresetStore.flow(id: stalePreset.id, defaults: defaults)?.captureDestinationID,
            fallback.id
        )
        XCTAssertEqual(
            CapturePresetStore.flow(id: orphanPresetID, defaults: defaults)?.captureDestinationID,
            orphan.id
        )

        let staleBeforeDeletion = CapturePresetStore.loadFlows(defaults: defaults)
        CapturePresetStore.retirePreset(
            id: orphanPresetID,
            ownedRouteID: orphan.id,
            defaults: defaults
        )
        CapturePresetStore.saveFlows(staleBeforeDeletion, defaults: defaults)
        XCTAssertNil(CapturePresetStore.flow(id: orphanPresetID, defaults: defaults))
    }

    func test_staleWriterCannotResurrectPresetBeforeOwnershipMigration() throws {
        let suiteName = "test.preset.pre-migration-retire.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let retainedDefault = CapturePresetStore.defaultFlow
        var deleted = CapturePresetStore.makeCustomFlow()
        deleted.id = "deleted-before-migration"
        let staleSnapshot = [retainedDefault, deleted]
        CapturePresetStore.saveFlows(staleSnapshot, defaults: defaults)

        CapturePresetStore.retirePreset(
            id: deleted.id,
            ownedRouteID: nil,
            defaults: defaults
        )
        CapturePresetStore.saveFlows(staleSnapshot, defaults: defaults)

        XCTAssertEqual(
            CapturePresetStore.loadFlows(defaults: defaults).map(\.id),
            [retainedDefault.id]
        )
    }

    func test_concurrentPresetRetirementsKeepEveryTombstone() throws {
        let suiteName = "test.preset.concurrent-retire.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            CapturePresetProfileStore.currentOwnedRouteMigrationVersion,
            forKey: CapturePresetProfileStore.ownedRouteMigrationVersionKey
        )
        let presets = (0..<8).map { index in
            CapturePreset(
                id: "retire-\(index)",
                name: "Retire \(index)",
                symbolName: "folder",
                isBuiltIn: false,
                kind: .custom,
                captureDestinationID: UUID()
            )
        }
        let retainedDefault = CapturePresetStore.defaultFlow
        CapturePresetStore.saveFlows([retainedDefault] + presets, defaults: defaults)

        DispatchQueue.concurrentPerform(iterations: presets.count) { index in
            CapturePresetStore.retirePreset(
                id: presets[index].id,
                ownedRouteID: presets[index].captureDestinationID,
                defaults: defaults
            )
        }
        CapturePresetStore.saveFlows([retainedDefault] + presets, defaults: defaults)

        XCTAssertEqual(
            CapturePresetStore.loadFlows(defaults: defaults).map(\.id),
            [retainedDefault.id]
        )
    }

    func test_ownedPresetRouteMigrationReplayUsesSameCloneIDsAfterInterruptedCommit() throws {
        let suiteName = "test.preset.replay-route.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sharedRoute = CaptureDestination(
            name: "Shared",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        var first = CapturePresetStore.defaultFlow
        first.captureDestinationID = sharedRoute.id
        var second = CapturePresetStore.makeCustomFlow()
        second.id = "second"
        second.captureDestinationID = sharedRoute.id
        second.capturePlacementOverride = .prepend
        let legacyPresets = [first, second]
        CapturePresetStore.saveFlows(legacyPresets, defaults: defaults)
        var library = CaptureLibraryEnvelope(
            destinations: [sharedRoute],
            defaultDestinationID: sharedRoute.id
        )

        XCTAssertTrue(CapturePresetStore.migrateToOwnedPresetRoutes(library: &library, defaults: defaults))
        let firstCloneIDs = Set(library.destinations.map(\.id))

        // Simulate the route file committing before App Group defaults were
        // published. Replaying must target the exact same deterministic IDs.
        CapturePresetStore.saveFlows(legacyPresets, defaults: defaults)
        defaults.removeObject(forKey: CapturePresetProfileStore.ownedRouteMigrationVersionKey)
        XCTAssertTrue(CapturePresetStore.migrateToOwnedPresetRoutes(library: &library, defaults: defaults))

        XCTAssertEqual(Set(library.destinations.map(\.id)), firstCloneIDs)
        let replayedSecond = try XCTUnwrap(
            CapturePresetStore.flow(id: second.id, defaults: defaults)
        )
        XCTAssertEqual(replayedSecond.capturePlacementOverride, nil)
        XCTAssertEqual(
            library.destinations.first(where: { $0.id == replayedSecond.captureDestinationID })?.placement,
            .prepend
        )
    }

    func test_ownedPresetRouteMigrationPromotesOrphanButNotRetiredRoute() throws {
        let suiteName = "test.preset.orphan-route.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let owned = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        let orphan = CaptureDestination(
            name: "Ideas",
            rootBookmark: Data([2]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Ideas.md")
        )
        let retired = CaptureDestination(
            name: "Old",
            rootBookmark: Data([3]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Old.md")
        )
        var preset = CapturePresetStore.defaultFlow
        preset.captureDestinationID = owned.id
        CapturePresetStore.saveFlows([preset], defaults: defaults)
        CapturePresetStore.retireOwnedRoute(retired.id, defaults: defaults)
        var library = CaptureLibraryEnvelope(
            destinations: [owned, orphan, retired],
            defaultDestinationID: owned.id
        )

        _ = CapturePresetStore.migrateToOwnedPresetRoutes(library: &library, defaults: defaults)
        let migrated = CapturePresetStore.loadFlows(defaults: defaults)

        XCTAssertNotNil(migrated.first(where: { $0.id == "route-\(orphan.id.uuidString.lowercased())" }))
        XCTAssertNil(migrated.first(where: { $0.captureDestinationID == retired.id }))
        XCTAssertTrue(library.destinations.contains(where: { $0.id == retired.id }))
    }

    func test_routeLibraryRetainsRetiredRouteAfterQueuedRequestCompletes() async throws {
        let suiteName = "test.preset.retired-route-purge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturePresetRetired-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let route = CaptureDestination(
            name: "Deleted Preset",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        let store = CaptureLibraryStore(fileURL: root.appendingPathComponent(CaptureLibraryStore.defaultFilename))
        try await store.save(CaptureLibraryEnvelope(destinations: [route], defaultDestinationID: route.id))
        CapturePresetStore.retireOwnedRoute(route.id, defaults: defaults)

        let inbox = CaptureInbox(rootDirectoryURL: root)
        let request = CaptureRequest(
            source: .app,
            destinationID: route.id,
            payloads: [.text("keep route until delivered")]
        )
        try await inbox.enqueue(request)

        var loaded = try await CapturePresetRouteLibrary.load(from: store, defaults: defaults)
        XCTAssertTrue(loaded.destinations.contains(where: { $0.id == route.id }))

        _ = try await inbox.claim(requestID: request.id)
        try await inbox.complete(requestID: request.id)
        loaded = try await CapturePresetRouteLibrary.load(from: store, defaults: defaults)
        XCTAssertTrue(loaded.destinations.contains(where: { $0.id == route.id }))
    }

    func test_completedMigrationLeavesNewPresetUnconfigured() throws {
        let suiteName = "test.preset.new-unconfigured.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let route = CaptureDestination(
            name: "Default",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        var defaultPreset = CapturePresetStore.defaultFlow
        defaultPreset.captureDestinationID = route.id
        CapturePresetStore.saveFlows([defaultPreset], defaults: defaults)
        var library = CaptureLibraryEnvelope(destinations: [route], defaultDestinationID: route.id)
        XCTAssertTrue(CapturePresetStore.migrateToOwnedPresetRoutes(library: &library, defaults: defaults))

        var presets = CapturePresetStore.loadFlows(defaults: defaults)
        var newPreset = CapturePresetStore.makeCustomFlow()
        newPreset.id = "new-after-migration"
        presets.append(newPreset)
        CapturePresetStore.saveFlows(presets, defaults: defaults)

        XCTAssertFalse(CapturePresetStore.migrateToOwnedPresetRoutes(library: &library, defaults: defaults))
        XCTAssertNil(CapturePresetStore.flow(id: newPreset.id, defaults: defaults)?.captureDestinationID)
    }

    func test_clearCaptureDestinationRemovesDeletedRouteFromEveryFlow() throws {
        let suiteName = "test.flow.clear-route.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deletedID = UUID()
        let retainedID = UUID()
        var deletedRoute = CapturePresetStore.defaultFlow
        deletedRoute.captureDestinationID = deletedID
        var retainedRoute = CapturePresetStore.makeCustomFlow()
        retainedRoute.captureDestinationID = retainedID
        CapturePresetStore.saveFlows([deletedRoute, retainedRoute], defaults: defaults)

        let cleared = CapturePresetStore.clearCaptureDestination(
            deletedID,
            defaults: defaults
        )
        let flows = CapturePresetStore.loadFlows(defaults: defaults)

        XCTAssertEqual(cleared, 1)
        XCTAssertNil(flows.first { $0.id == deletedRoute.id }?.captureDestinationID)
        XCTAssertEqual(flows.first { $0.id == retainedRoute.id }?.captureDestinationID, retainedID)
    }

    func test_clearCaptureEntryTemplateRemovesDeletedTemplateFromEveryFlow() throws {
        let suiteName = "test.flow.clear-template.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deletedID = UUID()
        var flow = CapturePresetStore.makeCustomFlow()
        flow.captureEntryTemplateID = deletedID
        CapturePresetStore.saveFlows([flow], defaults: defaults)

        let cleared = CapturePresetStore.clearCaptureEntryTemplate(deletedID, defaults: defaults)
        let loaded = CapturePresetStore.loadFlows(defaults: defaults)

        XCTAssertEqual(cleared, 1)
        XCTAssertNil(loaded.first(where: { $0.id == flow.id })?.captureEntryTemplateID)
    }

    func test_exportSettingsDecodeMissingAudioEmbedFieldsWithSafeDefaults() throws {
        let settings = try JSONDecoder().decode(CapturePresetExportSettings.self, from: Data("{}".utf8))

        XCTAssertFalse(settings.embedAudioInMarkdown)
        XCTAssertEqual(settings.audioEmbedPlacement, .bottom)
    }

    func test_loadFlows_removesDeprecatedBuiltInsAndPreservesCustomFlows() throws {
        let suiteName = "test.flow.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let custom = CapturePreset(
            id: "custom-test",
            name: "My Meeting Flow",
            symbolName: "person.2",
            isBuiltIn: false,
            kind: .custom,
            exportSettings: CapturePresetExportSettings(usesCustomExportSettings: false),
            postProcessingMode: .meetingNotes
        )
        let oldBuiltIns = [
            CapturePreset(
                id: "dream",
                name: "Dream Journal",
                symbolName: "moon.stars",
                isBuiltIn: true,
                kind: .dream
            ),
            CapturePreset(
                id: "todo",
                name: "Todo List",
                symbolName: "checklist",
                isBuiltIn: true,
                kind: .todo
            ),
            CapturePreset(
                id: "meeting",
                name: "Meeting / Call",
                symbolName: "person.2.wave.2",
                isBuiltIn: true,
                kind: .meeting
            ),
        ]
        let oldDefault = CapturePreset(
            id: CapturePresetStore.generalId,
            name: "General Note",
            symbolName: "text.alignleft",
            isBuiltIn: true,
            kind: .general
        )
        let stored = [oldDefault, custom] + oldBuiltIns
        defaults.set(try JSONEncoder().encode(stored), forKey: CapturePresetStore.flowsKey)

        let loaded = CapturePresetStore.loadFlows(defaults: defaults)

        XCTAssertEqual(loaded.map(\.id).sorted(), [CapturePresetStore.generalId, custom.id].sorted())
        XCTAssertTrue(loaded.contains { $0.id == CapturePresetStore.generalId && $0.displayName == "Default" && $0.symbolName == CapturePresetStore.defaultSymbolName })
        XCTAssertTrue(loaded.contains { $0.id == custom.id && $0.postProcessingMode == .meetingNotes })
        XCTAssertTrue(loaded.allSatisfy { $0.exportSettings.usesCustomExportSettings })
        XCTAssertFalse(loaded.contains { ["dream", "todo", "meeting"].contains($0.id) })
    }

    func test_loadFlows_migratesLegacyGlobalFileExportSettingsToPerFlowSettings() throws {
        let suiteName = "test.flow.export-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxboardLegacyFlowExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        defaults.set(true, forKey: AppConstants.fileExportEnabledKey)
        defaults.set(ExportFileFormat.yaml.rawValue, forKey: AppConstants.fileExportFormatKey)
        defaults.set(ExportFileMode.append.rawValue, forKey: AppConstants.fileExportModeKey)
        defaults.set("Legacy Daily", forKey: AppConstants.fileExportAppendFileNameKey)
        defaults.set([ExportYAMLProperty.text.rawValue], forKey: AppConstants.fileExportYAMLPropertiesKey)
        defaults.set(try tempFolder.bookmarkData(), forKey: AppConstants.fileExportBookmarkKey)

        let custom = CapturePreset(
            id: "custom-legacy",
            name: "Legacy Export Flow",
            symbolName: "folder",
            isBuiltIn: false,
            kind: .custom,
            exportSettings: CapturePresetExportSettings(usesCustomExportSettings: false)
        )
        defaults.set(try JSONEncoder().encode([custom]), forKey: CapturePresetStore.flowsKey)

        let loaded = CapturePresetStore.loadFlows(defaults: defaults)
        let migrated = try XCTUnwrap(loaded.first { $0.id == custom.id })

        XCTAssertTrue(migrated.exportSettings.usesCustomExportSettings)
        XCTAssertTrue(migrated.exportSettings.exportEnabled)
        XCTAssertEqual(migrated.exportSettings.format, .yaml)
        XCTAssertEqual(migrated.exportSettings.mode, .append)
        XCTAssertEqual(migrated.exportSettings.appendFileName, "Legacy Daily")
        XCTAssertEqual(migrated.exportSettings.yamlProperties, [.text])
        XCTAssertEqual(migrated.exportSettings.folderName, tempFolder.lastPathComponent)
        XCTAssertNotNil(migrated.exportSettings.folderBookmark)
    }

    func test_loadFlows_appliesLegacyGlobalExportSettingsWhenNoFlowsStored() throws {
        let suiteName = "test.flow.default-export-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxboardDefaultLegacyExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        defaults.set(true, forKey: AppConstants.fileExportEnabledKey)
        defaults.set(ExportFileFormat.md.rawValue, forKey: AppConstants.fileExportFormatKey)
        defaults.set(try tempFolder.bookmarkData(), forKey: AppConstants.fileExportBookmarkKey)

        let loaded = CapturePresetStore.loadFlows(defaults: defaults)
        let defaultFlow = try XCTUnwrap(loaded.first { $0.id == CapturePresetStore.generalId })

        XCTAssertTrue(defaultFlow.exportSettings.usesCustomExportSettings)
        XCTAssertTrue(defaultFlow.exportSettings.exportEnabled)
        XCTAssertEqual(defaultFlow.exportSettings.format, .md)
        XCTAssertEqual(defaultFlow.exportSettings.folderName, tempFolder.lastPathComponent)
        XCTAssertNotNil(defaultFlow.exportSettings.folderBookmark)
    }

    func test_todoFlowFormatter_outputsMarkdownCheckboxes() {
        var flow = CapturePresetStore.makeCustomFlow()
        flow.staticFrontmatter = ["type": "todo", "category": "task", "tags": "[todo]"]
        flow.postProcessingMode = .todoList
        let transcript = Transcript(
            text: "I need to buy milk. Then email Sam about the launch.",
            duration: 4,
            modelUsed: "base",
            language: "en"
        )

        let formatted = TranscriptFlowFormatter.apply(flow: flow, to: transcript)

        XCTAssertTrue(formatted.cleanedText?.contains("- [ ] Buy milk") == true)
        XCTAssertTrue(formatted.cleanedText?.contains("- [ ] Email Sam about the launch") == true)
        XCTAssertEqual(formatted.category, "task")
        XCTAssertTrue(formatted.tags?.contains("todo") == true)
    }

    func test_todoFlowFormatter_preservesDiarizedSpeakerLabels() {
        let formatted = TranscriptFlowFormatter.formatTodoListPreservingSpeakerLabels("""
        Speaker 1:
        Send the notes. Schedule the follow-up.

        Speaker 2:
        Email the recording.
        """)

        XCTAssertTrue(formatted.contains("Speaker 1:\n- [ ] Send the notes"))
        XCTAssertTrue(formatted.contains("- [ ] Schedule the follow-up"))
        XCTAssertTrue(formatted.contains("Speaker 2:\n- [ ] Email the recording"))
        XCTAssertFalse(formatted.contains("- [ ] Speaker 1"))
    }

    func test_todoFlowFormatter_convertsPlainBulletsToMarkdownCheckboxes() {
        let formatted = TranscriptFlowFormatter.formatTodoList("- Ensure Vox on device processing works with Apple Intelligence.")

        XCTAssertEqual(formatted, "- [ ] Ensure Vox on device processing works with Apple Intelligence.")
    }

    func test_recordingCommand_decodesLegacyPayloadWithoutFlowId() throws {
        let json = """
        {"requestId":"abc","action":"startSegment","modelId":"ggml-base","language":"en"}
        """.data(using: .utf8)!

        let command = try JSONDecoder().decode(RecordingCommand.self, from: json)

        XCTAssertEqual(command.requestId, "abc")
        XCTAssertNil(command.flowId)
    }

    func test_flowCustomExport_writesFrontmatterAndUsesFlowFolder() throws {
        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxboardFlowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let suiteName = "test.flow.export.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(false, forKey: AppConstants.fileExportEnabledKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var flow = CapturePresetStore.makeCustomFlow()
        flow.staticFrontmatter = ["type": "dream", "category": "journal", "tags": "[dream]"]
        flow.exportSettings.usesCustomExportSettings = true
        flow.exportSettings.exportEnabled = true
        flow.exportSettings.format = .md
        flow.exportSettings.mode = .newFile
        flow.exportSettings.folderBookmark = try tempFolder.bookmarkData()
        flow.staticFrontmatter["mood"] = "strange"

        let transcript = TranscriptFlowFormatter.apply(
            flow: flow,
            to: Transcript(text: "I was flying over a city", duration: 3, modelUsed: "base", language: "en")
        )

        let url = TranscriptFileExporter.exportIfEnabled(transcript, flow: flow, defaults: defaults)

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.deletingLastPathComponent().resolvingSymlinksInPath(), tempFolder.resolvingSymlinksInPath())
        let content = try String(contentsOf: XCTUnwrap(url), encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("---\n"))
        XCTAssertTrue(content.contains("mood: \"strange\""))
        XCTAssertTrue(content.contains("tags: [\"dream\"]"))
        XCTAssertTrue(content.contains("I was flying over a city"))
    }

    func test_loadMigratesLegacyVoiceNoteTypeToModalityNeutralCapture() throws {
        let suiteName = "test.flow.voice-type.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var flow = CapturePresetStore.makeCustomFlow()
        flow.staticFrontmatter = ["type": "voice-note", "project": "vox"]
        defaults.set(try JSONEncoder().encode([flow]), forKey: CapturePresetStore.flowsKey)

        let loaded = CapturePresetStore.loadFlows(defaults: defaults)
        let migrated = try XCTUnwrap(loaded.first(where: { $0.id == flow.id }))

        XCTAssertEqual(migrated.staticFrontmatter["type"], "capture")
        XCTAssertEqual(migrated.staticFrontmatter["project"], "vox")
        XCTAssertEqual(CapturePresetStore.loadFlows(defaults: defaults), loaded)
    }

    func test_legacyCapturePresetFixture_decodesWithoutCaptureSchema() throws {
        let fixture = """
        {
          "id": "custom-legacy-fixture",
          "name": "Legacy Fixture",
          "symbolName": "waveform",
          "isEnabled": true,
          "isBuiltIn": false,
          "kind": "custom",
          "exportSettings": {
            "usesCustomExportSettings": true,
            "exportEnabled": true,
            "format": "md",
            "mode": "append",
            "folderName": "Notes",
            "audioFolderName": "",
            "newFileNameTemplate": "vox-{timestamp}",
            "appendFileName": "Inbox",
            "markdownTemplateEnabled": false,
            "markdownTemplateName": "",
            "mdObsidianEnabled": true,
            "yamlUsesMarkdownExtension": false,
            "yamlProperties": ["text"],
            "embedAudioInMarkdown": false,
            "audioEmbedPlacement": "bottom"
          },
          "staticFrontmatter": {"type":"voice-note"},
          "postProcessingMode": "clean",
          "customPostProcessingInstruction": "",
          "audioSaveMode": "off",
          "attachmentsFolderName": "attachments"
        }
        """.data(using: .utf8)!

        let flow = try JSONDecoder().decode(CapturePreset.self, from: fixture)
        let encodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(flow)) as? [String: Any]
        )

        XCTAssertEqual(flow.id, "custom-legacy-fixture")
        XCTAssertEqual(flow.exportSettings.mode, .append)
        XCTAssertFalse(flow.captureProcessingEnabled)
        XCTAssertNil(encodedObject["captureDestinationID"])
        XCTAssertNil(encodedObject["captureSchema"])
    }

    #if canImport(AVFoundation)
    func test_audioDestinationURL_usesFlowAudioFolderOverride() {
        let transcriptURL = URL(fileURLWithPath: "/tmp/Notes/meeting.md")
        let audioFolder = URL(fileURLWithPath: "/tmp/Audio Clips")
        var flow = CapturePresetStore.makeCustomFlow()
        flow.audioSaveMode = .attachmentsFolder
        flow.attachmentsFolderName = "nested-attachments"

        let destination = AudioAttachmentExporter.audioDestinationURL(
            for: transcriptURL,
            flow: flow,
            preferredExtension: "m4a",
            audioFolderOverride: audioFolder
        )

        XCTAssertEqual(destination.path, "/tmp/Audio Clips/meeting.m4a")
    }

    func test_audioDestinationURL_ignoresAudioFolderOverrideWhenAlongsideTranscript() {
        let transcriptURL = URL(fileURLWithPath: "/tmp/Notes/meeting.md")
        let audioFolder = URL(fileURLWithPath: "/tmp/Audio Clips")
        var flow = CapturePresetStore.makeCustomFlow()
        flow.audioSaveMode = .alongsideTranscript

        let destination = AudioAttachmentExporter.audioDestinationURL(
            for: transcriptURL,
            flow: flow,
            preferredExtension: "m4a",
            audioFolderOverride: audioFolder
        )

        XCTAssertEqual(destination.path, "/tmp/Notes/meeting.m4a")
    }

    func test_exportAudioIfNeeded_alongsideTranscriptWritesAudioNextToNote() async throws {
        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxboardAudioExportTests-\(UUID().uuidString)")
        let notesFolder = tempFolder.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let sourceAudioURL = tempFolder.appendingPathComponent("recording.wav")
        try Data("not-a-real-wav".utf8).write(to: sourceAudioURL)
        let transcriptURL = notesFolder.appendingPathComponent("meeting.md")
        try "# Meeting".write(to: transcriptURL, atomically: true, encoding: .utf8)

        var flow = CapturePresetStore.makeCustomFlow()
        flow.audioSaveMode = .alongsideTranscript

        let audioURL = try await AudioAttachmentExporter.exportAudioIfNeeded(
            sourceAudioURL: sourceAudioURL,
            transcriptFileURL: transcriptURL,
            flow: flow,
            transcriptFolderScopeURL: notesFolder
        )

        let savedAudioURL = try XCTUnwrap(audioURL)
        XCTAssertEqual(
            savedAudioURL.deletingLastPathComponent().resolvingSymlinksInPath(),
            notesFolder.resolvingSymlinksInPath()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedAudioURL.path))
    }
    #endif
}
