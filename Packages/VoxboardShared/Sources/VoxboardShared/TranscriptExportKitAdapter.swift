import Foundation
import ExportKit

/// ExportKit-facing payload for a Voxboard transcript export.
///
/// Voxboard keeps the full domain model (`Transcript`) in the app package and
/// exposes only ExportKit's generic identity/date surface to the reusable
/// infrastructure.
public struct TranscriptExportRecord: ExportRecord, Codable, Sendable {
    public var transcript: Transcript

    public init(transcript: Transcript) {
        self.transcript = transcript
    }

    public var exportRecordID: String { transcript.id.uuidString.lowercased() }
    public var exportDate: Date { transcript.date }
}

/// App-owned export configuration. It intentionally contains Voxboard choices
/// (format toggles, filename defaults, enrichment, template content) rather
/// than putting those decisions into ExportKit.
public struct TranscriptExportConfiguration: Equatable, Sendable {
    public var format: ExportFileFormat
    public var mode: ExportFileMode
    public var yamlProperties: Set<ExportYAMLProperty>
    public var yamlUsesMarkdownExtension: Bool
    public var mdObsidianEnabled: Bool
    public var enrichmentOptions: TranscriptExportEnrichmentOptions
    public var staticFrontmatter: [String: String]
    public var audioAttachmentRelativePath: String?
    public var newFileNameTemplate: String
    public var appendFileName: String
    public var markdownTemplateContent: String?

    public init(
        format: ExportFileFormat,
        mode: ExportFileMode,
        yamlProperties: Set<ExportYAMLProperty> = ExportYAMLProperty.defaultSelection,
        yamlUsesMarkdownExtension: Bool = false,
        mdObsidianEnabled: Bool = false,
        enrichmentOptions: TranscriptExportEnrichmentOptions = .default,
        staticFrontmatter: [String: String] = [:],
        audioAttachmentRelativePath: String? = nil,
        newFileNameTemplate: String = TranscriptFileExporter.defaultNewFileNameTemplate,
        appendFileName: String = TranscriptFileExporter.defaultAppendFileName,
        markdownTemplateContent: String? = nil
    ) {
        self.format = format
        self.mode = mode
        self.yamlProperties = yamlProperties
        self.yamlUsesMarkdownExtension = yamlUsesMarkdownExtension
        self.mdObsidianEnabled = mdObsidianEnabled
        self.enrichmentOptions = enrichmentOptions
        self.staticFrontmatter = staticFrontmatter
        self.audioAttachmentRelativePath = audioAttachmentRelativePath
        self.newFileNameTemplate = newFileNameTemplate
        self.appendFileName = appendFileName
        self.markdownTemplateContent = markdownTemplateContent
    }

    public var selectedFormatIDs: [String] { [format.exportKitFormatID] }
    public var writeMode: ExportWriteMode { mode == .newFile ? .overwrite : .update }

    public var appendSeparator: String {
        if (format == .yaml && yamlUsesMarkdownExtension) || (format == .md && mdObsidianEnabled) {
            return "\n\n"
        }
        return "\n\n---\n\n"
    }

    public var portableProfile: PortableExportProfileSnapshot {
        PortableExportProfileSnapshot(
            formatIDs: selectedFormatIDs,
            aggregateFolderTemplate: "",
            aggregateFilenameTemplate: "{filenameBase}",
            writeMode: writeMode,
            metadata: [
                "app": "Voxboard",
                "domain": "transcript",
                "mode": mode.rawValue
            ]
        )
    }
}

public extension ExportFileFormat {
    var exportKitFormatID: String { rawValue }

    func exportKitDescriptor(
        yamlUsesMarkdownExtension: Bool = false,
        mdObsidianEnabled: Bool = false
    ) -> ExportFormatDescriptor {
        switch self {
        case .txt:
            return ExportFormatDescriptor(
                id: exportKitFormatID,
                displayName: "Plain Text",
                fileExtension: fileExtension,
                contentType: "text/plain",
                defaultSortKey: "10-txt"
            )
        case .md:
            return ExportFormatDescriptor(
                id: exportKitFormatID,
                displayName: mdObsidianEnabled ? "Markdown Frontmatter" : "Markdown",
                fileExtension: fileExtension,
                contentType: "text/markdown",
                defaultSortKey: "20-md"
            )
        case .json:
            return ExportFormatDescriptor(
                id: exportKitFormatID,
                displayName: "JSON",
                fileExtension: fileExtension,
                contentType: "application/json",
                defaultSortKey: "30-json"
            )
        case .yaml:
            return ExportFormatDescriptor(
                id: exportKitFormatID,
                displayName: yamlUsesMarkdownExtension ? "YAML Frontmatter" : "YAML",
                fileExtension: yamlUsesMarkdownExtension ? ExportFileFormat.md.fileExtension : fileExtension,
                contentType: yamlUsesMarkdownExtension ? "text/markdown" : "application/x-yaml",
                defaultSortKey: "40-yaml"
            )
        }
    }
}

public struct TranscriptExportRenderer: ExportRenderer {
    public typealias Record = TranscriptExportRecord

    public var configuration: TranscriptExportConfiguration
    public var descriptor: ExportFormatDescriptor

    public init(configuration: TranscriptExportConfiguration) {
        self.configuration = configuration
        self.descriptor = configuration.format.exportKitDescriptor(
            yamlUsesMarkdownExtension: configuration.yamlUsesMarkdownExtension,
            mdObsidianEnabled: configuration.mdObsidianEnabled
        )
    }

    public func render(record: TranscriptExportRecord, context: ExportRenderContext) throws -> RenderedExport {
        let content = try TranscriptFileExporter.exportKitRenderedContent(
            record.transcript,
            configuration: configuration
        )
        return RenderedExport(content: content, contentType: descriptor.contentType)
    }
}

public enum TranscriptExportRendererFactory {
    public static func registry(
        configuration: TranscriptExportConfiguration
    ) throws -> ExportRendererRegistry<TranscriptExportRecord> {
        try ExportRendererRegistry(renderers: [
            AnyExportRenderer(TranscriptExportRenderer(configuration: configuration))
        ])
    }
}

public struct TranscriptExportPathPlanner {
    public var configuration: TranscriptExportConfiguration
    public var safetyPolicy: ExportPathSafetyPolicy

    public init(
        configuration: TranscriptExportConfiguration,
        safetyPolicy: ExportPathSafetyPolicy = .rejectTraversalAndAbsolutePaths
    ) {
        self.configuration = configuration
        self.safetyPolicy = safetyPolicy
    }

    public func filenameBase(for record: TranscriptExportRecord) -> String {
        switch configuration.mode {
        case .newFile:
            return TranscriptFileExporter.exportKitResolvedNewFileBaseName(
                for: record.transcript,
                enrichmentOptions: configuration.enrichmentOptions,
                template: configuration.newFileNameTemplate
            )
        case .append:
            return TranscriptFileExporter.exportKitResolvedAppendFileBaseName(
                template: configuration.appendFileName
            )
        }
    }

    public func planFile(
        record: TranscriptExportRecord,
        descriptor: ExportFormatDescriptor,
        rendered: RenderedExport,
        destination: ExportDestination? = nil,
        fileSystem: (any ExportFileSystem)? = nil,
        ensureUniqueFilename: Bool = false
    ) throws -> PlannedExportFile {
        var relativePath = try plannedRelativePath(record: record, descriptor: descriptor)
        if ensureUniqueFilename, let destination, let fileSystem {
            relativePath = try uniquedRelativePath(relativePath, destination: destination, fileSystem: fileSystem)
        }

        return PlannedExportFile(
            id: "\(record.exportRecordID)-\(descriptor.id)",
            role: .aggregate(formatID: descriptor.id),
            relativePath: relativePath,
            content: rendered.content,
            format: descriptor,
            contentType: rendered.contentType,
            displayName: descriptor.displayName,
            estimatedByteCount: rendered.content.utf8.count
        )
    }

    public func plannedRelativePath(
        record: TranscriptExportRecord,
        descriptor: ExportFormatDescriptor
    ) throws -> String {
        let profile = configuration.portableProfile
        let template = profile.aggregatePathTemplate(fileExtension: descriptor.fileExtension)
        let variables = ExportPathVariables(date: record.exportDate, values: [
            "filenameBase": filenameBase(for: record),
            "recordID": record.exportRecordID,
            "id": record.exportRecordID,
            "id8": String(record.exportRecordID.prefix(8)),
            "model": record.transcript.modelUsed,
            "language": record.transcript.language,
            "format": descriptor.id
        ])
        return try template.plannedRelativePath(variables: variables, safetyPolicy: safetyPolicy)
    }

    private func uniquedRelativePath(
        _ relativePath: String,
        destination: ExportDestination,
        fileSystem: any ExportFileSystem
    ) throws -> String {
        let baseURL = try destination.resolvedBaseURL(safetyPolicy: safetyPolicy)
        let initialURL = try safetyPolicy.appending(relativePath, to: baseURL, isDirectory: false)
        guard fileSystem.fileExists(at: initialURL) else { return relativePath }

        let nsRelativePath = relativePath as NSString
        let directory = nsRelativePath.deletingLastPathComponent
        let ext = nsRelativePath.pathExtension
        let base = (nsRelativePath.deletingPathExtension as NSString).lastPathComponent

        var index = 2
        while true {
            let filename = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidateRelativePath = directory.isEmpty || directory == "."
                ? filename
                : (directory as NSString).appendingPathComponent(filename)
            let candidateURL = try safetyPolicy.appending(candidateRelativePath, to: baseURL, isDirectory: false)
            if !fileSystem.fileExists(at: candidateURL) {
                return candidateRelativePath
            }
            index += 1
        }
    }
}

public struct TranscriptDestinationWriter {
    public var fileWriter: ExportFileWriter

    public init(fileWriter: ExportFileWriter = ExportFileWriter(fileSystem: FileManagerExportFileSystem())) {
        self.fileWriter = fileWriter
    }

    @discardableResult
    public func write(
        _ file: PlannedExportFile,
        configuration: TranscriptExportConfiguration,
        to destination: ExportDestination
    ) throws -> ExportFileWriteResult {
        try fileWriter.write(
            file,
            to: destination,
            mode: configuration.writeMode,
            mergeStrategy: mergeStrategy(for: configuration)
        )
    }

    private func mergeStrategy(for configuration: TranscriptExportConfiguration) -> (any ExportMergeStrategy)? {
        guard configuration.mode == .append else { return nil }
        if configuration.format == .json {
            return TranscriptJSONAppendMergeStrategy()
        }
        return TranscriptSeparatorAppendMergeStrategy(
            separator: configuration.appendSeparator,
            stripLeadingMarkdownFrontmatterFromNewContent: configuration.format == .md && !configuration.mdObsidianEnabled
        )
    }
}

public struct TranscriptSeparatorAppendMergeStrategy: ExportMergeStrategy, Sendable {
    public var separator: String
    public var stripLeadingMarkdownFrontmatterFromNewContent: Bool

    public init(
        separator: String,
        stripLeadingMarkdownFrontmatterFromNewContent: Bool = false
    ) {
        self.separator = separator
        self.stripLeadingMarkdownFrontmatterFromNewContent = stripLeadingMarkdownFrontmatterFromNewContent
    }

    public func merge(existing: String, new: String, file: PlannedExportFile) throws -> String {
        let contentToAppend = stripLeadingMarkdownFrontmatterFromNewContent
            ? TranscriptFileExporter.exportKitRemovingLeadingMarkdownFrontmatter(from: new)
            : new
        guard !contentToAppend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return existing
        }
        return existing + separator + contentToAppend
    }
}

public struct TranscriptJSONAppendMergeStrategy: ExportMergeStrategy, Sendable {
    public init() {}

    public func merge(existing: String, new: String, file: PlannedExportFile) throws -> String {
        let decoder = JSONDecoder()
        let existingData = Data(existing.utf8)
        let newData = Data(new.utf8)
        var transcripts = try decoder.decode([Transcript].self, from: existingData)
        if let appended = try? decoder.decode([Transcript].self, from: newData) {
            transcripts.append(contentsOf: appended)
        } else {
            transcripts.append(try decoder.decode(Transcript.self, from: newData))
        }
        return try TranscriptFileExporter.exportKitEncodedTranscriptArray(transcripts)
    }
}

public struct TranscriptExportRun {
    public var configuration: TranscriptExportConfiguration
    public var fileSystem: any ExportFileSystem
    public var safetyPolicy: ExportPathSafetyPolicy

    public init(
        configuration: TranscriptExportConfiguration,
        fileSystem: any ExportFileSystem = FileManagerExportFileSystem(),
        safetyPolicy: ExportPathSafetyPolicy = .rejectTraversalAndAbsolutePaths
    ) {
        self.configuration = configuration
        self.fileSystem = fileSystem
        self.safetyPolicy = safetyPolicy
    }

    @discardableResult
    public func export(_ transcript: Transcript, to folderURL: URL) throws -> URL {
        let destination = ExportDestination(rootURL: folderURL)
        let result = try write(TranscriptExportRecord(transcript: transcript), to: destination)
        return result.url
    }

    @discardableResult
    public func write(
        _ record: TranscriptExportRecord,
        to destination: ExportDestination
    ) throws -> ExportFileWriteResult {
        let registry = try TranscriptExportRendererFactory.registry(configuration: configuration)
        let descriptor = try registry.descriptors(for: configuration.selectedFormatIDs)[0]
        let rendered = try registry.render(record: record, formatID: descriptor.id)
        let plan = try TranscriptExportPathPlanner(configuration: configuration, safetyPolicy: safetyPolicy)
            .planFile(
                record: record,
                descriptor: descriptor,
                rendered: rendered,
                destination: destination,
                fileSystem: fileSystem,
                ensureUniqueFilename: configuration.mode == .newFile
            )
        let writer = TranscriptDestinationWriter(
            fileWriter: ExportFileWriter(fileSystem: fileSystem, safetyPolicy: safetyPolicy)
        )
        return try writer.write(plan, configuration: configuration, to: destination)
    }
}

public enum TranscriptExportPreviewFactory {
    public static func buildPreview(
        transcripts: [Transcript],
        configuration: TranscriptExportConfiguration,
        maxRenderedRecords: Int = ExportPreviewBuilder<Transcript, TranscriptExportRecord>.defaultMaxRenderedRecords,
        maxFetchAttempts: Int = ExportPreviewBuilder<Transcript, TranscriptExportRecord>.defaultMaxFetchAttempts
    ) async throws -> ExportPreview {
        let registry = try TranscriptExportRendererFactory.registry(configuration: configuration)
        let dataSource = AnyExportRecordDataSource<Transcript, TranscriptExportRecord> { transcript in
            ExportFetchedRecord(record: TranscriptExportRecord(transcript: transcript))
        }
        let planner = TranscriptExportPathPlanner(configuration: configuration, safetyPolicy: .preserveCurrentBehavior)
        let request = ExportPreviewRequest(
            recordInputs: transcripts,
            selectedFormatIDs: configuration.selectedFormatIDs,
            dataSource: dataSource,
            rendererRegistry: registry,
            recordReference: { transcript in
                ExportRecordReference(
                    id: transcript.id.uuidString.lowercased(),
                    date: transcript.date,
                    displayName: transcript.title ?? String(transcript.text.prefix(32))
                )
            },
            planAggregateFile: { record, descriptor, rendered in
                try planner.planFile(record: record, descriptor: descriptor, rendered: rendered)
            }
        )
        return try await ExportPreviewBuilder<Transcript, TranscriptExportRecord>(
            maxRenderedRecords: maxRenderedRecords,
            maxFetchAttempts: maxFetchAttempts
        ).buildPreview(request)
    }
}

public enum TranscriptExportBatchOrchestrator {
    public static func export(
        transcripts: [Transcript],
        configuration: TranscriptExportConfiguration,
        folderURL: URL,
        onProgress: ((ExportProgress) -> Void)? = nil
    ) async -> ExportRunResult {
        let destination = ExportDestination(rootURL: folderURL)
        let run = TranscriptExportRun(configuration: configuration)
        let dataSource = AnyExportRecordDataSource<Transcript, TranscriptExportRecord> { transcript in
            ExportFetchedRecord(record: TranscriptExportRecord(transcript: transcript))
        }
        let recordWriter = AnyExportRecordWriter<TranscriptExportRecord> { record, _ in
            let result = try run.write(record, to: destination)
            return ExportRecordWriteSummary(filesWritten: result.bytesWritten > 0 ? 1 : 0)
        }
        let orchestrator = ExportRunOrchestrator<Transcript, TranscriptExportRecord>(
            dataSource: dataSource,
            writer: recordWriter,
            failureMapper: { error in
                ExportRunFailure(reason: .writeError, errorDescription: error.localizedDescription)
            }
        )
        let request = ExportRunRequest(
            recordInputs: transcripts,
            formatIDs: configuration.selectedFormatIDs,
            destination: destination,
            writeMode: configuration.writeMode,
            recordReference: { transcript in
                ExportRecordReference(id: transcript.id.uuidString.lowercased(), date: transcript.date)
            }
        )
        return await orchestrator.run(request, onProgress: onProgress)
    }
}
