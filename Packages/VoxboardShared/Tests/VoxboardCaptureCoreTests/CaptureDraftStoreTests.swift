import XCTest
@testable import VoxboardCaptureCore

final class CaptureDraftStoreTests: XCTestCase {
    func test_draftRestoresTextDestinationAndPlacement() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let destinationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let draft = CaptureDraft(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            requestID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            text: "Durable thought",
            destinationID: destinationID,
            deliveryKind: .meteredVoiceTranscript,
            placementOverride: .prepend
        )

        try await store.save(draft)
        let restored = try await store.load(id: draft.id)

        XCTAssertEqual(restored, draft)
    }

    func test_draftRestoresOneOffNoteOverrideAndRebasesIt() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let draft = CaptureDraft(
            text: "One-off route",
            destinationID: UUID(),
            placementOverride: .append,
            relativeNotePathOverride: "Projects/Now.md"
        )

        try await store.save(draft)
        let loaded = try await store.load(id: draft.id)
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.relativeNotePathOverride, "Projects/Now.md")

        var edited = restored
        edited.text += "\nMore"
        let rebased = edited.rebased(afterSubmitting: restored)
        XCTAssertEqual(rebased.relativeNotePathOverride, "Projects/Now.md")
    }

    func test_legacyDraftWithoutOneOffNoteOverrideDecodes() throws {
        let id = UUID()
        let requestID = UUID()
        let destinationID = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "requestID": "\(requestID.uuidString)",
          "createdAt": -978307200,
          "updatedAt": -978307200,
          "text": "Legacy",
          "destinationID": "\(destinationID.uuidString)",
          "additionalPayloads": []
        }
        """

        let decoded = try JSONDecoder().decode(CaptureDraft.self, from: Data(json.utf8))

        XCTAssertNil(decoded.relativeNotePathOverride)
        XCTAssertNil(decoded.captureSource)
        XCTAssertEqual(decoded.text, "Legacy")
    }

    func test_draftPersistsCaptureProvenanceAndUsesItForRequestsAndRebases() throws {
        let draft = CaptureDraft(
            text: "Opened from a widget",
            destinationID: UUID(),
            captureSource: .widget
        )

        let decoded = try JSONDecoder().decode(
            CaptureDraft.self,
            from: JSONEncoder().encode(draft)
        )
        let request = try decoded.makeRequest(source: .app)
        let rebased = decoded.rebased(afterSubmitting: decoded)

        XCTAssertEqual(decoded.captureSource, .widget)
        XCTAssertEqual(request.source, .widget)
        XCTAssertEqual(rebased.captureSource, .widget)
    }

    func test_locationOutcomeIsJournaledWithoutOverwritingConcurrentDraftEdits() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        var draft = CaptureDraft(text: "Before", destinationID: UUID())
        try await store.save(draft)
        draft.text = "Edited while resolving"
        try await store.save(draft)
        let outcome = CaptureLocationOutcome.unavailable(
            .timeout,
            attemptedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let originProfile = CapturePresetProfile(
            id: "import-profile",
            name: "Import",
            symbolName: "waveform",
            locationPolicy: CapturePresetLocationPolicy(isEnabled: true, precision: .city)
        )

        let journaled = try await store.journalLocation(
            draftID: draft.id,
            requestID: draft.requestID,
            outcome: outcome,
            decisionOverride: .sendWithoutLocation,
            profileSnapshot: originProfile,
            captureSource: .fileImport
        )
        let laterEditedProfile = CapturePresetProfile(
            id: originProfile.id,
            name: "Edited later",
            symbolName: "pencil",
            locationPolicy: CapturePresetLocationPolicy(isEnabled: true, precision: .exact)
        )
        let request = try journaled.makeRequest(source: .app, voxProfile: laterEditedProfile)

        XCTAssertEqual(journaled.text, "Edited while resolving")
        XCTAssertEqual(request.locationOutcome, outcome)
        XCTAssertEqual(request.locationDecisionOverride, .sendWithoutLocation)
        XCTAssertEqual(request.source, .fileImport)
        XCTAssertEqual(request.voxProfile, originProfile)
    }

    func test_abandonedImportClearsOriginJournalWithoutOverwritingDraftEdits() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        var draft = CaptureDraft(text: "Before import", destinationID: UUID())
        try await store.save(draft)
        _ = try await store.journalLocation(
            draftID: draft.id,
            requestID: draft.requestID,
            outcome: .unavailable(.timeout, attemptedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            decisionOverride: nil,
            profileSnapshot: CapturePresetProfile(
                id: "import",
                name: "Import",
                symbolName: "waveform"
            ),
            captureSource: .fileImport
        )
        let loaded = try await store.load(id: draft.id)
        draft = try XCTUnwrap(loaded)
        draft.text = "Edited while import failed"
        try await store.save(draft)

        let cleared = try await store.clearLocationJournal(
            draftID: draft.id,
            requestID: draft.requestID,
            captureSource: .fileImport
        )

        XCTAssertEqual(cleared.text, "Edited while import failed")
        XCTAssertNil(cleared.captureSource)
        XCTAssertNil(cleared.locationOutcome)
        XCTAssertNil(cleared.locationDecisionOverride)
        XCTAssertNil(cleared.voxProfileSnapshot)
    }

    func test_staleImportCallbacksCannotRestoreOrClearANewerPresetJournal() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let draft = CaptureDraft(text: "Concurrent", voxID: "new-preset", destinationID: UUID())
        try await store.save(draft)
        let oldProfile = CapturePresetProfile(
            id: "old-preset",
            name: "Old",
            symbolName: "location"
        )

        do {
            _ = try await store.journalLocation(
                draftID: draft.id,
                requestID: draft.requestID,
                outcome: .unavailable(.timeout, attemptedAt: Date()),
                decisionOverride: nil,
                profileSnapshot: oldProfile,
                captureSource: .fileImport,
                expectedVoxID: oldProfile.id
            )
            XCTFail("Expected stale import journal to be rejected")
        } catch {
            // Expected: the draft now belongs to a different Preset.
        }

        let newProfile = CapturePresetProfile(
            id: "new-preset",
            name: "New",
            symbolName: "mappin"
        )
        _ = try await store.journalLocation(
            draftID: draft.id,
            requestID: draft.requestID,
            outcome: .unavailable(.permissionDenied, attemptedAt: Date()),
            decisionOverride: nil,
            profileSnapshot: newProfile,
            captureSource: .app,
            expectedVoxID: newProfile.id
        )
        let afterStaleClear = try await store.clearLocationJournal(
            draftID: draft.id,
            requestID: draft.requestID,
            captureSource: .fileImport,
            expectedProfileID: oldProfile.id
        )

        XCTAssertEqual(afterStaleClear.voxProfileSnapshot, newProfile)
        XCTAssertNotNil(afterStaleClear.locationOutcome)
        XCTAssertEqual(afterStaleClear.captureSource, .app)
    }

    func test_changingPresetClearsJournaledLocationAttempt() {
        var draft = CaptureDraft(
            text: "Retry",
            voxProfileSnapshot: CapturePresetProfile(
                id: "old-preset",
                name: "Old",
                symbolName: "location"
            ),
            locationOutcome: .unavailable(
                .permissionDenied,
                attemptedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            locationDecisionOverride: .sendWithoutLocation
        )

        draft.selectVox("another-preset")

        XCTAssertNil(draft.locationOutcome)
        XCTAssertNil(draft.locationDecisionOverride)
        XCTAssertNil(draft.voxProfileSnapshot)
    }

    func test_changingDraftDestinationClearsDestinationScopedNoteOverride() {
        let first = UUID()
        let second = UUID()
        var draft = CaptureDraft(
            text: "Route safely",
            destinationID: first,
            relativeNotePathOverride: "Projects/First.md"
        )

        draft.selectDestination(first)
        XCTAssertEqual(draft.relativeNotePathOverride, "Projects/First.md")

        draft.selectDestination(second)
        XCTAssertEqual(draft.destinationID, second)
        XCTAssertNil(draft.relativeNotePathOverride)
    }

    func test_equivalentExplicitDestinationBecomesInheritedWithoutClearingOtherOverrides() {
        let destinationID = UUID()
        let templateID = UUID()
        var draft = CaptureDraft(
            destinationID: destinationID,
            placementOverride: .prepend,
            relativeNotePathOverride: "Projects/Now.md",
            entryTemplateID: templateID
        )

        XCTAssertTrue(draft.inheritDestinationIfEquivalent(to: destinationID))
        XCTAssertEqual(draft.destinationSelectionMode, .inherited)
        XCTAssertNil(draft.destinationID)
        XCTAssertEqual(draft.placementOverride, .prepend)
        XCTAssertEqual(draft.relativeNotePathOverride, "Projects/Now.md")
        XCTAssertEqual(draft.entryTemplateID, templateID)
    }

    func test_nonEquivalentExplicitDestinationRemainsExplicit() {
        let destinationID = UUID()
        var draft = CaptureDraft(destinationID: destinationID)

        XCTAssertFalse(draft.inheritDestinationIfEquivalent(to: UUID()))
        XCTAssertEqual(draft.destinationSelectionMode, .explicit)
        XCTAssertEqual(draft.destinationID, destinationID)
    }

    func test_makeRequestIncludesAttachmentWhenDraftTextIsEmpty() throws {
        let destinationID = UUID()
        let asset = try CaptureAssetReference(
            relativePath: "document.pdf",
            originalFilename: "document.pdf",
            contentTypeIdentifier: "com.adobe.pdf"
        )
        let draft = CaptureDraft(
            destinationID: destinationID,
            additionalPayloads: [.file(asset)]
        )

        let request = try draft.makeRequest(source: .app)

        XCTAssertTrue(draft.hasCaptureContent)
        XCTAssertEqual(request.payloads, [.file(asset)])
    }

    func test_makeRequestPreservesMarkdownIndentationAndHardBreakSpaces() throws {
        let destinationID = UUID()
        let draft = CaptureDraft(
            text: "    indented code\nline with hard break  \n",
            destinationID: destinationID
        )

        let request = try draft.makeRequest(source: .app)

        XCTAssertEqual(
            request.payloads,
            [.text("    indented code\nline with hard break  ")]
        )
    }

    func test_stalePersistedEmptyDraftStartsAtFirstSubstantiveSave() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let allocatedAt = Date(timeIntervalSince1970: 100)
        let startedAt = Date(timeIntervalSince1970: 500)
        var draft = CaptureDraft(
            createdAt: allocatedAt,
            updatedAt: allocatedAt,
            text: "   \n",
            destinationID: UUID()
        )

        try await store.save(draft, now: allocatedAt)
        let emptyRestored = try await store.load(id: draft.id)
        XCTAssertNil(emptyRestored?.captureStartedAt)

        draft.text = "A later thought"
        try await store.save(draft, now: startedAt)
        let loaded = try await store.load(id: draft.id)
        let restored = try XCTUnwrap(loaded)
        let request = try restored.makeRequest(source: .app)

        XCTAssertEqual(restored.createdAt, allocatedAt)
        XCTAssertEqual(restored.captureStartedAt, startedAt)
        XCTAssertEqual(request.createdAt, startedAt)
    }

    func test_repeatedStaleSavesPreserveFirstPersistedCaptureStart() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let allocatedAt = Date(timeIntervalSince1970: 100)
        let firstStartedAt = Date(timeIntervalSince1970: 500)
        let laterSaveAt = Date(timeIntervalSince1970: 900)
        let emptySnapshot = CaptureDraft(
            createdAt: allocatedAt,
            updatedAt: allocatedAt,
            destinationID: UUID()
        )
        try await store.save(emptySnapshot, now: allocatedAt)

        var firstContentSnapshot = emptySnapshot
        firstContentSnapshot.text = "First durable content"
        let firstSaved = try await store.save(firstContentSnapshot, now: firstStartedAt)

        var staleContentSnapshot = emptySnapshot
        staleContentSnapshot.text = "A concurrent stale snapshot"
        let staleSaved = try await store.save(staleContentSnapshot, now: laterSaveAt)
        let loaded = try await store.load(id: emptySnapshot.id)
        let restored = try XCTUnwrap(loaded)

        XCTAssertEqual(firstSaved.captureStartedAt, firstStartedAt)
        XCTAssertEqual(staleSaved.captureStartedAt, firstStartedAt)
        XCTAssertEqual(restored.captureStartedAt, firstStartedAt)
        XCTAssertEqual(try restored.makeRequest(source: .app).createdAt, firstStartedAt)
    }

    func test_staleEmptyDraftStartsWhenFirstDurableContentIsAPayload() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let startedAt = Date(timeIntervalSince1970: 600)
        var draft = CaptureDraft(createdAt: Date(timeIntervalSince1970: 100), destinationID: UUID())
        let asset = try CaptureAssetReference(
            relativePath: "photo.jpg",
            originalFilename: "photo.jpg",
            contentTypeIdentifier: "public.jpeg"
        )
        try await store.save(draft, now: Date(timeIntervalSince1970: 100))

        draft.additionalPayloads.append(.image(asset, altText: nil))
        try await store.save(draft, now: startedAt)
        let loaded = try await store.load(id: draft.id)
        let restored = try XCTUnwrap(loaded)

        XCTAssertEqual(restored.captureStartedAt, startedAt)
        XCTAssertEqual(try restored.makeRequest(source: .app).createdAt, startedAt)
    }

    func test_emptyDraftStartsAcrossColdStoreRestorationAndKeepsRequestIdentity() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let allocatedAt = Date(timeIntervalSince1970: 100)
        let startedAt = Date(timeIntervalSince1970: 900)
        let draft = CaptureDraft(
            requestID: UUID(),
            createdAt: allocatedAt,
            updatedAt: allocatedAt,
            destinationID: UUID()
        )
        let firstStore = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        try await firstStore.save(draft, now: allocatedAt)

        let secondStore = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let secondLoaded = try await secondStore.load(id: draft.id)
        var restored = try XCTUnwrap(secondLoaded)
        restored.text = "Started after relaunch"
        try await secondStore.save(restored, now: startedAt)

        let thirdStore = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let thirdLoaded = try await thirdStore.load(id: draft.id)
        let coldRestored = try XCTUnwrap(thirdLoaded)
        XCTAssertEqual(coldRestored.captureStartedAt, startedAt)
        XCTAssertEqual(coldRestored.requestID, draft.requestID)
        XCTAssertEqual(try coldRestored.makeRequest(source: .widget).createdAt, startedAt)
    }

    func test_appAndWidgetProvenanceDoesNotStartEmptyDraftOrRefreshContentfulDraft() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let startedAt = Date(timeIntervalSince1970: 700)
        let later = Date(timeIntervalSince1970: 1_200)

        for source in [CaptureSource.app, .widget] {
            var draft = CaptureDraft(destinationID: UUID(), captureSource: source)
            try await store.save(draft, now: Date(timeIntervalSince1970: 100))
            let emptyLoaded = try await store.load(id: draft.id)
            XCTAssertNil(emptyLoaded?.captureStartedAt)

            draft.text = "From \(source.rawValue)"
            try await store.save(draft, now: startedAt)
            let contentLoaded = try await store.load(id: draft.id)
            var restored = try XCTUnwrap(contentLoaded)
            restored.captureSource = source == .app ? .widget : .app
            try await store.save(restored, now: later)
            let provenanceLoaded = try await store.load(id: draft.id)
            let request = try XCTUnwrap(provenanceLoaded).makeRequest(source: .deepLink)

            XCTAssertEqual(request.createdAt, startedAt)
            XCTAssertEqual(request.source, source == .app ? .widget : .app)
        }
    }

    func test_legacyNonemptyDraftRetainsCreatedAtAsEffectiveCaptureTime() throws {
        let createdAt = Date(timeIntervalSince1970: 321)
        let legacyData = try legacyEncodedDraftData(
            CaptureDraft(createdAt: createdAt, updatedAt: createdAt, text: "Legacy", destinationID: UUID())
        )

        let decoded = try JSONDecoder().decode(CaptureDraft.self, from: legacyData)

        XCTAssertEqual(decoded.captureStartedAt, createdAt)
        XCTAssertEqual(try decoded.makeRequest(source: .app).createdAt, createdAt)
    }

    func test_legacyEmptyDraftRemainsStartable() throws {
        let createdAt = Date(timeIntervalSince1970: 321)
        let startedAt = Date(timeIntervalSince1970: 654)
        let legacyData = try legacyEncodedDraftData(
            CaptureDraft(createdAt: createdAt, updatedAt: createdAt, text: " \n", destinationID: UUID())
        )
        var decoded = try JSONDecoder().decode(CaptureDraft.self, from: legacyData)

        XCTAssertNil(decoded.captureStartedAt)
        decoded.text = "New content"
        XCTAssertTrue(decoded.beginCaptureIfNeeded(at: startedAt))
        XCTAssertEqual(decoded.captureStartedAt, startedAt)
        XCTAssertFalse(decoded.beginCaptureIfNeeded(at: Date(timeIntervalSince1970: 999)))
        XCTAssertEqual(try decoded.makeRequest(source: .app).createdAt, startedAt)
    }

    func test_failedDeliveryAndPreparedRetryKeepCaptureTimestampStable() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let destinationID = UUID()
        let startedAt = Date(timeIntervalSince1970: 800)
        var draft = CaptureDraft(createdAt: Date(timeIntervalSince1970: 100), destinationID: destinationID)
        draft.text = "Retry me"
        try await store.save(draft, now: startedAt)
        let loaded = try await store.load(id: draft.id)
        let persisted = try XCTUnwrap(loaded)
        let prepared = try persisted.makeRequest(source: .app)
        try await store.savePreparedRequest(prepared, draftID: draft.id)

        do {
            _ = try await store.submit(draftID: draft.id) { submitted in
                XCTAssertEqual(submitted.captureStartedAt, startedAt)
                throw DraftTestError.expected
            }
            XCTFail("Expected submit failure")
        } catch DraftTestError.expected {}

        let retryAt = Date(timeIntervalSince1970: 1_500)
        let retryLoaded = try await store.load(id: draft.id)
        let retryDraft = try XCTUnwrap(retryLoaded)
        try await store.save(retryDraft, now: retryAt)
        let retryRequest = try retryDraft.makeRequest(source: .widget)
        let preparedLoaded = try await store.loadPreparedRequest(draftID: draft.id)
        let restoredPrepared = try XCTUnwrap(preparedLoaded)

        XCTAssertEqual(retryRequest.createdAt, startedAt)
        XCTAssertEqual(restoredPrepared.createdAt, startedAt)
        XCTAssertEqual(retryRequest.id, prepared.id)
    }

    func test_draftSaveIsAtomicAndLeavesNoTemporaryFiles() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        var draft = CaptureDraft(text: "Version 1")

        try await store.save(draft)
        draft.text = String(repeating: "Version 2 ", count: 10_000)
        try await store.save(draft)

        let restored = try await store.load(id: draft.id)
        XCTAssertEqual(restored?.text, draft.text)
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("drafts"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.map(\.pathExtension), ["json"])
    }

    func test_successfulCaptureDeletesDraftAndStagingDirectory() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let draft = CaptureDraft(text: "Captured")
        try await store.save(draft)
        let staging = await store.stagingDirectoryURL(for: draft.id)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("asset".utf8).write(to: staging.appendingPathComponent("photo.jpg"))

        try await store.complete(draftID: draft.id)

        let restored = try await store.load(id: draft.id)
        XCTAssertNil(restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func test_failedCaptureKeepsDraftForRetry() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let draft = CaptureDraft(text: "Retry me")
        try await store.save(draft)

        do {
            _ = try await store.submit(draftID: draft.id) { _ in
                throw DraftTestError.expected
            }
            XCTFail("Expected submit failure")
        } catch DraftTestError.expected {
            // Expected.
        }

        let restored = try await store.load(id: draft.id)
        XCTAssertEqual(restored, draft)
    }

    func test_rebasedDraftKeepsOnlyEditsAddedDuringSuccessfulSubmission() throws {
        let destinationID = UUID()
        let submitted = CaptureDraft(
            id: UUID(),
            requestID: UUID(),
            text: "Original",
            destinationID: destinationID,
            deliveryKind: .meteredVoiceTranscript,
            additionalPayloads: [.url(URL(string: "https://example.com/first")!, title: nil)]
        )
        var edited = submitted
        edited.text = "Original\n\nAdded while sending"
        edited.additionalPayloads.append(
            .url(URL(string: "https://example.com/second")!, title: nil)
        )

        let rebased = edited.rebased(afterSubmitting: submitted, now: Date(timeIntervalSince1970: 500))

        XCTAssertEqual(rebased.id, submitted.id)
        XCTAssertNotEqual(rebased.requestID, submitted.requestID)
        XCTAssertEqual(rebased.text, "Added while sending")
        XCTAssertEqual(
            rebased.additionalPayloads,
            [.url(URL(string: "https://example.com/second")!, title: nil)]
        )
        XCTAssertEqual(rebased.createdAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(rebased.captureStartedAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(rebased.deliveryKind, .standard)
    }

    func test_rebasedDraftPreservesRewrittenTextRatherThanLosingIt() {
        let submitted = CaptureDraft(text: "Original")
        var edited = submitted
        edited.text = "Rewritten"

        let rebased = edited.rebased(afterSubmitting: submitted)

        XCTAssertEqual(rebased.text, "Rewritten")
    }

    func test_corruptDraftIsQuarantinedWithoutBlockingValidDrafts() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let valid = CaptureDraft(text: "Keep me")
        try await store.save(valid)
        let corruptID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let corruptURL = root
            .appendingPathComponent("drafts")
            .appendingPathComponent(corruptID.uuidString.lowercased())
            .appendingPathExtension("json")
        try Data("not-json".utf8).write(to: corruptURL)

        let drafts = try await store.loadAll()

        XCTAssertEqual(drafts, [valid])
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root
                .appendingPathComponent("drafts-corrupt")
                .appendingPathComponent(corruptURL.lastPathComponent)
                .path
        ))
    }

    func test_twoDraftWritersDoNotLoseIndependentDrafts() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let secondStore = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let first = CaptureDraft(text: "First")
        let second = CaptureDraft(text: "Second")

        async let saveFirst: CaptureDraft = firstStore.save(first)
        async let saveSecond: CaptureDraft = secondStore.save(second)
        _ = try await (saveFirst, saveSecond)

        let drafts = try await firstStore.loadAll()
        XCTAssertEqual(Set(drafts.map(\.id)), Set([first.id, second.id]))
    }

    func test_preparedRequestReusesExactOriginLocationAndIsRemovedWithCompletedDraft() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureDraftStore(
            rootDirectoryURL: root,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let draft = CaptureDraft(text: "Raw", destinationID: UUID())
        let prepared = CaptureRequest(
            id: draft.requestID,
            source: .app,
            destinationID: draft.destinationID!,
            payloads: [.text("Processed once")],
            voxProcessingState: .applied,
            locationOutcome: .available(CaptureLocationSnapshot(
                latitude: 12.345678,
                longitude: -87.654321,
                horizontalAccuracy: 7.5,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                source: .app,
                precision: .exact,
                label: CaptureLocationLabel(place: "Origin")
            )),
            originDraftUpdatedAt: draft.updatedAt
        )
        try await store.save(draft)
        try await store.savePreparedRequest(prepared, draftID: draft.id)

        let loadedPrepared = try await store.loadPreparedRequest(draftID: draft.id)
        XCTAssertEqual(loadedPrepared, prepared)

        try await store.complete(draftID: draft.id)
        let removedPrepared = try await store.loadPreparedRequest(draftID: draft.id)
        XCTAssertNil(removedPrepared)
    }

    func test_preparedReuseIgnoresLaterLiveEditsToSamePresetIdentity() throws {
        let destinationID = UUID()
        let draft = CaptureDraft(text: "Origin", destinationID: destinationID)
        let originalProfile = CapturePresetProfile(
            id: "journal",
            name: "Original",
            symbolName: "book",
            locationPolicy: CapturePresetLocationPolicy(isEnabled: true)
        )
        var prepared = try draft.makeRequest(
            source: .app,
            resolvedDestinationID: destinationID,
            voxProfile: originalProfile
        )
        prepared.voxProcessingState = .applied
        prepared.locationOutcome = .unavailable(.timeout, attemptedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let editedProfile = CapturePresetProfile(
            id: "journal",
            name: "Edited Later",
            symbolName: "pencil",
            locationPolicy: CapturePresetLocationPolicy(isEnabled: true, precision: .city)
        )

        XCTAssertTrue(CapturePreparedRequestReuse.matches(
            prepared,
            draft: draft,
            destinationID: destinationID,
            presetID: editedProfile.id
        ))
        XCTAssertEqual(prepared.voxProfile, originalProfile)
        XCTAssertFalse(CapturePreparedRequestReuse.matches(
            prepared,
            draft: draft,
            destinationID: destinationID,
            presetID: "different-preset"
        ))
    }

    private func legacyEncodedDraftData(_ draft: CaptureDraft) throws -> Data {
        let encoded = try JSONEncoder().encode(draft)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "captureStartedAt")
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureDraftStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum DraftTestError: Error {
    case expected
}
