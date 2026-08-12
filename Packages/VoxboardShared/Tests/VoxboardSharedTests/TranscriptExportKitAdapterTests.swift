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

    func test_pathPlannerRendersTwoDigitYearToken() throws {
        let transcript = Transcript(
            id: UUID(),
            text: "Two-digit year",
            date: Date(timeIntervalSince1970: 1_704_164_645),
            duration: 1,
            modelUsed: "base",
            language: "en"
        )
        let config = TranscriptExportConfiguration(
            format: .txt,
            mode: .newFile,
            newFileNameTemplate: "daily-{YR}"
        )

        let filenameBase = TranscriptExportPathPlanner(configuration: config)
            .filenameBase(for: TranscriptExportRecord(transcript: transcript))

        XCTAssertEqual(filenameBase, "daily-24")
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

    func test_newFileRetryReusesExactAtomicOutputInsteadOfCreatingDuplicateName() throws {
        let transcript = Transcript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            text: "Crash-safe new file",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1,
            modelUsed: "base",
            language: "en"
        )
        let config = TranscriptExportConfiguration(
            format: .txt,
            mode: .newFile,
            deliveryTransactionDirectoryURL: tempFolder
                .appendingPathComponent("transactions/new-file", isDirectory: true)
        )
        let run = TranscriptExportRun(configuration: config)

        let firstURL = try run.export(transcript, to: tempFolder)
        let retriedURL = try run.export(transcript, to: tempFolder)

        XCTAssertEqual(retriedURL, firstURL)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: tempFolder,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "txt" }.count,
            1
        )
    }

    func test_plainTextAppendRetryDoesNotRepeatAtomicTailPayload() throws {
        let transcript = Transcript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!,
            text: "Crash-safe append payload",
            date: Date(timeIntervalSince1970: 1_700_000_001),
            duration: 1,
            modelUsed: "base",
            language: "en"
        )
        let run = TranscriptExportRun(configuration: TranscriptExportConfiguration(
            format: .txt,
            mode: .append,
            deliveryTransactionDirectoryURL: tempFolder
                .appendingPathComponent("transactions/text-append", isDirectory: true)
        ))

        let url = try run.export(transcript, to: tempFolder)
        _ = try run.export(transcript, to: tempFolder)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content.components(separatedBy: "Crash-safe append payload").count - 1, 1)
    }

    func test_jsonAppendRetryDeduplicatesStableTranscriptID() throws {
        let transcript = Transcript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000333")!,
            text: "Crash-safe JSON append",
            date: Date(timeIntervalSince1970: 1_700_000_002),
            duration: 1,
            modelUsed: "base",
            language: "en"
        )
        let run = TranscriptExportRun(configuration: TranscriptExportConfiguration(
            format: .json,
            mode: .append,
            deliveryTransactionDirectoryURL: tempFolder
                .appendingPathComponent("transactions/json-append", isDirectory: true)
        ))

        let url = try run.export(transcript, to: tempFolder)
        _ = try run.export(transcript, to: tempFolder)

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([Transcript].self, from: data)
        XCTAssertEqual(decoded.map(\.id), [transcript.id])
    }

    func test_distinctIdenticalPlainTextAppendDeliveriesAreBothWritten() throws {
        let first = Transcript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000501")!,
            text: "Intentionally identical",
            date: Date(timeIntervalSince1970: 1_700_000_003),
            duration: 1,
            modelUsed: "base",
            language: "en"
        )
        let second = Transcript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000502")!,
            text: first.text,
            date: first.date,
            duration: first.duration,
            modelUsed: first.modelUsed,
            language: first.language
        )

        let firstURL = try TranscriptExportRun(configuration: TranscriptExportConfiguration(
            format: .txt,
            mode: .append,
            deliveryTransactionDirectoryURL: tempFolder
                .appendingPathComponent("transactions/distinct-append-1", isDirectory: true)
        )).export(first, to: tempFolder)
        _ = try TranscriptExportRun(configuration: TranscriptExportConfiguration(
            format: .txt,
            mode: .append,
            deliveryTransactionDirectoryURL: tempFolder
                .appendingPathComponent("transactions/distinct-append-2", isDirectory: true)
        )).export(second, to: tempFolder)

        let content = try String(contentsOf: firstURL, encoding: .utf8)
        XCTAssertEqual(content.components(separatedBy: "Intentionally identical").count - 1, 2)
    }

    func test_distinctIdenticalNewFileDeliveriesUseDifferentFiles() throws {
        let first = Transcript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000503")!,
            text: "Same new-file body",
            date: Date(timeIntervalSince1970: 1_700_000_004),
            duration: 1,
            modelUsed: "base",
            language: "en"
        )
        let second = Transcript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000504")!,
            text: first.text,
            date: first.date,
            duration: first.duration,
            modelUsed: first.modelUsed,
            language: first.language
        )
        let makeRun: (String) -> TranscriptExportRun = { key in
            TranscriptExportRun(configuration: TranscriptExportConfiguration(
                format: .txt,
                mode: .newFile,
                newFileNameTemplate: "fixed",
                deliveryTransactionDirectoryURL: self.tempFolder
                    .appendingPathComponent("transactions/\(key)", isDirectory: true)
            ))
        }

        let firstURL = try makeRun("distinct-new-1").export(first, to: tempFolder)
        let secondURL = try makeRun("distinct-new-2").export(second, to: tempFolder)

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(firstURL.lastPathComponent, "fixed.txt")
        XCTAssertEqual(secondURL.lastPathComponent, "fixed-2.txt")
    }

    func test_newFileTransactionResumesPreviouslySelectedUniquedPath() throws {
        let occupiedURL = tempFolder.appendingPathComponent("fixed.txt")
        try "Unrelated existing note".write(to: occupiedURL, atomically: true, encoding: .utf8)
        let transcript = Transcript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000505")!,
            text: "Crash after writing the uniqued path",
            date: Date(timeIntervalSince1970: 1_700_000_005),
            duration: 1,
            modelUsed: "base",
            language: "en"
        )
        let run = TranscriptExportRun(configuration: TranscriptExportConfiguration(
            format: .txt,
            mode: .newFile,
            newFileNameTemplate: "fixed",
            deliveryTransactionDirectoryURL: tempFolder
                .appendingPathComponent("transactions/uniqued-retry", isDirectory: true)
        ))

        let firstURL = try run.export(transcript, to: tempFolder)
        let retriedURL = try run.export(transcript, to: tempFolder)

        XCTAssertEqual(firstURL.lastPathComponent, "fixed-2.txt")
        XCTAssertEqual(retriedURL, firstURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFolder.appendingPathComponent("fixed-3.txt").path))
    }

    func test_deliveryTransactionRejectsExternalEditAfterPublishedCrashBoundary() throws {
        let targetURL = tempFolder.appendingPathComponent("conflict.txt")
        try "Before".write(to: targetURL, atomically: true, encoding: .utf8)
        let transaction = ExternalFileDeliveryTransaction(
            directoryURL: tempFolder.appendingPathComponent("transactions/conflict", isDirectory: true)
        )
        _ = try transaction.prepareAndPublish(
            data: Data("Expected postimage".utf8),
            to: targetURL,
            expecting: .contents(Data("Before".utf8))
        )
        try "User changed destination".write(to: targetURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try transaction.resumeIfPrepared()) { error in
            XCTAssertEqual(
                error as? ExternalFileDeliveryTransaction.TransactionError,
                .destinationConflict
            )
        }
        XCTAssertEqual(
            try String(contentsOf: targetURL, encoding: .utf8),
            "User changed destination"
        )
    }

    func test_deliveryTransactionRejectsEditBetweenReadAndJournalPreparation() throws {
        let targetURL = tempFolder.appendingPathComponent("preimage-conflict.txt")
        let original = Data("Original preimage".utf8)
        try original.write(to: targetURL, options: .atomic)
        let transaction = ExternalFileDeliveryTransaction(
            directoryURL: tempFolder.appendingPathComponent("transactions/preimage-conflict", isDirectory: true)
        )
        let userEdited = Data("Concurrent user edit".utf8)
        try userEdited.write(to: targetURL, options: .atomic)

        XCTAssertThrowsError(try transaction.prepareAndPublish(
            data: Data("Stale merged result".utf8),
            to: targetURL,
            expecting: .contents(original)
        )) { error in
            XCTAssertEqual(
                error as? ExternalFileDeliveryTransaction.TransactionError,
                .destinationConflict
            )
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), userEdited)
    }

    func test_deliveryTransactionRejectsEditInsideFinalCoordinatedPublishBoundary() throws {
        let targetURL = tempFolder.appendingPathComponent("coordinated-conflict.txt")
        let original = Data("Original coordinated preimage".utf8)
        let userEdited = Data("Edit during coordinated publication".utf8)
        try original.write(to: targetURL, options: .atomic)
        let transaction = ExternalFileDeliveryTransaction(
            directoryURL: tempFolder.appendingPathComponent("transactions/coordinated-conflict", isDirectory: true),
            beforeCoordinatedPublish: {
                try userEdited.write(to: targetURL, options: .atomic)
            }
        )

        XCTAssertThrowsError(try transaction.prepareAndPublish(
            data: Data("Would overwrite user edit".utf8),
            to: targetURL,
            expecting: .contents(original)
        )) { error in
            XCTAssertEqual(
                error as? ExternalFileDeliveryTransaction.TransactionError,
                .destinationConflict
            )
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), userEdited)
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
