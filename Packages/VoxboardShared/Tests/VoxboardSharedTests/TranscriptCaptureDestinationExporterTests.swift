import XCTest
@testable import VoxboardShared

final class TranscriptCaptureDestinationExporterTests: XCTestCase {
    func test_adapterRendersEnrichedTranscriptAndFlowFrontmatterAsMarkdownPayload() throws {
        var flow = RecordingFlowStore.makeCustomFlow()
        flow.staticFrontmatter = ["type": "meeting", "project": "vox"]
        let transcript = Transcript(
            text: "raw words",
            duration: 12,
            modelUsed: "base",
            language: "en"
        ).withEnrichment(
            title: "Planning",
            tags: ["meeting", "vox"],
            category: nil,
            cleanedText: "Clean meeting notes"
        )

        let payloads = try TranscriptCaptureAdapter.payloads(
            transcript: transcript,
            flow: flow,
            audioAsset: nil
        )
        guard case .text(let markdown) = try XCTUnwrap(payloads.first) else {
            return XCTFail("Expected Markdown text payload")
        }

        XCTAssertTrue(markdown.hasPrefix("---\n"))
        XCTAssertTrue(markdown.contains("type: \"meeting\""))
        XCTAssertTrue(markdown.contains("project: \"vox\""))
        XCTAssertTrue(markdown.contains("Clean meeting notes"))
        XCTAssertFalse(markdown.contains("raw words"))
    }

    func test_exportUsesDestinationPlacementAndCopiesRetainedAudio() async throws {
        let root = try temporaryFolder(named: "destination")
        let staging = try temporaryFolder(named: "staging")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        let noteURL = root.appendingPathComponent("Inbox.md")
        try "# Inbox\n\nOlder".write(to: noteURL, atomically: true, encoding: .utf8)
        let audioURL = staging.appendingPathComponent("recording.wav")
        try Data("audio".utf8).write(to: audioURL)
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md"),
            placement: .prepend,
            attachmentsFolderName: "media"
        )
        var flow = RecordingFlowStore.makeCustomFlow()
        flow.staticFrontmatter = ["type": "voice-note"]
        flow.audioSaveMode = .attachmentsFolder
        flow.attachmentsFolderName = "voice-media"
        flow.exportSettings.embedAudioInMarkdown = true
        flow.exportSettings.audioEmbedPlacement = .bottom
        let transcript = Transcript(
            text: "New spoken note",
            duration: 2,
            modelUsed: "base",
            language: "en"
        )

        let receipt = try await TranscriptCaptureDestinationExporter().export(
            transcript: transcript,
            flow: flow,
            destination: destination,
            destinationRootURL: root,
            stagingDirectoryURL: staging.appendingPathComponent("request"),
            audioSourceURL: audioURL
        )

        let markdown = try String(contentsOf: noteURL, encoding: .utf8)
        XCTAssertLessThan(try index(of: "New spoken note", in: markdown), try index(of: "Older", in: markdown))
        XCTAssertTrue(markdown.contains("![[voice-media/recording.wav]]"))
        XCTAssertEqual(receipt.attachmentURLs.map(\.lastPathComponent), ["recording.wav"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("voice-media/recording.wav")), Data("audio".utf8))
    }

    func test_alongsideAudioCanBeRetainedWithoutEmbedding() async throws {
        let root = try temporaryFolder(named: "alongside-destination")
        let staging = try temporaryFolder(named: "alongside-staging")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        let audioURL = staging.appendingPathComponent("private.wav")
        try Data("audio".utf8).write(to: audioURL)
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md"),
            attachmentsFolderName: "destination-media"
        )
        var flow = RecordingFlowStore.makeCustomFlow()
        flow.audioSaveMode = .alongsideTranscript
        flow.exportSettings.embedAudioInMarkdown = false

        _ = try await TranscriptCaptureDestinationExporter().export(
            transcript: Transcript(text: "Private voice", duration: 1, modelUsed: "base", language: "en"),
            flow: flow,
            destination: destination,
            destinationRootURL: root,
            stagingDirectoryURL: staging.appendingPathComponent("request"),
            audioSourceURL: audioURL
        )

        let markdown = try String(contentsOf: root.appendingPathComponent("Inbox.md"), encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("private.wav").path))
        XCTAssertFalse(markdown.contains("![["))
        XCTAssertTrue(markdown.contains("Private voice"))
    }

    func test_topAudioEmbedAppearsAfterFrontmatterBeforeTranscript() async throws {
        let root = try temporaryFolder(named: "top-audio-destination")
        let staging = try temporaryFolder(named: "top-audio-staging")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        let audioURL = staging.appendingPathComponent("top.wav")
        try Data("audio".utf8).write(to: audioURL)
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: Data(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        var flow = RecordingFlowStore.makeCustomFlow()
        flow.staticFrontmatter = ["type": "voice-note"]
        flow.audioSaveMode = .attachmentsFolder
        flow.attachmentsFolderName = "audio"
        flow.exportSettings.embedAudioInMarkdown = true
        flow.exportSettings.audioEmbedPlacement = .top

        _ = try await TranscriptCaptureDestinationExporter().export(
            transcript: Transcript(text: "Spoken body", duration: 1, modelUsed: "base", language: "en"),
            flow: flow,
            destination: destination,
            destinationRootURL: root,
            stagingDirectoryURL: staging.appendingPathComponent("request"),
            audioSourceURL: audioURL
        )

        let markdown = try String(contentsOf: root.appendingPathComponent("Inbox.md"), encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("---\n"))
        XCTAssertLessThan(try index(of: "---\n\n![[audio/top.wav]]", in: markdown), try index(of: "Spoken body", in: markdown))
    }

    func test_configuredExportIsDurableBeforeWritingAndUsesTranscriptIdentity() async throws {
        let captureRoot = try temporaryFolder(named: "durable-before-write")
        let destinationRoot = try temporaryFolder(named: "durable-destination")
        defer {
            try? FileManager.default.removeItem(at: captureRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: try destinationRoot.bookmarkData(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        try await CaptureLibraryStore(
            fileURL: captureRoot.appendingPathComponent(CaptureLibraryStore.defaultFilename),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).save(CaptureLibraryEnvelope(destinations: [destination], defaultDestinationID: destination.id))
        let transcript = Transcript(text: "Durable voice", duration: 1, modelUsed: "base", language: "en")
        let writer = InboxStateObservingWriter(captureRootURL: captureRoot)

        let receipt = try await ConfiguredTranscriptCaptureDestinationExporter.export(
            transcript: transcript,
            flow: RecordingFlowStore.makeCustomFlow(),
            destinationID: destination.id,
            audioSourceURL: nil,
            captureRootURL: captureRoot,
            pipeline: CapturePipeline(writer: writer)
        )

        let observedState = await writer.observedState
        let finalState = try await CaptureInbox(rootDirectoryURL: captureRoot).state(of: transcript.id)
        XCTAssertEqual(receipt.requestID, transcript.id)
        XCTAssertEqual(observedState, .processing)
        XCTAssertEqual(finalState, .completed)
        let deliveredHistory = try await CaptureHistoryStore(
            fileURL: captureRoot.appendingPathComponent(AppConstants.captureHistoryFilename),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).list()
        XCTAssertEqual(deliveredHistory.map(\.requestID), [transcript.id])
        XCTAssertEqual(deliveredHistory.first?.outcome, .delivered)
        XCTAssertEqual(deliveredHistory.first?.source, .voice)
    }

    func test_configuredExportQueuesExactRequestAndStagedAudioWhenDestinationWriteFails() async throws {
        let captureRoot = try temporaryFolder(named: "capture-root")
        let destinationRoot = try temporaryFolder(named: "failed-destination")
        defer {
            try? FileManager.default.removeItem(at: captureRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        let destination = CaptureDestination(
            name: "Broken Heading Route",
            rootBookmark: try destinationRoot.bookmarkData(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md"),
            placement: .beneathHeading(
                CaptureHeadingSelector(title: "Missing", level: 2),
                missingHeadingBehavior: .fail
            )
        )
        try await CaptureLibraryStore(
            fileURL: captureRoot.appendingPathComponent(CaptureLibraryStore.defaultFilename),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).save(CaptureLibraryEnvelope(destinations: [destination], defaultDestinationID: destination.id))
        let audioURL = captureRoot.appendingPathComponent("source.wav")
        try Data("audio-to-retry".utf8).write(to: audioURL)
        let transcript = Transcript(text: "Never lose me", duration: 2, modelUsed: "base", language: "en")
        var flow = RecordingFlowStore.makeCustomFlow()
        flow.audioSaveMode = .attachmentsFolder

        do {
            _ = try await ConfiguredTranscriptCaptureDestinationExporter.export(
                transcript: transcript,
                flow: flow,
                destinationID: destination.id,
                audioSourceURL: audioURL,
                captureRootURL: captureRoot,
                pipeline: CapturePipeline(
                    writer: CoordinatedCaptureWriter(coordinator: ProcessLocalCaptureFileCoordinator.shared)
                )
            )
            XCTFail("Expected route failure")
        } catch ConfiguredTranscriptCaptureError.queuedForRetry {
            // Expected.
        }

        let inbox = CaptureInbox(
            rootDirectoryURL: captureRoot,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let pendingIDs = try await inbox.requestIDs(in: .pending)
        let requestID = try XCTUnwrap(pendingIDs.first)
        XCTAssertEqual(requestID, transcript.id)
        let stagedDirectory = captureRoot
            .appendingPathComponent("inbox-staging")
            .appendingPathComponent(requestID.uuidString.lowercased())
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedDirectory.appendingPathComponent("source.wav").path))
        let failedHistory = try await CaptureHistoryStore(
            fileURL: captureRoot.appendingPathComponent(AppConstants.captureHistoryFilename),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).list()
        XCTAssertEqual(failedHistory.map(\.requestID), [transcript.id])
        XCTAssertEqual(failedHistory.first?.outcome, .failed)
    }

    func test_missingConfiguredDestinationQueuesTranscriptForReroute() async throws {
        let captureRoot = try temporaryFolder(named: "missing-route")
        defer { try? FileManager.default.removeItem(at: captureRoot) }
        try await CaptureLibraryStore(
            fileURL: captureRoot.appendingPathComponent(CaptureLibraryStore.defaultFilename),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).save(CaptureLibraryEnvelope())
        let missingID = UUID()

        do {
            _ = try await ConfiguredTranscriptCaptureDestinationExporter.export(
                transcript: Transcript(text: "Recover this voice note", duration: 1, modelUsed: "base", language: "en"),
                flow: RecordingFlowStore.makeCustomFlow(),
                destinationID: missingID,
                audioSourceURL: nil,
                captureRootURL: captureRoot
            )
            XCTFail("Expected queued route")
        } catch ConfiguredTranscriptCaptureError.queuedForRetry {
            // Expected.
        }

        let inbox = CaptureInbox(
            rootDirectoryURL: captureRoot,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        )
        let queued = try await inbox.claimNext()
        XCTAssertEqual(queued?.destinationID, missingID)
        guard case .text(let markdown)? = queued?.payloads.first else {
            return XCTFail("Expected queued transcript payload")
        }
        XCTAssertTrue(markdown.contains("Recover this voice note"))
    }

    func test_audioStagingFailureDoesNotQueueTranscriptOnlyRequest() async throws {
        let captureRoot = try temporaryFolder(named: "missing-audio")
        let destinationRoot = try temporaryFolder(named: "missing-audio-destination")
        defer {
            try? FileManager.default.removeItem(at: captureRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        let destination = CaptureDestination(
            name: "Inbox",
            rootBookmark: try destinationRoot.bookmarkData(),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        try await CaptureLibraryStore(
            fileURL: captureRoot.appendingPathComponent(CaptureLibraryStore.defaultFilename),
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).save(CaptureLibraryEnvelope(destinations: [destination], defaultDestinationID: destination.id))
        var flow = RecordingFlowStore.makeCustomFlow()
        flow.audioSaveMode = .attachmentsFolder

        do {
            _ = try await ConfiguredTranscriptCaptureDestinationExporter.export(
                transcript: Transcript(text: "Keep the words", duration: 1, modelUsed: "base", language: "en"),
                flow: flow,
                destinationID: destination.id,
                audioSourceURL: captureRoot.appendingPathComponent("missing.wav"),
                captureRootURL: captureRoot
            )
            XCTFail("Expected queued staging failure")
        } catch ConfiguredTranscriptCaptureError.audioPreparationFailed {
            // The caller must retain the source audio and offer a real retry;
            // never enqueue a reduced transcript-only request.
        }

        let queued = try await CaptureInbox(
            rootDirectoryURL: captureRoot,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).claimNext()
        XCTAssertNil(queued)
    }

    func test_recordingFlowRoundTripsCaptureDestinationBinding() throws {
        let destinationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var flow = RecordingFlowStore.makeCustomFlow()
        flow.captureDestinationID = destinationID

        let decoded = try JSONDecoder().decode(
            RecordingFlow.self,
            from: JSONEncoder().encode(flow)
        )

        XCTAssertEqual(decoded.captureDestinationID, destinationID)
    }

    private func temporaryFolder(named: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptCaptureDestinationExporterTests-\(named)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func index(of needle: String, in haystack: String) throws -> String.Index {
        try XCTUnwrap(haystack.range(of: needle)?.lowerBound)
    }
}

private actor InboxStateObservingWriter: CaptureMutationWriting {
    let captureRootURL: URL
    private let delegate = CoordinatedCaptureWriter(coordinator: ProcessLocalCaptureFileCoordinator.shared)
    private(set) var observedState: CaptureInboxState?

    init(captureRootURL: URL) {
        self.captureRootURL = captureRootURL
    }

    func write(
        _ mutation: MarkdownCaptureMutation,
        to fileURL: URL
    ) async throws -> CaptureWriteReceipt {
        observedState = try await CaptureInbox(
            rootDirectoryURL: captureRootURL,
            coordinator: ProcessLocalCaptureFileCoordinator.shared
        ).state(of: mutation.requestID)
        return try await delegate.write(mutation, to: fileURL)
    }
}
