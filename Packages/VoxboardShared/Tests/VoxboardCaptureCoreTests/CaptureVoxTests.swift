import XCTest
@testable import VoxboardCaptureCore

final class CaptureVoxTests: XCTestCase {
    func test_lightweightProfileDecodesExistingRecordingFlowPayload() throws {
        let destinationID = UUID()
        let json = """
        {
          "id":"meeting",
          "name":"Meeting",
          "symbolName":"person.2",
          "isEnabled":true,
          "isBuiltIn":false,
          "kind":"custom",
          "exportSettings":{"exportEnabled":true},
          "staticFrontmatter":{"type":"meeting"},
          "postProcessingMode":"meetingNotes",
          "customPostProcessingInstruction":"",
          "captureProcessingEnabled":true,
          "capturePrompt":"Add the agenda, recording, or whiteboard.",
          "captureDestinationID":"\(destinationID.uuidString)"
        }
        """

        let profile = try JSONDecoder().decode(
            CaptureVoxProfile.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(profile.id, "meeting")
        XCTAssertEqual(profile.postProcessingMode, .meetingNotes)
        XCTAssertTrue(profile.captureProcessingEnabled)
        XCTAssertEqual(profile.captureDestinationID, destinationID)
        XCTAssertEqual(profile.staticFrontmatter, ["type": "meeting"])
    }

    func test_legacyProfileDefaultsCaptureProcessingOff() throws {
        let json = """
        {
          "id":"legacy",
          "name":"Legacy Voice",
          "symbolName":"waveform",
          "staticFrontmatter":{"type":"voice-note"},
          "postProcessingMode":"clean"
        }
        """

        let profile = try JSONDecoder().decode(
            CaptureVoxProfile.self,
            from: Data(json.utf8)
        )

        XCTAssertFalse(profile.captureProcessingEnabled)
        XCTAssertEqual(profile.capturePrompt, "")
        XCTAssertEqual(profile.metadataScope, .document)
    }

    func test_captureSelectionIsIndependentFromRecordingSelection() throws {
        let suite = "capture-vox-selection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = [
            CaptureVoxProfile(id: "recording", name: "Recording", symbolName: "mic"),
            CaptureVoxProfile(id: "capture", name: "Capture", symbolName: "square.and.pencil"),
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: CaptureVoxProfileStore.profilesKey)
        defaults.set("recording", forKey: CaptureVoxProfileStore.selectedProfileIDKey)

        CaptureVoxProfileStore.selectCaptureProfile(id: "capture", defaults: defaults)

        XCTAssertEqual(CaptureVoxProfileStore.selectedProfileID(defaults: defaults), "capture")
        XCTAssertEqual(defaults.string(forKey: CaptureVoxProfileStore.selectedProfileIDKey), "recording")
    }

    func test_routeResolverHonorsExplicitThenVoxThenLibraryPrecedence() {
        let explicit = CaptureDestination(
            name: "Explicit",
            rootBookmark: Data(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Explicit.md")
        )
        let voxRoute = CaptureDestination(
            name: "Vox",
            rootBookmark: Data(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Vox.md")
        )
        let libraryDefault = CaptureDestination(
            name: "Default",
            rootBookmark: Data(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Default.md")
        )
        let profile = CaptureVoxProfile(
            id: "journal",
            name: "Journal",
            symbolName: "book",
            captureDestinationID: voxRoute.id
        )
        let destinations = [explicit, voxRoute, libraryDefault]

        XCTAssertEqual(
            CaptureVoxRouteResolver.destinationID(
                selectionMode: .explicit,
                explicitDestinationID: explicit.id,
                profile: profile,
                destinations: destinations,
                libraryDefaultDestinationID: libraryDefault.id
            ),
            explicit.id
        )
        XCTAssertEqual(
            CaptureVoxRouteResolver.destinationID(
                selectionMode: .inherited,
                explicitDestinationID: explicit.id,
                profile: profile,
                destinations: destinations,
                libraryDefaultDestinationID: libraryDefault.id
            ),
            voxRoute.id
        )
        var profileWithoutRoute = profile
        profileWithoutRoute.captureDestinationID = UUID()
        XCTAssertEqual(
            CaptureVoxRouteResolver.destinationID(
                selectionMode: .inherited,
                explicitDestinationID: nil,
                profile: profileWithoutRoute,
                destinations: destinations,
                libraryDefaultDestinationID: libraryDefault.id
            ),
            libraryDefault.id
        )
    }

    func test_selectingVoxReturnsDraftToInheritedRoute() throws {
        let explicitDestination = UUID()
        var draft = CaptureDraft(
            text: "Keep me",
            destinationID: explicitDestination,
            placementOverride: .prepend,
            entryTemplateID: UUID()
        )

        draft.selectVox("journal")

        XCTAssertEqual(draft.voxID, "journal")
        XCTAssertEqual(draft.destinationSelectionMode, .inherited)
        XCTAssertNil(draft.destinationID)
        XCTAssertNil(draft.placementOverride)
        XCTAssertNil(draft.entryTemplateID)
        XCTAssertEqual(draft.text, "Keep me")
    }

    func test_legacyDraftWithDestinationDecodesAsExplicit() throws {
        let id = UUID()
        let requestID = UUID()
        let destinationID = UUID()
        let now = Date()
        let date = ISO8601DateFormatter().string(from: now)
        let json = """
        {
          "id":"\(id.uuidString)",
          "requestID":"\(requestID.uuidString)",
          "createdAt":"\(date)",
          "updatedAt":"\(date)",
          "text":"Legacy",
          "destinationID":"\(destinationID.uuidString)",
          "additionalPayloads":[]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let draft = try decoder.decode(CaptureDraft.self, from: Data(json.utf8))

        XCTAssertEqual(draft.destinationSelectionMode, .explicit)
        XCTAssertEqual(draft.destinationID, destinationID)
        XCTAssertNil(draft.voxID)
    }

    func test_makeRequestSnapshotsVoxAndMarksProcessingPending() throws {
        let route = UUID()
        let profile = CaptureVoxProfile(
            id: "tasks",
            name: "Tasks",
            symbolName: "checklist",
            staticFrontmatter: ["type": "task"],
            postProcessingMode: .todoList,
            captureProcessingEnabled: true,
            captureDestinationID: route
        )
        let draft = CaptureDraft(text: "buy milk", voxID: profile.id)

        let request = try draft.makeRequest(
            source: .app,
            resolvedDestinationID: route,
            voxProfile: profile
        )

        XCTAssertEqual(request.destinationID, route)
        XCTAssertEqual(request.voxProfile, profile)
        XCTAssertEqual(request.frontmatter, ["type": "task"])
        XCTAssertEqual(request.voxProcessingState, .pending)
        XCTAssertEqual(request.originDraftUpdatedAt, draft.updatedAt)
    }

    func test_requestProcessorPreservesPayloadAssociationsAndAddsMetadata() async throws {
        let audio = try CaptureAssetReference(
            relativePath: "recording.m4a",
            originalFilename: "recording.m4a",
            contentTypeIdentifier: "public.audio"
        )
        let page = try CaptureAssetReference(
            relativePath: "page.jpg",
            originalFilename: "page.jpg",
            contentTypeIdentifier: "public.jpeg"
        )
        let profile = CaptureVoxProfile(
            id: "meeting",
            name: "Meeting",
            symbolName: "person.2",
            staticFrontmatter: ["project": "vox"],
            postProcessingMode: .meetingNotes,
            captureProcessingEnabled: true
        )
        let request = CaptureRequest(
            source: .app,
            destinationID: UUID(),
            payloads: [
                .text("typed"),
                .audio(audio, transcript: "spoken"),
                .scannedDocument(pages: [page], pdf: nil, extractedText: "scan"),
            ],
            frontmatter: profile.staticFrontmatter,
            voxProfile: profile,
            voxProcessingState: .pending
        )

        let processed = await CaptureVoxRequestProcessor(
            textProcessor: StubCaptureTextProcessor()
        ).process(request)

        XCTAssertEqual(processed.voxProcessingState, .applied)
        XCTAssertEqual(processed.frontmatter["project"], "vox")
        XCTAssertEqual(processed.frontmatter["title"], "Processed")
        XCTAssertEqual(processed.frontmatter["category"], "meeting")
        XCTAssertEqual(processed.frontmatter["tags"], "[local, capture]")
        guard case .text(let typed) = processed.payloads[0] else {
            return XCTFail("Expected text")
        }
        guard case .audio(let retainedAudio, let spoken) = processed.payloads[1] else {
            return XCTFail("Expected audio")
        }
        guard case .scannedDocument(let pages, _, let scan) = processed.payloads[2] else {
            return XCTFail("Expected scan")
        }
        XCTAssertEqual(typed, "PROCESSED: typed")
        XCTAssertEqual(retainedAudio, audio)
        XCTAssertEqual(spoken, "PROCESSED: spoken")
        XCTAssertEqual(pages, [page])
        XCTAssertEqual(scan, "PROCESSED: scan")
    }

    func test_processorFailureUsesDeterministicTodoFallback() async {
        let profile = CaptureVoxProfile(
            id: "tasks",
            name: "Tasks",
            symbolName: "checklist",
            postProcessingMode: .todoList,
            captureProcessingEnabled: true
        )
        let request = CaptureRequest(
            source: .shortcut,
            destinationID: UUID(),
            payloads: [.text("buy milk. email sam")],
            voxProfile: profile,
            voxProcessingState: .pending
        )

        let processed = await CaptureVoxRequestProcessor(
            textProcessor: FailingCaptureTextProcessor()
        ).process(request)

        guard case .text(let text) = processed.payloads[0] else {
            return XCTFail("Expected text")
        }
        XCTAssertEqual(text, "- [ ] Buy milk\n- [ ] Email sam")
        XCTAssertEqual(processed.voxProcessingState, .applied)
    }
}

private struct StubCaptureTextProcessor: CaptureVoxTextProcessing {
    func process(
        text: String,
        profile: CaptureVoxProfile
    ) async throws -> CaptureVoxTextProcessingResult {
        CaptureVoxTextProcessingResult(
            text: "PROCESSED: \(text)",
            title: "Processed",
            tags: ["local", "capture"],
            category: "meeting"
        )
    }
}

private struct FailingCaptureTextProcessor: CaptureVoxTextProcessing {
    struct Failure: Error {}

    func process(
        text: String,
        profile: CaptureVoxProfile
    ) async throws -> CaptureVoxTextProcessingResult {
        throw Failure()
    }
}
