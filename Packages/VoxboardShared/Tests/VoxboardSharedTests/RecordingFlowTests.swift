import XCTest
@testable import VoxboardShared

final class RecordingFlowTests: XCTestCase {

    func test_defaultFlows_includeOnlyDefaultFlow() {
        let flows = RecordingFlowStore.defaultFlows

        XCTAssertEqual(flows.map(\.id), [RecordingFlowStore.generalId])
        XCTAssertEqual(flows.first?.displayName, "Default")
        XCTAssertEqual(flows.first?.kind, .general)
    }

    func test_usesAIEnrichment_isControlledByPostProcessingMode() {
        var flow = RecordingFlowStore.defaultFlow
        XCTAssertTrue(flow.usesAIEnrichment)

        flow.postProcessingMode = .none
        XCTAssertFalse(flow.usesAIEnrichment)

        flow.postProcessingMode = .todoList
        XCTAssertTrue(flow.usesAIEnrichment)
    }

    func test_loadFlows_removesDeprecatedBuiltInsAndPreservesCustomFlows() throws {
        let suiteName = "test.flow.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let custom = RecordingFlow(
            id: "custom-test",
            name: "My Meeting Flow",
            symbolName: "person.2",
            isBuiltIn: false,
            kind: .custom,
            exportSettings: RecordingFlowExportSettings(usesCustomExportSettings: false),
            postProcessingMode: .meetingNotes
        )
        let oldBuiltIns = [
            RecordingFlow(
                id: "dream",
                name: "Dream Journal",
                symbolName: "moon.stars",
                isBuiltIn: true,
                kind: .dream
            ),
            RecordingFlow(
                id: "todo",
                name: "Todo List",
                symbolName: "checklist",
                isBuiltIn: true,
                kind: .todo
            ),
            RecordingFlow(
                id: "meeting",
                name: "Meeting / Call",
                symbolName: "person.2.wave.2",
                isBuiltIn: true,
                kind: .meeting
            ),
        ]
        let oldDefault = RecordingFlow(
            id: RecordingFlowStore.generalId,
            name: "General Note",
            symbolName: "text.alignleft",
            isBuiltIn: true,
            kind: .general
        )
        let stored = [oldDefault, custom] + oldBuiltIns
        defaults.set(try JSONEncoder().encode(stored), forKey: RecordingFlowStore.flowsKey)

        let loaded = RecordingFlowStore.loadFlows(defaults: defaults)

        XCTAssertEqual(loaded.map(\.id).sorted(), [RecordingFlowStore.generalId, custom.id].sorted())
        XCTAssertTrue(loaded.contains { $0.id == RecordingFlowStore.generalId && $0.displayName == "Default" })
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

        let custom = RecordingFlow(
            id: "custom-legacy",
            name: "Legacy Export Flow",
            symbolName: "folder",
            isBuiltIn: false,
            kind: .custom,
            exportSettings: RecordingFlowExportSettings(usesCustomExportSettings: false)
        )
        defaults.set(try JSONEncoder().encode([custom]), forKey: RecordingFlowStore.flowsKey)

        let loaded = RecordingFlowStore.loadFlows(defaults: defaults)
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

        let loaded = RecordingFlowStore.loadFlows(defaults: defaults)
        let defaultFlow = try XCTUnwrap(loaded.first { $0.id == RecordingFlowStore.generalId })

        XCTAssertTrue(defaultFlow.exportSettings.usesCustomExportSettings)
        XCTAssertTrue(defaultFlow.exportSettings.exportEnabled)
        XCTAssertEqual(defaultFlow.exportSettings.format, .md)
        XCTAssertEqual(defaultFlow.exportSettings.folderName, tempFolder.lastPathComponent)
        XCTAssertNotNil(defaultFlow.exportSettings.folderBookmark)
    }

    func test_todoFlowFormatter_outputsMarkdownCheckboxes() {
        var flow = RecordingFlowStore.makeCustomFlow()
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

        var flow = RecordingFlowStore.makeCustomFlow()
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

    #if canImport(AVFoundation)
    func test_audioDestinationURL_usesFlowAudioFolderOverride() {
        let transcriptURL = URL(fileURLWithPath: "/tmp/Notes/meeting.md")
        let audioFolder = URL(fileURLWithPath: "/tmp/Audio Clips")
        var flow = RecordingFlowStore.makeCustomFlow()
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
        var flow = RecordingFlowStore.makeCustomFlow()
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

        var flow = RecordingFlowStore.makeCustomFlow()
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
