import XCTest
import ExportKit
@testable import VoxboardShared

final class TranscriptExportKitAdapterTests: XCTestCase {
    private var tempFolder: URL!

    override func setUp() {
        super.setUp()
        tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxboardExportKitTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFolder)
        super.tearDown()
    }

    func test_rendererOutputsMarkdownAndAppendJSONPayloads() throws {
        let transcript = Transcript(text: "ExportKit renderer", duration: 12, modelUsed: "base", language: "en")
        let record = TranscriptExportRecord(transcript: transcript)

        let markdownConfig = TranscriptExportConfiguration(format: .md, mode: .newFile)
        let markdownRegistry = try TranscriptExportRendererFactory.registry(configuration: markdownConfig)
        let markdown = try markdownRegistry.render(record: record, formatID: ExportFileFormat.md.exportKitFormatID)
        XCTAssertEqual(markdown.contentType, "text/markdown")
        XCTAssertTrue(markdown.content.contains("## Transcript"))
        XCTAssertTrue(markdown.content.contains("ExportKit renderer"))

        let jsonConfig = TranscriptExportConfiguration(format: .json, mode: .append)
        let jsonRegistry = try TranscriptExportRendererFactory.registry(configuration: jsonConfig)
        let json = try jsonRegistry.render(record: record, formatID: ExportFileFormat.json.exportKitFormatID)
        let decoded = try JSONDecoder().decode([Transcript].self, from: Data(json.content.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].text, "ExportKit renderer")
    }

    func test_pathPlannerBuildsRelativePathsAndDestinationWriterRejectsTraversal() throws {
        let transcript = Transcript(text: "Path safety", duration: 1, modelUsed: "base", language: "fr")
        let record = TranscriptExportRecord(transcript: transcript)
        let config = TranscriptExportConfiguration(
            format: .txt,
            mode: .newFile,
            newFileNameTemplate: "voice-{language}-{id8}"
        )
        let descriptor = config.format.exportKitDescriptor()
        let rendered = RenderedExport(content: "Path safety", contentType: descriptor.contentType)
        let planned = try TranscriptExportPathPlanner(configuration: config)
            .planFile(record: record, descriptor: descriptor, rendered: rendered)

        XCTAssertTrue(planned.relativePath.hasPrefix("voice-fr-"))
        XCTAssertTrue(planned.relativePath.hasSuffix(".txt"))
        XCTAssertFalse(planned.relativePath.contains(".."))

        let unsafe = PlannedExportFile(
            id: "unsafe",
            role: .aggregate(formatID: descriptor.id),
            relativePath: "../escape.txt",
            content: "nope",
            format: descriptor,
            contentType: descriptor.contentType
        )
        let destination = ExportDestination(rootURL: tempFolder)
        XCTAssertThrowsError(
            try TranscriptDestinationWriter().write(unsafe, configuration: config, to: destination)
        )
    }

    func test_newFileModeUsesExportKitWriterAndPreservesUniquing() throws {
        let transcript = Transcript(text: "Unique", duration: 1, modelUsed: "base", language: "en")
        let config = TranscriptExportConfiguration(
            format: .txt,
            mode: .newFile,
            newFileNameTemplate: "fixed-name"
        )
        let run = TranscriptExportRun(configuration: config)

        let first = try run.export(transcript, to: tempFolder)
        let second = try run.export(transcript, to: tempFolder)

        XCTAssertEqual(first.lastPathComponent, "fixed-name.txt")
        XCTAssertEqual(second.lastPathComponent, "fixed-name-2.txt")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "Unique")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "Unique")
    }

    func test_appendModeUsesAppMergeStrategiesForTextAndJSON() throws {
        let first = Transcript(text: "First", duration: 1, modelUsed: "base", language: "en")
        let second = Transcript(text: "Second", duration: 2, modelUsed: "base", language: "en")

        let textConfig = TranscriptExportConfiguration(
            format: .txt,
            mode: .append,
            appendFileName: "daily"
        )
        let textRun = TranscriptExportRun(configuration: textConfig)
        let textURL = try textRun.export(first, to: tempFolder)
        _ = try textRun.export(second, to: tempFolder)
        let textContent = try String(contentsOf: textURL, encoding: .utf8)
        XCTAssertTrue(textContent.contains("First\n\n---\n\nSecond"))

        let jsonConfig = TranscriptExportConfiguration(
            format: .json,
            mode: .append,
            appendFileName: "daily-json"
        )
        let jsonRun = TranscriptExportRun(configuration: jsonConfig)
        let jsonURL = try jsonRun.export(first, to: tempFolder)
        _ = try jsonRun.export(second, to: tempFolder)
        let decoded = try JSONDecoder().decode([Transcript].self, from: Data(contentsOf: jsonURL))
        XCTAssertEqual(decoded.map(\.text), ["First", "Second"])
    }

    func test_obsidianMarkdownAppend_keepsSingleFrontmatterAndBothTranscripts() throws {
        let first = Transcript(text: "First Obsidian", duration: 1, modelUsed: "base", language: "en")
        let second = Transcript(text: "Second Obsidian", duration: 2, modelUsed: "base", language: "en")
        let config = TranscriptExportConfiguration(
            format: .md,
            mode: .append,
            mdObsidianEnabled: true,
            staticFrontmatter: ["type": "voice-note", "tags": "[manual]"]
        )
        let run = TranscriptExportRun(configuration: config)

        let url = try run.export(first, to: tempFolder)
        _ = try run.export(second, to: tempFolder)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content.components(separatedBy: "---").count - 1, 2)
        XCTAssertEqual(content.components(separatedBy: "type:").count - 1, 1)
        XCTAssertTrue(content.contains("First Obsidian"))
        XCTAssertTrue(content.contains("Second Obsidian"))
    }

    func test_yamlMarkdownAppend_keepsSingleFrontmatterAndBothTranscripts() throws {
        let first = Transcript(text: "First YAML Markdown", duration: 1, modelUsed: "base", language: "en")
        let second = Transcript(text: "Second YAML Markdown", duration: 2, modelUsed: "small", language: "fr")
        let config = TranscriptExportConfiguration(
            format: .yaml,
            mode: .append,
            yamlUsesMarkdownExtension: true,
            staticFrontmatter: ["type": "voice-note"]
        )
        let run = TranscriptExportRun(configuration: config)

        let url = try run.export(first, to: tempFolder)
        _ = try run.export(second, to: tempFolder)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(url.pathExtension, "md")
        XCTAssertEqual(content.components(separatedBy: "---").count - 1, 2)
        XCTAssertTrue(content.contains("First YAML Markdown"))
        XCTAssertTrue(content.contains("Second YAML Markdown"))
    }

    func test_markdownAppend_mergesTagsAndAudioWithoutDuplicates() throws {
        let first = Transcript(
            text: "First",
            duration: 1,
            modelUsed: "base",
            language: "en"
        ).withEnrichment(title: nil, tags: ["manual", "voice"], category: nil, cleanedText: nil)
        let second = Transcript(
            text: "Second",
            duration: 1,
            modelUsed: "base",
            language: "en"
        ).withEnrichment(title: nil, tags: ["voice", "idea"], category: nil, cleanedText: nil)
        let firstConfig = TranscriptExportConfiguration(
            format: .md,
            mode: .append,
            mdObsidianEnabled: true,
            staticFrontmatter: ["tags": "[manual]"],
            audioAttachmentRelativePath: "first.m4a"
        )
        let secondConfig = TranscriptExportConfiguration(
            format: .md,
            mode: .append,
            mdObsidianEnabled: true,
            staticFrontmatter: ["tags": "[manual]"],
            audioAttachmentRelativePath: "second.m4a"
        )

        let url = try TranscriptExportRun(configuration: firstConfig).export(first, to: tempFolder)
        _ = try TranscriptExportRun(configuration: secondConfig).export(second, to: tempFolder)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content.components(separatedBy: "tags:").count - 1, 1)
        XCTAssertEqual(content.components(separatedBy: "audio:").count - 1, 1)
        for value in ["manual", "voice", "idea", "first.m4a", "second.m4a"] {
            XCTAssertTrue(content.contains(value), "Missing merged value: \(value)")
        }
    }

    func test_previewGenerationUsesExportKitPlannedFilesWithoutWriting() async throws {
        let transcripts = [
            Transcript(text: "Older", duration: 1, modelUsed: "base", language: "en"),
            Transcript(text: "Newest", duration: 1, modelUsed: "base", language: "en")
        ]
        let config = TranscriptExportConfiguration(format: .md, mode: .newFile)

        let preview = try await TranscriptExportPreviewFactory.buildPreview(
            transcripts: transcripts,
            configuration: config,
            maxRenderedRecords: 1,
            maxFetchAttempts: 2
        )

        XCTAssertEqual(preview.totalRecordCount, 2)
        XCTAssertEqual(preview.renderedRecordCount, 1)
        XCTAssertEqual(preview.records.first?.files.count, 1)
        XCTAssertTrue(preview.records.first?.files.first?.relativePath.hasSuffix(".md") == true)
        XCTAssertTrue(preview.records.first?.files.first?.content.contains("Newest") == true)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(at: tempFolder, includingPropertiesForKeys: nil).isEmpty) == true)
    }

    func test_batchOrchestratorReportsSuccessAndProgress() async throws {
        let transcripts = [
            Transcript(text: "One", duration: 1, modelUsed: "base", language: "en"),
            Transcript(text: "Two", duration: 2, modelUsed: "base", language: "en")
        ]
        let config = TranscriptExportConfiguration(format: .txt, mode: .newFile)
        var phases: [ExportProgressPhase] = []

        let result = await TranscriptExportBatchOrchestrator.export(
            transcripts: transcripts,
            configuration: config,
            folderURL: tempFolder
        ) { progress in
            phases.append(progress.phase)
        }

        XCTAssertEqual(result.status, .fullSuccess)
        XCTAssertEqual(result.successCount, 2)
        XCTAssertEqual(result.filesWritten, 2)
        XCTAssertTrue(phases.contains(.planning))
        XCTAssertTrue(phases.contains(.writing))
        XCTAssertTrue(phases.contains(.completed))
    }

    func test_batchOrchestratorReportsFailureForInvalidDestination() async throws {
        let invalidDestination = tempFolder.appendingPathComponent("not-a-folder")
        try "occupied".write(to: invalidDestination, atomically: true, encoding: .utf8)
        let config = TranscriptExportConfiguration(format: .txt, mode: .newFile)

        let result = await TranscriptExportBatchOrchestrator.export(
            transcripts: [Transcript(text: "Cannot write", duration: 1, modelUsed: "base", language: "en")],
            configuration: config,
            folderURL: invalidDestination
        )

        XCTAssertEqual(result.status, .failure)
        XCTAssertEqual(result.successCount, 0)
        XCTAssertEqual(result.failedRecords.first?.failure.reason, .writeError)
    }

    func test_nonVoxboardRecordUsesExportKitGenericallyAndCanPartiallySucceed() async throws {
        struct SampleNoteRecord: ExportRecord {
            let id: String
            let date: Date
            let body: String
            var exportRecordID: String { id }
            var exportDate: Date { date }
        }

        let descriptor = ExportFormatDescriptor(
            id: "sample-note-text",
            displayName: "Sample Note Text",
            fileExtension: "txt",
            contentType: "text/plain"
        )
        let renderer = AnyExportRenderer<SampleNoteRecord>(descriptor: descriptor) { record, _ in
            RenderedExport(content: record.body, contentType: descriptor.contentType)
        }
        let registry = try ExportRendererRegistry(renderers: [renderer])
        let records = [
            1: SampleNoteRecord(id: "one", date: Date(), body: "hello generic export"),
            2: nil
        ]
        let dataSource = AnyExportRecordDataSource<Int, SampleNoteRecord> { input in
            ExportFetchedRecord(record: records[input] ?? nil)
        }
        let fileWriter = ExportFileWriter(fileSystem: FileManagerExportFileSystem())
        let destination = ExportDestination(rootURL: tempFolder)
        let recordWriter = AnyExportRecordWriter<SampleNoteRecord> { record, context in
            let rendered = try registry.render(record: record, formatID: descriptor.id)
            let relativePath = try ExportPathTemplate(filenameTemplate: "{recordID}", fileExtension: descriptor.fileExtension)
                .plannedRelativePath(
                    variables: ExportPathVariables(date: record.exportDate, values: ["recordID": record.exportRecordID]),
                    safetyPolicy: .rejectTraversalAndAbsolutePaths
                )
            let file = PlannedExportFile(
                id: record.exportRecordID,
                role: .aggregate(formatID: descriptor.id),
                relativePath: relativePath,
                content: rendered.content,
                format: descriptor,
                contentType: descriptor.contentType
            )
            _ = try fileWriter.write(file, to: context.destination ?? destination, mode: context.writeMode)
            return ExportRecordWriteSummary(filesWritten: 1)
        }
        let orchestrator = ExportRunOrchestrator<Int, SampleNoteRecord>(
            dataSource: dataSource,
            writer: recordWriter
        )

        let result = await orchestrator.run(
            ExportRunRequest(
                recordInputs: [1, 2],
                formatIDs: [descriptor.id],
                destination: destination,
                writeMode: .overwrite,
                recordReference: { ExportRecordReference(id: "sample-\($0)") }
            )
        )

        XCTAssertEqual(result.status, .partialSuccess)
        XCTAssertEqual(result.successCount, 1)
        XCTAssertEqual(result.failedRecords.first?.failure.reason, .noData)
        XCTAssertEqual(try String(contentsOf: tempFolder.appendingPathComponent("one.txt"), encoding: .utf8), "hello generic export")
    }
}
