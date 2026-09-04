import XCTest
@testable import VoxboardCaptureCore

final class CaptureVoxTests: XCTestCase {
    func test_lightweightProfileDecodesExistingCapturePresetPayload() throws {
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
            CapturePresetProfile.self,
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
            CapturePresetProfile.self,
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
            CapturePresetProfile(id: "recording", name: "Recording", symbolName: "mic"),
            CapturePresetProfile(id: "capture", name: "Capture", symbolName: "square.and.pencil"),
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: CapturePresetProfileStore.profilesKey)
        defaults.set("recording", forKey: CapturePresetProfileStore.selectedProfileIDKey)

        XCTAssertTrue(CapturePresetProfileStore.selectCaptureProfile(id: "capture", defaults: defaults))

        XCTAssertEqual(CapturePresetProfileStore.selectedProfileID(defaults: defaults), "capture")
        XCTAssertEqual(defaults.string(forKey: CapturePresetProfileStore.selectedProfileIDKey), "recording")
    }

    func test_captureSelectionRejectsUnknownAndDisabledProfiles() throws {
        let suite = "capture-vox-selection-validation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = [
            CapturePresetProfile(id: "enabled", name: "Enabled", symbolName: "mic"),
            CapturePresetProfile(
                id: "disabled",
                name: "Disabled",
                symbolName: "nosign",
                isEnabled: false
            ),
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: CapturePresetProfileStore.profilesKey)
        XCTAssertTrue(CapturePresetProfileStore.selectCaptureProfile(id: "enabled", defaults: defaults))

        XCTAssertFalse(CapturePresetProfileStore.selectCaptureProfile(id: "disabled", defaults: defaults))
        XCTAssertFalse(CapturePresetProfileStore.selectCaptureProfile(id: "missing", defaults: defaults))
        XCTAssertEqual(CapturePresetProfileStore.selectedProfileID(defaults: defaults), "enabled")
    }

    func test_routeResolverHonorsExplicitThenPresetThenLegacyLibraryPrecedence() {
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
        let profile = CapturePresetProfile(
            id: "journal",
            name: "Journal",
            symbolName: "book",
            captureDestinationID: voxRoute.id
        )
        let destinations = [explicit, voxRoute, libraryDefault]

        XCTAssertEqual(
            CapturePresetRouteResolver.destinationID(
                selectionMode: .explicit,
                explicitDestinationID: explicit.id,
                profile: profile,
                destinations: destinations,
                libraryDefaultDestinationID: libraryDefault.id
            ),
            explicit.id
        )
        XCTAssertEqual(
            CapturePresetRouteResolver.destinationID(
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
            CapturePresetRouteResolver.destinationID(
                selectionMode: .inherited,
                explicitDestinationID: nil,
                profile: profileWithoutRoute,
                destinations: destinations,
                libraryDefaultDestinationID: libraryDefault.id
            ),
            libraryDefault.id
        )
        XCTAssertNil(
            CapturePresetRouteResolver.destinationID(
                selectionMode: .inherited,
                explicitDestinationID: nil,
                profile: profileWithoutRoute,
                destinations: destinations,
                libraryDefaultDestinationID: libraryDefault.id,
                allowsLegacyFallback: false
            )
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
        let profile = CapturePresetProfile(
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
        let profile = CapturePresetProfile(
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

        let processed = await CapturePresetRequestProcessor(
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
        let profile = CapturePresetProfile(
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

        let processed = await CapturePresetRequestProcessor(
            textProcessor: FailingCaptureTextProcessor()
        ).process(request)

        guard case .text(let text) = processed.payloads[0] else {
            return XCTFail("Expected text")
        }
        XCTAssertEqual(text, "- [ ] Buy milk\n- [ ] Email sam")
        XCTAssertEqual(processed.voxProcessingState, .applied)
    }

    func test_processorRespectsProcessingScopePerPayload() async throws {
        let audio = try CaptureAssetReference(
            relativePath: "recording.m4a",
            originalFilename: "recording.m4a",
            contentTypeIdentifier: "public.audio"
        )
        func makeRequest(scope: CapturePresetProcessingScope) -> CaptureRequest {
            let profile = CapturePresetProfile(
                id: "scoped",
                name: "Scoped",
                symbolName: "waveform",
                postProcessingMode: .clean,
                captureProcessingEnabled: true,
                captureProcessingScope: scope
            )
            return CaptureRequest(
                source: .app,
                destinationID: UUID(),
                payloads: [
                    .text("typed"),
                    .audio(audio, transcript: "spoken"),
                ],
                frontmatter: [:],
                voxProfile: profile,
                voxProcessingState: .pending
            )
        }

        // Voice Only: the transcript is processed, typed text is untouched,
        // and no AI metadata is generated from the skipped typed payload.
        let voiceOnly = await CapturePresetRequestProcessor(
            textProcessor: StubCaptureTextProcessor()
        ).process(makeRequest(scope: .voiceOnly))
        guard case .text(let typed) = voiceOnly.payloads[0],
              case .audio(_, let spoken) = voiceOnly.payloads[1] else {
            return XCTFail("Expected text and audio payloads")
        }
        XCTAssertEqual(typed, "typed", "voice-only scope must not rewrite typed text")
        XCTAssertEqual(spoken, "PROCESSED: spoken")
        XCTAssertEqual(voiceOnly.voxProcessingState, .applied)

        // Text Only: the mirror image.
        let textOnly = await CapturePresetRequestProcessor(
            textProcessor: StubCaptureTextProcessor()
        ).process(makeRequest(scope: .textOnly))
        guard case .text(let typedAgain) = textOnly.payloads[0],
              case .audio(_, let spokenAgain) = textOnly.payloads[1] else {
            return XCTFail("Expected text and audio payloads")
        }
        XCTAssertEqual(typedAgain, "PROCESSED: typed")
        XCTAssertEqual(spokenAgain, "spoken", "text-only scope must not rewrite transcripts")
        XCTAssertEqual(textOnly.voxProcessingState, .applied)
    }
}

private struct StubCaptureTextProcessor: CapturePresetTextProcessing {
    func process(
        text: String,
        profile: CapturePresetProfile
    ) async throws -> CapturePresetTextProcessingResult {
        CapturePresetTextProcessingResult(
            text: "PROCESSED: \(text)",
            title: "Processed",
            tags: ["local", "capture"],
            category: "meeting"
        )
    }
}

private struct FailingCaptureTextProcessor: CapturePresetTextProcessing {
    struct Failure: Error {}

    func process(
        text: String,
        profile: CapturePresetProfile
    ) async throws -> CapturePresetTextProcessingResult {
        throw Failure()
    }
}
