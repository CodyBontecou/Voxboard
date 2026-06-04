import Foundation

public enum ExportFileFormat: String, Codable, CaseIterable, Sendable {
    case txt, md, json, yaml

    public var fileExtension: String { rawValue }
}

public enum ExportFileMode: String, Codable, CaseIterable, Sendable {
    case append
    case newFile
}

/// Controls how the AI-generated title is applied to the exported filename.
public enum EnrichedFilenameStyle: String, Codable, CaseIterable, Sendable {
    /// Prepend the title to the template result: `{title}-{template}`.
    case prefix
    /// Use the title as the entire filename, ignoring the template.
    case fullName
}

/// How enrichment (title, tags, cleanedText) flows into an export.
/// All fields default to `true` — callers should construct via
/// `TranscriptExportEnrichmentOptions.default` or read `.fromDefaults`.
public struct TranscriptExportEnrichmentOptions: Sendable, Equatable {
    public var useEnrichedTitleInFilename: Bool
    public var enrichedFilenameStyle: EnrichedFilenameStyle
    public var useCleanedText: Bool
    public var includeTags: Bool

    public init(
        useEnrichedTitleInFilename: Bool,
        enrichedFilenameStyle: EnrichedFilenameStyle = .prefix,
        useCleanedText: Bool,
        includeTags: Bool
    ) {
        self.useEnrichedTitleInFilename = useEnrichedTitleInFilename
        self.enrichedFilenameStyle = enrichedFilenameStyle
        self.useCleanedText = useCleanedText
        self.includeTags = includeTags
    }

    public static let `default` = TranscriptExportEnrichmentOptions(
        useEnrichedTitleInFilename: true,
        enrichedFilenameStyle: .prefix,
        useCleanedText: true,
        includeTags: true
    )

    public static let disabled = TranscriptExportEnrichmentOptions(
        useEnrichedTitleInFilename: false,
        enrichedFilenameStyle: .prefix,
        useCleanedText: false,
        includeTags: false
    )
}

public enum ExportYAMLProperty: String, Codable, CaseIterable, Sendable {
    case id
    case text
    case date
    case duration
    case modelUsed
    case language

    public static let defaultSelection: Set<ExportYAMLProperty> = Set(allCases)

    public var displayName: String {
        switch self {
        case .id:
            return "Identifier"
        case .text:
            return "Text"
        case .date:
            return "Date"
        case .duration:
            return "Duration"
        case .modelUsed:
            return "Model"
        case .language:
            return "Language"
        }
    }

    fileprivate var yamlKey: String {
        switch self {
        case .id:
            return "id"
        case .text:
            return "text"
        case .date:
            return "date"
        case .duration:
            return "duration_seconds"
        case .modelUsed:
            return "model_used"
        case .language:
            return "language"
        }
    }
}

public enum TranscriptFileExporter {

    public static let defaultNewFileNameTemplate = "voxboard-{timestamp}-{id8}"
    public static let defaultAppendFileName = "voxboard-transcripts"

    private static let invalidFilenameCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Export a transcript to a file in the given folder.
    /// Returns the URL of the written file.
    @discardableResult
    public static func export(
        _ transcript: Transcript,
        format: ExportFileFormat,
        mode: ExportFileMode,
        folderURL: URL,
        yamlProperties: Set<ExportYAMLProperty> = ExportYAMLProperty.defaultSelection,
        yamlUsesMarkdownExtension: Bool = false,
        mdObsidianEnabled: Bool = false,
        enrichmentOptions: TranscriptExportEnrichmentOptions = .default,
        staticFrontmatter: [String: String] = [:],
        audioAttachmentRelativePath: String? = nil,
        newFileNameTemplateOverride: String? = nil,
        appendFileNameOverride: String? = nil,
        defaults: UserDefaults? = nil
    ) throws -> URL {
        let configuration = exportKitConfiguration(
            format: format,
            mode: mode,
            yamlProperties: yamlProperties,
            yamlUsesMarkdownExtension: yamlUsesMarkdownExtension,
            mdObsidianEnabled: mdObsidianEnabled,
            enrichmentOptions: enrichmentOptions,
            staticFrontmatter: staticFrontmatter,
            audioAttachmentRelativePath: audioAttachmentRelativePath,
            newFileNameTemplateOverride: newFileNameTemplateOverride,
            appendFileNameOverride: appendFileNameOverride,
            defaults: defaults
        )
        return try TranscriptExportRun(configuration: configuration).export(transcript, to: folderURL)
    }

    // MARK: - Text formatting

    /// The body text chosen for export — cleaned text when enrichment provided
    /// one and the user has that option enabled, otherwise the raw transcript.
    private static func bodyText(
        _ transcript: Transcript,
        options: TranscriptExportEnrichmentOptions
    ) -> String {
        if options.useCleanedText, let cleaned = transcript.cleanedText, !cleaned.isEmpty {
            return cleaned
        }
        return transcript.text
    }

    /// Non-nil, non-empty tags array the user wants in the export, or nil.
    private static func usableTags(
        _ transcript: Transcript,
        options: TranscriptExportEnrichmentOptions
    ) -> [String]? {
        guard options.includeTags,
              let tags = transcript.tags,
              !tags.isEmpty else {
            return nil
        }
        return tags
    }

    private static func formatContent(
        _ transcript: Transcript,
        format: ExportFileFormat,
        yamlProperties: Set<ExportYAMLProperty>,
        yamlUsesMarkdownFrontmatter: Bool,
        mdObsidianEnabled: Bool = false,
        enrichmentOptions: TranscriptExportEnrichmentOptions,
        staticFrontmatter: [String: String],
        audioAttachmentRelativePath: String?
    ) -> String {
        let frontmatter = resolvedFrontmatter(
            transcript,
            options: enrichmentOptions,
            staticFrontmatter: staticFrontmatter,
            audioAttachmentRelativePath: audioAttachmentRelativePath
        )

        switch format {
        case .txt:
            return formatTxt(transcript, options: enrichmentOptions, audioAttachmentRelativePath: audioAttachmentRelativePath)
        case .md:
            if mdObsidianEnabled {
                return formatYAML(
                    transcript,
                    properties: ExportYAMLProperty.defaultSelection,
                    wrapsInMarkdownFrontmatter: true,
                    options: enrichmentOptions,
                    frontmatter: frontmatter
                )
            }
            return applyMarkdownFrontmatter(
                to: formatMarkdown(transcript, options: enrichmentOptions),
                frontmatter: frontmatter
            )
        case .yaml:
            return formatYAML(
                transcript,
                properties: yamlProperties,
                wrapsInMarkdownFrontmatter: yamlUsesMarkdownFrontmatter,
                options: enrichmentOptions,
                frontmatter: frontmatter
            )
        case .json:
            fatalError("JSON uses data-based export, not string formatting")
        }
    }

    private static func formatTxt(
        _ transcript: Transcript,
        options: TranscriptExportEnrichmentOptions,
        audioAttachmentRelativePath: String?
    ) -> String {
        let body = bodyText(transcript, options: options)
        var lines: [String] = [body]
        if let tags = usableTags(transcript, options: options) {
            lines.append("Tags: " + tags.joined(separator: ", "))
        }
        if let audioAttachmentRelativePath, !audioAttachmentRelativePath.isEmpty {
            lines.append("Audio: " + audioAttachmentRelativePath)
        }
        return lines.joined(separator: "\n\n")
    }

    private static func formatMarkdown(
        _ transcript: Transcript,
        options: TranscriptExportEnrichmentOptions
    ) -> String {
        let dateString = displayDateFormatter.string(from: transcript.date)
        let durationString = String(format: "%.1fs", transcript.duration)
        let body = bodyText(transcript, options: options)
        var result = """
        ## Transcript - \(dateString)

        - **Duration**: \(durationString)
        - **Model**: \(transcript.modelUsed)
        - **Language**: \(transcript.language)

        \(body)
        """
        if let tags = usableTags(transcript, options: options) {
            let hashtags = tags.map { "#\(sanitizeHashtag($0))" }.joined(separator: " ")
            result += "\n\n" + hashtags
        }
        return result
    }

    private static func sanitizeHashtag(_ tag: String) -> String {
        let lowered = tag.lowercased()
        let replaced = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return "-"
        }
        return String(replaced)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func resolvedFrontmatter(
        _ transcript: Transcript,
        options: TranscriptExportEnrichmentOptions,
        staticFrontmatter: [String: String],
        audioAttachmentRelativePath: String?
    ) -> [String: String] {
        var fm = staticFrontmatter
        if let title = transcript.title, !title.isEmpty, fm["title"] == nil {
            fm["title"] = title
        }
        if let category = transcript.category, !category.isEmpty, fm["category"] == nil {
            fm["category"] = category
        }
        if let tags = usableTags(transcript, options: options), !tags.isEmpty {
            let merged = TranscriptFlowFormatter.mergeTags(tags, parseFrontmatterTags(fm["tags"]))
            fm["tags"] = "[" + merged.map { yamlQuoted($0) }.joined(separator: ", ") + "]"
        }
        if let audioAttachmentRelativePath, !audioAttachmentRelativePath.isEmpty {
            fm["audio"] = audioAttachmentRelativePath
        }
        return fm.filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func parseFrontmatterTags(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .split { $0 == "," || $0 == " " || $0 == "#" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func applyMarkdownFrontmatter(to markdown: String, frontmatter: [String: String]) -> String {
        guard !frontmatter.isEmpty else { return markdown }
        let lines = frontmatterLines(frontmatter)
        guard !lines.isEmpty else { return markdown }
        let block = "---\n" + lines.joined(separator: "\n") + "\n---"

        if markdown.hasPrefix("---\n"), let closeRange = markdown.range(of: "\n---", options: [], range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex) {
            var result = markdown
            result.insert(contentsOf: "\n" + lines.joined(separator: "\n"), at: closeRange.lowerBound)
            return result
        }
        return block + "\n\n" + markdown
    }

    private static func frontmatterLines(_ frontmatter: [String: String]) -> [String] {
        frontmatter
            .sorted(by: { $0.key < $1.key })
            .map { "\(sanitizeYAMLKey($0.key)): \(yamlFrontmatterValue($0.value))" }
    }

    private static func sanitizeYAMLKey(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let key = raw.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return key.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func yamlFrontmatterValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "\"\"" }
        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) ||
            trimmed == "true" || trimmed == "false" ||
            Double(trimmed) != nil {
            return trimmed
        }
        return yamlQuoted(trimmed)
    }

    private static func formatYAML(
        _ transcript: Transcript,
        properties: Set<ExportYAMLProperty>,
        wrapsInMarkdownFrontmatter: Bool,
        options: TranscriptExportEnrichmentOptions,
        frontmatter: [String: String] = [:]
    ) -> String {
        let orderedProperties = ExportYAMLProperty.allCases.filter { properties.contains($0) }
        let exportedText = bodyText(transcript, options: options)

        var lines: [String] = []
        for property in orderedProperties {
            switch property {
            case .id:
                lines.append("\(property.yamlKey): \(yamlQuoted(transcript.id.uuidString.lowercased()))")
            case .text:
                lines.append(contentsOf: yamlTextLines(exportedText, key: property.yamlKey))
            case .date:
                let date = isoDateFormatter.string(from: transcript.date)
                lines.append("\(property.yamlKey): \(yamlQuoted(date))")
            case .duration:
                lines.append("\(property.yamlKey): \(String(format: "%.3f", transcript.duration))")
            case .modelUsed:
                lines.append("\(property.yamlKey): \(yamlQuoted(transcript.modelUsed))")
            case .language:
                lines.append("\(property.yamlKey): \(yamlQuoted(transcript.language))")
            }
        }

        if let tags = usableTags(transcript, options: options) {
            let joined = tags.map { yamlQuoted($0) }.joined(separator: ", ")
            lines.append("tags: [\(joined)]")
        }

        for (key, value) in frontmatter.sorted(by: { $0.key < $1.key }) where !key.isEmpty && key != "tags" {
            lines.append("\(sanitizeYAMLKey(key)): \(yamlFrontmatterValue(value))")
        }

        let yamlBody = lines.isEmpty ? "{}" : lines.joined(separator: "\n")

        guard wrapsInMarkdownFrontmatter else { return yamlBody }
        return "---\n\(yamlBody)\n---"
    }

    private static func yamlTextLines(_ text: String, key: String) -> [String] {
        if text.isEmpty {
            return ["\(key): \"\""]
        }

        let rows = text.components(separatedBy: .newlines)
        var lines = ["\(key): |-"]
        lines.append(contentsOf: rows.map { "  \($0)" })
        return lines
    }

    private static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    // MARK: - File targeting

    private static func targetURL(
        for transcript: Transcript,
        format: ExportFileFormat,
        mode: ExportFileMode,
        folderURL: URL,
        yamlUsesMarkdownExtension: Bool,
        enrichmentOptions: TranscriptExportEnrichmentOptions,
        newFileNameTemplateOverride: String? = nil,
        appendFileNameOverride: String? = nil,
        defaults: UserDefaults?
    ) -> URL {
        let fileExtension = resolvedFileExtension(for: format, yamlUsesMarkdownExtension: yamlUsesMarkdownExtension)

        switch mode {
        case .newFile:
            let baseName = resolveNewFileBaseName(
                for: transcript,
                enrichmentOptions: enrichmentOptions,
                templateOverride: newFileNameTemplateOverride,
                defaults: defaults
            )
            let initialURL = folderURL.appendingPathComponent("\(baseName).\(fileExtension)")
            return uniquedURL(initialURL)
        case .append:
            let baseName = resolveAppendFileBaseName(templateOverride: appendFileNameOverride, defaults: defaults)
            return folderURL.appendingPathComponent("\(baseName).\(fileExtension)")
        }
    }

    private static func resolvedFileExtension(
        for format: ExportFileFormat,
        yamlUsesMarkdownExtension: Bool
    ) -> String {
        if format == .yaml, yamlUsesMarkdownExtension {
            return ExportFileFormat.md.fileExtension
        }
        return format.fileExtension
    }

    private static func resolveNewFileBaseName(
        for transcript: Transcript,
        enrichmentOptions: TranscriptExportEnrichmentOptions,
        templateOverride: String? = nil,
        defaults: UserDefaults?
    ) -> String {
        let configuredTemplate = templateOverride ?? defaults?.string(forKey: AppConstants.fileExportNewFileNameTemplateKey)
        let template = nonEmptyTrimmed(configuredTemplate) ?? defaultNewFileNameTemplate
        let rendered = renderTemplate(template, transcript: transcript)
        let fallback = renderTemplate(defaultNewFileNameTemplate, transcript: transcript)
        let templateBase = sanitizeFilenameBase(rendered, fallback: fallback)

        // If the user wants the enriched title in the filename and it is
        // available, apply it according to the chosen style.
        if enrichmentOptions.useEnrichedTitleInFilename,
           let title = nonEmptyTrimmed(transcript.title) {
            let sanitizedTitle = sanitizeFilenameBase(title, fallback: "")
            if !sanitizedTitle.isEmpty {
                switch enrichmentOptions.enrichedFilenameStyle {
                case .prefix:
                    // Prepend the title to the template so files stay unique
                    // even when two recordings produce the same title.
                    return "\(sanitizedTitle)-\(templateBase)"
                case .fullName:
                    // Use the title as the entire filename.
                    return sanitizedTitle
                }
            }
        }
        return templateBase
    }

    private static func resolveAppendFileBaseName(templateOverride: String? = nil, defaults: UserDefaults?) -> String {
        let configured = templateOverride ?? defaults?.string(forKey: AppConstants.fileExportAppendFileNameKey)
        return sanitizeFilenameBase(configured ?? defaultAppendFileName, fallback: defaultAppendFileName)
    }

    private static func renderTemplate(_ template: String, transcript: Transcript) -> String {
        let timestamp = dateFormatter.string(from: transcript.date)
        let date = String(timestamp.prefix(10))
        let time = String(timestamp.suffix(6))
        let id = transcript.id.uuidString.lowercased()
        let id8 = String(id.prefix(8))

        return template
            .replacingOccurrences(of: "{timestamp}", with: timestamp)
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "{id}", with: id)
            .replacingOccurrences(of: "{id8}", with: id8)
            .replacingOccurrences(of: "{model}", with: transcript.modelUsed)
            .replacingOccurrences(of: "{language}", with: transcript.language)
    }

    private static func sanitizeFilenameBase(_ raw: String, fallback: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let nsString = trimmed as NSString
            let ext = nsString.pathExtension
            if !ext.isEmpty {
                trimmed = nsString.deletingPathExtension
            }
        }

        let replacedScalars = trimmed.unicodeScalars.map { scalar -> String in
            if invalidFilenameCharacters.contains(scalar) {
                return "-"
            }
            return String(scalar)
        }

        let cleaned = replacedScalars
            .joined()
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))

        return nonEmptyTrimmed(cleaned) ?? fallback
    }

    private static func uniquedURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent

        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base)-\(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Append helpers

    private static func appendText(_ content: String, to fileURL: URL, separator: String) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let existing = try String(contentsOf: fileURL, encoding: .utf8)
            let combined = existing + separator + content
            try combined.write(to: fileURL, atomically: true, encoding: .utf8)
        } else {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - ExportKit adapter seams

    static func exportKitConfiguration(
        format: ExportFileFormat,
        mode: ExportFileMode,
        yamlProperties: Set<ExportYAMLProperty>,
        yamlUsesMarkdownExtension: Bool,
        mdObsidianEnabled: Bool,
        enrichmentOptions: TranscriptExportEnrichmentOptions,
        staticFrontmatter: [String: String],
        audioAttachmentRelativePath: String?,
        newFileNameTemplateOverride: String?,
        appendFileNameOverride: String?,
        markdownTemplateContent: String? = nil,
        defaults: UserDefaults?
    ) -> TranscriptExportConfiguration {
        let configuredNewFileTemplate = newFileNameTemplateOverride ?? defaults?.string(forKey: AppConstants.fileExportNewFileNameTemplateKey)
        let configuredAppendFileName = appendFileNameOverride ?? defaults?.string(forKey: AppConstants.fileExportAppendFileNameKey)
        return TranscriptExportConfiguration(
            format: format,
            mode: mode,
            yamlProperties: yamlProperties,
            yamlUsesMarkdownExtension: yamlUsesMarkdownExtension,
            mdObsidianEnabled: mdObsidianEnabled,
            enrichmentOptions: enrichmentOptions,
            staticFrontmatter: staticFrontmatter,
            audioAttachmentRelativePath: audioAttachmentRelativePath,
            newFileNameTemplate: nonEmptyTrimmed(configuredNewFileTemplate) ?? defaultNewFileNameTemplate,
            appendFileName: nonEmptyTrimmed(configuredAppendFileName) ?? defaultAppendFileName,
            markdownTemplateContent: markdownTemplateContent
        )
    }

    static func exportKitRenderedContent(
        _ transcript: Transcript,
        configuration: TranscriptExportConfiguration
    ) throws -> String {
        if configuration.format == .json {
            if configuration.mode == .append {
                return try exportKitEncodedTranscriptArray([transcript])
            }
            let data = try jsonEncoder.encode(transcript)
            return String(decoding: data, as: UTF8.self)
        }

        if let templateContent = configuration.markdownTemplateContent {
            return applyMarkdownFrontmatter(
                to: TemplateRenderer.render(
                    template: templateContent,
                    context: TemplateRenderer.Context(transcript: transcript)
                ),
                frontmatter: resolvedFrontmatter(
                    transcript,
                    options: configuration.enrichmentOptions,
                    staticFrontmatter: configuration.staticFrontmatter,
                    audioAttachmentRelativePath: configuration.audioAttachmentRelativePath
                )
            )
        }

        return formatContent(
            transcript,
            format: configuration.format,
            yamlProperties: configuration.yamlProperties,
            yamlUsesMarkdownFrontmatter: configuration.format == .yaml && configuration.yamlUsesMarkdownExtension,
            mdObsidianEnabled: configuration.mdObsidianEnabled,
            enrichmentOptions: configuration.enrichmentOptions,
            staticFrontmatter: configuration.staticFrontmatter,
            audioAttachmentRelativePath: configuration.audioAttachmentRelativePath
        )
    }

    static func exportKitResolvedNewFileBaseName(
        for transcript: Transcript,
        enrichmentOptions: TranscriptExportEnrichmentOptions,
        template: String
    ) -> String {
        resolveNewFileBaseName(
            for: transcript,
            enrichmentOptions: enrichmentOptions,
            templateOverride: template,
            defaults: nil
        )
    }

    static func exportKitResolvedAppendFileBaseName(template: String) -> String {
        resolveAppendFileBaseName(templateOverride: template, defaults: nil)
    }

    static func exportKitEncodedTranscriptArray(_ transcripts: [Transcript]) throws -> String {
        let data = try jsonEncoder.encode(transcripts)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Convenience: export if settings are enabled

    /// Reads export settings from the given defaults and exports if enabled.
    ///
    /// - `folderURLOverride`: A security-scoped URL from a smart folder bookmark.
    ///   When provided, this URL is used directly as the destination.
    /// - `autoOrganizeSubfolder`: A subfolder name generated by Apple Intelligence.
    ///   When provided, the subfolder is created under the base export folder (within
    ///   the base folder's security scope) and used as the destination.
    ///   `folderURLOverride` takes priority when both are supplied.
    ///
    /// Returns the written file URL on success; otherwise nil.
    @discardableResult
    public static func exportIfEnabled(
        _ transcript: Transcript,
        folderURLOverride: URL? = nil,
        autoOrganizeSubfolder: String? = nil,
        flow: RecordingFlow? = nil,
        audioAttachmentRelativePath: String? = nil,
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) -> URL? {
        guard let defaults else { return nil }

        let custom = (flow?.exportSettings.usesCustomExportSettings == true) ? flow?.exportSettings : nil
        let exportEnabled = custom?.exportEnabled ?? defaults.bool(forKey: AppConstants.fileExportEnabledKey)
        guard exportEnabled else { return nil }

        let format: ExportFileFormat
        let mode: ExportFileMode
        let yamlProperties: Set<ExportYAMLProperty>
        let yamlUsesMarkdownExtension: Bool
        let mdObsidianEnabled: Bool
        let templateURL: URL?
        let newFileNameTemplateOverride: String?
        let appendFileNameOverride: String?

        if let custom {
            format = custom.format
            mode = custom.mode
            yamlProperties = custom.yamlProperties
            yamlUsesMarkdownExtension = custom.yamlUsesMarkdownExtension
            mdObsidianEnabled = custom.mdObsidianEnabled
            templateURL = custom.markdownTemplateEnabled ? resolveBookmarkData(custom.markdownTemplateBookmark) : nil
            newFileNameTemplateOverride = custom.newFileNameTemplate
            appendFileNameOverride = custom.appendFileName
        } else {
            let formatRaw = defaults.string(forKey: AppConstants.fileExportFormatKey) ?? "txt"
            let modeRaw = defaults.string(forKey: AppConstants.fileExportModeKey) ?? "newFile"
            format = ExportFileFormat(rawValue: formatRaw) ?? .txt
            mode = ExportFileMode(rawValue: modeRaw) ?? .newFile
            yamlProperties = resolveYAMLProperties(from: defaults)
            yamlUsesMarkdownExtension = resolveYAMLObsidianBasesEnabled(from: defaults)
            mdObsidianEnabled = resolveMDObsidianEnabled(from: defaults)
            let templateEnabled = defaults.bool(forKey: AppConstants.fileExportTemplateEnabledKey)
            templateURL = templateEnabled ? resolveTemplateBookmark(from: defaults) : nil
            newFileNameTemplateOverride = nil
            appendFileNameOverride = nil
        }

        var enrichmentOptions = resolveEnrichmentOptions(from: defaults)
        if flow != nil {
            enrichmentOptions.useCleanedText = true
            enrichmentOptions.includeTags = true
        }
        let staticFrontmatter = flow?.staticFrontmatter ?? [:]

        func write(to folderURL: URL) -> URL? {
            if let templateURL {
                return try? exportViaTemplate(
                    transcript,
                    templateURL: templateURL,
                    folderURL: folderURL,
                    enrichmentOptions: enrichmentOptions,
                    staticFrontmatter: staticFrontmatter,
                    audioAttachmentRelativePath: audioAttachmentRelativePath,
                    newFileNameTemplateOverride: newFileNameTemplateOverride,
                    defaults: defaults
                )
            }
            return try? export(
                transcript,
                format: format,
                mode: mode,
                folderURL: folderURL,
                yamlProperties: yamlProperties,
                yamlUsesMarkdownExtension: yamlUsesMarkdownExtension,
                mdObsidianEnabled: mdObsidianEnabled,
                enrichmentOptions: enrichmentOptions,
                staticFrontmatter: staticFrontmatter,
                audioAttachmentRelativePath: audioAttachmentRelativePath,
                newFileNameTemplateOverride: newFileNameTemplateOverride,
                appendFileNameOverride: appendFileNameOverride,
                defaults: defaults
            )
        }

        // Smart folder override — URL carries its own security scope from a bookmark.
        if let override = folderURLOverride {
            let needsScoping = override.startAccessingSecurityScopedResource()
            defer { if needsScoping { override.stopAccessingSecurityScopedResource() } }
            return write(to: override)
        }

        // Base export folder — required for both auto-organize and the default path.
        let baseURL: URL?
        if let custom {
            baseURL = resolveBookmarkData(custom.folderBookmark)
        } else {
            baseURL = resolveBookmark(from: defaults)
        }
        guard let baseURL else { return nil }
        let needsBaseScoping = baseURL.startAccessingSecurityScopedResource()
        defer { if needsBaseScoping { baseURL.stopAccessingSecurityScopedResource() } }

        // Auto-organize: create subfolder under base (inherits base security scope).
        if let subfolderName = autoOrganizeSubfolder, !subfolderName.isEmpty {
            let subfolderURL = baseURL.appendingPathComponent(subfolderName)
            try? FileManager.default.createDirectory(at: subfolderURL, withIntermediateDirectories: true)
            return write(to: subfolderURL)
        }

        // Default: export directly to the base folder.
        return write(to: baseURL)
    }

    /// Add an audio attachment reference to an already-exported transcript file.
    /// Used after M4A/WAV attachment export succeeds and the final relative path
    /// is known. Markdown files receive/update YAML frontmatter; YAML files get
    /// an `audio` property; TXT files get a short trailing reference.
    public static func attachAudioReference(to transcriptFileURL: URL, relativePath: String) throws {
        guard !relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let ext = transcriptFileURL.pathExtension.lowercased()
        let existing = (try? String(contentsOf: transcriptFileURL, encoding: .utf8)) ?? ""
        let updated: String
        switch ext {
        case "md", "markdown":
            updated = applyMarkdownFrontmatter(to: existing, frontmatter: ["audio": relativePath])
        case "yaml", "yml":
            updated = existing + (existing.hasSuffix("\n") ? "" : "\n") + "audio: \(yamlQuoted(relativePath))\n"
        case "txt":
            updated = existing + "\n\nAudio: \(relativePath)"
        default:
            return
        }
        try updated.write(to: transcriptFileURL, atomically: true, encoding: .utf8)
    }

    /// Render the transcript through the chosen template file and write the
    /// result as `.md` (new-file mode) into `folderURL`. The template file is
    /// opened with its own security scope.
    @discardableResult
    public static func exportViaTemplate(
        _ transcript: Transcript,
        templateURL: URL,
        folderURL: URL,
        enrichmentOptions: TranscriptExportEnrichmentOptions = .default,
        staticFrontmatter: [String: String] = [:],
        audioAttachmentRelativePath: String? = nil,
        newFileNameTemplateOverride: String? = nil,
        defaults: UserDefaults? = nil
    ) throws -> URL {
        let needsScope = templateURL.startAccessingSecurityScopedResource()
        defer { if needsScope { templateURL.stopAccessingSecurityScopedResource() } }

        let templateContent = try String(contentsOf: templateURL, encoding: .utf8)
        let configuration = exportKitConfiguration(
            format: .md,
            mode: .newFile,
            yamlProperties: ExportYAMLProperty.defaultSelection,
            yamlUsesMarkdownExtension: false,
            mdObsidianEnabled: false,
            enrichmentOptions: enrichmentOptions,
            staticFrontmatter: staticFrontmatter,
            audioAttachmentRelativePath: audioAttachmentRelativePath,
            newFileNameTemplateOverride: newFileNameTemplateOverride,
            appendFileNameOverride: nil,
            markdownTemplateContent: templateContent,
            defaults: defaults
        )
        return try TranscriptExportRun(configuration: configuration).export(transcript, to: folderURL)
    }

    /// Returns the security-scoped URL for the configured export folder, or nil
    /// when no bookmark has been saved. Used by callers (e.g. auto-organize) that
    /// need to inspect the folder's contents before exporting.
    public static func resolveExportFolderURL(
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) -> URL? {
        guard let defaults else { return nil }
        return resolveBookmark(from: defaults)
    }

    /// Reads per-field enrichment toggles. When the master enrichment toggle is
    /// off we force the "disabled" options — there won't be enrichment data
    /// anyway, but this avoids any chance of partial enrichment leaking into
    /// the filename or body.
    private static func resolveEnrichmentOptions(from defaults: UserDefaults) -> TranscriptExportEnrichmentOptions {
        guard AppConstants.enrichmentEnabled else { return .disabled }
        return TranscriptExportEnrichmentOptions(
            useEnrichedTitleInFilename: AppConstants.exportUseEnrichedTitleInFilename,
            enrichedFilenameStyle: AppConstants.exportEnrichedFilenameStyle,
            useCleanedText: AppConstants.exportUseCleanedText,
            includeTags: AppConstants.exportIncludeTags
        )
    }

    private static func resolveBookmarkData(_ bookmarkData: Data?) -> URL? {
        guard let bookmarkData else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
    }

    /// Resolve security-scoped bookmark from UserDefaults.
    private static func resolveBookmark(from defaults: UserDefaults) -> URL? {
        guard let bookmarkData = defaults.data(forKey: AppConstants.fileExportBookmarkKey) else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        if isStale {
            if let newData = try? url.bookmarkData() {
                defaults.set(newData, forKey: AppConstants.fileExportBookmarkKey)
            }
        }
        return url
    }

    private static func resolveYAMLProperties(from defaults: UserDefaults) -> Set<ExportYAMLProperty> {
        guard let rawValues = defaults.array(forKey: AppConstants.fileExportYAMLPropertiesKey) as? [String] else {
            return ExportYAMLProperty.defaultSelection
        }
        let parsed = Set(rawValues.compactMap(ExportYAMLProperty.init(rawValue:)))
        return parsed.isEmpty ? ExportYAMLProperty.defaultSelection : parsed
    }

    private static func resolveYAMLObsidianBasesEnabled(from defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: AppConstants.fileExportYAMLObsidianBasesKey)
    }

    private static func resolveTemplateBookmark(from defaults: UserDefaults) -> URL? {
        guard let bookmarkData = defaults.data(forKey: AppConstants.fileExportTemplateBookmarkKey) else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        if isStale, let newData = try? url.bookmarkData() {
            defaults.set(newData, forKey: AppConstants.fileExportTemplateBookmarkKey)
        }
        return url
    }

    private static func resolveMDObsidianEnabled(from defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: AppConstants.fileExportMDObsidianKey)
    }

    private static func appendJSON(_ transcript: Transcript, to fileURL: URL) throws {
        var transcripts: [Transcript]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            transcripts = try JSONDecoder().decode([Transcript].self, from: data)
        } else {
            transcripts = []
        }
        transcripts.append(transcript)
        let data = try jsonEncoder.encode(transcripts)
        try data.write(to: fileURL)
    }
}
