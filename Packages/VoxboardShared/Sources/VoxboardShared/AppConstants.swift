import Foundation

/// Shared constants used by both the main app and keyboard extension.
/// The App Group allows sharing files (models, transcripts) and UserDefaults between targets.
public enum AppConstants: Sendable {
    public static let appGroupIdentifier = "group.bontecou.Voxboard"
    public static let modelsDirectoryName = "WhisperModels"
    public static let recordingsDirectoryName = "Recordings"
    public static let selectedModelKey = "selectedWhisperModel"
    public static let selectedLanguageKey = "selectedLanguage"
    public static let defaultModelName = "ggml-base"

    /// URL scheme used by the keyboard extension to open the main app for recording.
    public static let urlScheme = "voxboard"

    /// Build a URL to open the main app's recording flow from the keyboard.
    public static func recordURL(modelId: String, language: String, requestId: String) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "record"
        components.queryItems = [
            URLQueryItem(name: "model", value: modelId),
            URLQueryItem(name: "lang", value: language),
            URLQueryItem(name: "requestId", value: requestId),
        ]
        return components.url
    }

    public static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    public static var modelsDirectoryURL: URL? {
        sharedContainerURL?.appendingPathComponent(modelsDirectoryName)
    }

    public static var recordingsDirectoryURL: URL? {
        sharedContainerURL?.appendingPathComponent(recordingsDirectoryName)
    }

    // File export settings
    public static let fileExportEnabledKey = "fileExportEnabled"
    public static let fileExportFormatKey = "fileExportFormat"
    public static let fileExportModeKey = "fileExportMode"
    public static let fileExportBookmarkKey = "fileExportFolderBookmark"
    public static let fileExportYAMLPropertiesKey = "fileExportYAMLProperties"
    public static let fileExportYAMLObsidianBasesKey = "fileExportYAMLObsidianBases"
    public static let fileExportNewFileNameTemplateKey = "fileExportNewFileNameTemplate"
    public static let fileExportAppendFileNameKey = "fileExportAppendFileName"

    // On-device LLM enrichment (Apple Intelligence) toggle.
    // Defaults to true when unset — see `enrichmentEnabled` accessor below.
    public static let enrichmentEnabledKey = "enrichmentEnabled"

    // Which enrichment fields flow into file exports. Each defaults to true
    // so users who turn enrichment on get the enriched export for free.
    public static let exportUseEnrichedTitleInFilenameKey = "exportUseEnrichedTitleInFilename"
    public static let exportEnrichedFilenameStyleKey = "exportEnrichedFilenameStyle"
    public static let exportUseCleanedTextKey = "exportUseCleanedText"
    public static let exportIncludeTagsKey = "exportIncludeTags"

    /// Whether on-device LLM enrichment should run after transcription.
    /// Defaults to `true` when the user has never flipped the toggle, so the
    /// feature is opt-out rather than opt-in.
    public static var enrichmentEnabled: Bool {
        boolOrDefault(enrichmentEnabledKey, default: true)
    }

    public static var exportUseEnrichedTitleInFilename: Bool {
        boolOrDefault(exportUseEnrichedTitleInFilenameKey, default: true)
    }

    public static var exportEnrichedFilenameStyle: EnrichedFilenameStyle {
        guard let raw = sharedDefaults?.string(forKey: exportEnrichedFilenameStyleKey) else { return .prefix }
        return EnrichedFilenameStyle(rawValue: raw) ?? .prefix
    }

    public static var exportUseCleanedText: Bool {
        boolOrDefault(exportUseCleanedTextKey, default: true)
    }

    public static var exportIncludeTags: Bool {
        boolOrDefault(exportIncludeTagsKey, default: true)
    }

    private static func boolOrDefault(_ key: String, default defaultValue: Bool) -> Bool {
        guard let defaults = sharedDefaults else { return defaultValue }
        if defaults.object(forKey: key) == nil { return defaultValue }
        return defaults.bool(forKey: key)
    }

    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }
}
