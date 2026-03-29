import Foundation

public enum ExportFileFormat: String, Codable, CaseIterable, Sendable {
    case txt, md, json

    public var fileExtension: String { rawValue }
}

public enum ExportFileMode: String, Codable, CaseIterable, Sendable {
    case append
    case newFile
}

public enum TranscriptFileExporter {

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
        folderURL: URL
    ) throws -> URL {
        let fileURL = targetURL(for: transcript, format: format, mode: mode, folderURL: folderURL)

        switch (format, mode) {
        case (.json, .newFile):
            let data = try jsonEncoder.encode(transcript)
            try data.write(to: fileURL)

        case (.json, .append):
            try appendJSON(transcript, to: fileURL)

        case (_, .newFile):
            let content = formatContent(transcript, format: format)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)

        case (_, .append):
            let content = formatContent(transcript, format: format)
            try appendText(content, to: fileURL)
        }

        return fileURL
    }

    // MARK: - Text formatting

    private static func formatContent(_ transcript: Transcript, format: ExportFileFormat) -> String {
        switch format {
        case .txt:
            return transcript.text
        case .md:
            return formatMarkdown(transcript)
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

    // MARK: - File targeting

    private static func targetURL(
        for transcript: Transcript,
        format: ExportFileFormat,
        mode: ExportFileMode,
        folderURL: URL
    ) -> URL {
        switch mode {
        case .newFile:
            let timestamp = dateFormatter.string(from: transcript.date)
            let shortId = transcript.id.uuidString.prefix(8).lowercased()
            return folderURL.appendingPathComponent("voxboard-\(timestamp)-\(shortId).\(format.fileExtension)")
        case .append:
            return folderURL.appendingPathComponent("voxboard-transcripts.\(format.fileExtension)")
        }
    }

    // MARK: - Append helpers

    private static func appendText(_ content: String, to fileURL: URL) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let existing = try String(contentsOf: fileURL, encoding: .utf8)
            let combined = existing + "\n\n---\n\n" + content
            try combined.write(to: fileURL, atomically: true, encoding: .utf8)
        } else {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Convenience: export if settings are enabled

    /// Reads export settings from the given defaults and exports if enabled.
    /// Silently returns if export is disabled or no folder is configured.
    public static func exportIfEnabled(
        _ transcript: Transcript,
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) {
        guard let defaults, defaults.bool(forKey: AppConstants.fileExportEnabledKey) else { return }

        let formatRaw = defaults.string(forKey: AppConstants.fileExportFormatKey) ?? "txt"
        let modeRaw = defaults.string(forKey: AppConstants.fileExportModeKey) ?? "newFile"
        let format = ExportFileFormat(rawValue: formatRaw) ?? .txt
        let mode = ExportFileMode(rawValue: modeRaw) ?? .newFile

        guard let folderURL = resolveBookmark(from: defaults) else { return }

        let needsScoping = folderURL.startAccessingSecurityScopedResource()
        defer { if needsScoping { folderURL.stopAccessingSecurityScopedResource() } }

        try? export(transcript, format: format, mode: mode, folderURL: folderURL)
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
