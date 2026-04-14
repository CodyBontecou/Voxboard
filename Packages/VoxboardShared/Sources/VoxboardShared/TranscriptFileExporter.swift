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
        enrichmentOptions: TranscriptExportEnrichmentOptions = .default,
        defaults: UserDefaults? = nil
    ) throws -> URL {
        let fileURL = targetURL(
            for: transcript,
            format: format,
            mode: mode,
            folderURL: folderURL,
            yamlUsesMarkdownExtension: yamlUsesMarkdownExtension,
            enrichmentOptions: enrichmentOptions,
            defaults: defaults
        )

        switch (format, mode) {
        case (.json, .newFile):
            let data = try jsonEncoder.encode(transcript)
            try data.write(to: fileURL)

        case (.json, .append):
            try appendJSON(transcript, to: fileURL)

        case (_, .newFile):
            let content = formatContent(
                transcript,
                format: format,
                yamlProperties: yamlProperties,
                yamlUsesMarkdownFrontmatter: format == .yaml && yamlUsesMarkdownExtension,
                enrichmentOptions: enrichmentOptions
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)

        case (_, .append):
            let content = formatContent(
                transcript,
                format: format,
                yamlProperties: yamlProperties,
                yamlUsesMarkdownFrontmatter: format == .yaml && yamlUsesMarkdownExtension,
                enrichmentOptions: enrichmentOptions
            )
            let separator = (format == .yaml && yamlUsesMarkdownExtension) ? "\n\n" : "\n\n---\n\n"
            try appendText(content, to: fileURL, separator: separator)
        }

        return fileURL
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
        enrichmentOptions: TranscriptExportEnrichmentOptions
    ) -> String {
        switch format {
        case .txt:
            return formatTxt(transcript, options: enrichmentOptions)
        case .md:
            return formatMarkdown(transcript, options: enrichmentOptions)
        case .yaml:
            return formatYAML(
                transcript,
                properties: yamlProperties,
                wrapsInMarkdownFrontmatter: yamlUsesMarkdownFrontmatter,
                options: enrichmentOptions
            )
        case .json:
            fatalError("JSON uses data-based export, not string formatting")
        }
    }

    private static func formatTxt(
        _ transcript: Transcript,
        options: TranscriptExportEnrichmentOptions
    ) -> String {
        let body = bodyText(transcript, options: options)
        guard let tags = usableTags(transcript, options: options) else {
            return body
        }
        let tagLine = "Tags: " + tags.joined(separator: ", ")
        return body + "\n\n" + tagLine
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

    private static func formatYAML(
        _ transcript: Transcript,
        properties: Set<ExportYAMLProperty>,
        wrapsInMarkdownFrontmatter: Bool,
        options: TranscriptExportEnrichmentOptions
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
        defaults: UserDefaults?
    ) -> URL {
        let fileExtension = resolvedFileExtension(for: format, yamlUsesMarkdownExtension: yamlUsesMarkdownExtension)

        switch mode {
        case .newFile:
            let baseName = resolveNewFileBaseName(
                for: transcript,
                enrichmentOptions: enrichmentOptions,
                defaults: defaults
            )
            let initialURL = folderURL.appendingPathComponent("\(baseName).\(fileExtension)")
            return uniquedURL(initialURL)
        case .append:
            let baseName = resolveAppendFileBaseName(defaults: defaults)
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
        defaults: UserDefaults?
    ) -> String {
        let configuredTemplate = defaults?.string(forKey: AppConstants.fileExportNewFileNameTemplateKey)
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

    private static func resolveAppendFileBaseName(defaults: UserDefaults?) -> String {
        let configured = defaults?.string(forKey: AppConstants.fileExportAppendFileNameKey)
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

    // MARK: - Convenience: export if settings are enabled

    /// Reads export settings from the given defaults and exports if enabled.
    /// Returns the written file URL on success; otherwise nil.
    @discardableResult
    public static func exportIfEnabled(
        _ transcript: Transcript,
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) -> URL? {
        guard let defaults, defaults.bool(forKey: AppConstants.fileExportEnabledKey) else { return nil }

        let formatRaw = defaults.string(forKey: AppConstants.fileExportFormatKey) ?? "txt"
        let modeRaw = defaults.string(forKey: AppConstants.fileExportModeKey) ?? "newFile"
        let format = ExportFileFormat(rawValue: formatRaw) ?? .txt
        let mode = ExportFileMode(rawValue: modeRaw) ?? .newFile
        let yamlProperties = resolveYAMLProperties(from: defaults)
        let yamlUsesMarkdownExtension = resolveYAMLObsidianBasesEnabled(from: defaults)
        let enrichmentOptions = resolveEnrichmentOptions(from: defaults)

        guard let folderURL = resolveBookmark(from: defaults) else { return nil }

        let needsScoping = folderURL.startAccessingSecurityScopedResource()
        defer { if needsScoping { folderURL.stopAccessingSecurityScopedResource() } }

        return try? export(
            transcript,
            format: format,
            mode: mode,
            folderURL: folderURL,
            yamlProperties: yamlProperties,
            yamlUsesMarkdownExtension: yamlUsesMarkdownExtension,
            enrichmentOptions: enrichmentOptions,
            defaults: defaults
        )
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
