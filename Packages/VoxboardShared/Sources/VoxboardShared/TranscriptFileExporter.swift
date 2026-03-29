import Foundation

public enum ExportFileFormat: String, Codable, CaseIterable, Sendable {
    case txt, md, json, yaml

    public var fileExtension: String { rawValue }
}

public enum ExportFileMode: String, Codable, CaseIterable, Sendable {
    case append
    case newFile
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
        defaults: UserDefaults? = nil
    ) throws -> URL {
        let fileURL = targetURL(
            for: transcript,
            format: format,
            mode: mode,
            folderURL: folderURL,
            yamlUsesMarkdownExtension: yamlUsesMarkdownExtension,
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
                yamlUsesMarkdownFrontmatter: format == .yaml && yamlUsesMarkdownExtension
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)

        case (_, .append):
            let content = formatContent(
                transcript,
                format: format,
                yamlProperties: yamlProperties,
                yamlUsesMarkdownFrontmatter: format == .yaml && yamlUsesMarkdownExtension
            )
            let separator = (format == .yaml && yamlUsesMarkdownExtension) ? "\n\n" : "\n\n---\n\n"
            try appendText(content, to: fileURL, separator: separator)
        }

        return fileURL
    }

    // MARK: - Text formatting

    private static func formatContent(
        _ transcript: Transcript,
        format: ExportFileFormat,
        yamlProperties: Set<ExportYAMLProperty>,
        yamlUsesMarkdownFrontmatter: Bool
    ) -> String {
        switch format {
        case .txt:
            return transcript.text
        case .md:
            return formatMarkdown(transcript)
        case .yaml:
            return formatYAML(
                transcript,
                properties: yamlProperties,
                wrapsInMarkdownFrontmatter: yamlUsesMarkdownFrontmatter
            )
        case .json:
            fatalError("JSON uses data-based export, not string formatting")
        }
    }

    private static func formatMarkdown(_ transcript: Transcript) -> String {
        let dateString = displayDateFormatter.string(from: transcript.date)
        let durationString = String(format: "%.1fs", transcript.duration)
        return """
        ## Transcript - \(dateString)

        - **Duration**: \(durationString)
        - **Model**: \(transcript.modelUsed)
        - **Language**: \(transcript.language)

        \(transcript.text)
        """
    }

    private static func formatYAML(
        _ transcript: Transcript,
        properties: Set<ExportYAMLProperty>,
        wrapsInMarkdownFrontmatter: Bool
    ) -> String {
        let orderedProperties = ExportYAMLProperty.allCases.filter { properties.contains($0) }

        let yamlBody: String
        if orderedProperties.isEmpty {
            yamlBody = "{}"
        } else {
            var lines: [String] = []
            for property in orderedProperties {
                switch property {
                case .id:
                    lines.append("\(property.yamlKey): \(yamlQuoted(transcript.id.uuidString.lowercased()))")
                case .text:
                    lines.append(contentsOf: yamlTextLines(transcript.text, key: property.yamlKey))
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
            yamlBody = lines.joined(separator: "\n")
        }

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
        defaults: UserDefaults?
    ) -> URL {
        let fileExtension = resolvedFileExtension(for: format, yamlUsesMarkdownExtension: yamlUsesMarkdownExtension)

        switch mode {
        case .newFile:
            let baseName = resolveNewFileBaseName(for: transcript, defaults: defaults)
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

    private static func resolveNewFileBaseName(for transcript: Transcript, defaults: UserDefaults?) -> String {
        let configuredTemplate = defaults?.string(forKey: AppConstants.fileExportNewFileNameTemplateKey)
        let template = nonEmptyTrimmed(configuredTemplate) ?? defaultNewFileNameTemplate
        let rendered = renderTemplate(template, transcript: transcript)
        let fallback = renderTemplate(defaultNewFileNameTemplate, transcript: transcript)
        return sanitizeFilenameBase(rendered, fallback: fallback)
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
            defaults: defaults
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
