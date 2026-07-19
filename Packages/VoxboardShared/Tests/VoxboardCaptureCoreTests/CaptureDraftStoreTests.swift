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

        async let saveFirst: Void = firstStore.save(first)
        async let saveSecond: Void = secondStore.save(second)
        _ = try await (saveFirst, saveSecond)

        let drafts = try await firstStore.loadAll()
        XCTAssertEqual(Set(drafts.map(\.id)), Set([first.id, second.id]))
    }

    func test_preparedRequestPersistsSeparatelyAndIsRemovedWithCompletedDraft() async throws {
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
