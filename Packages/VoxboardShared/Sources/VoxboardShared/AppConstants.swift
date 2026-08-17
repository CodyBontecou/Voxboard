import Foundation

/// User-configurable live capture sources that can independently opt into auto-stop.
public enum VoiceAutoStopCapturePath: String, CaseIterable, Codable, Hashable, Sendable {
    case keyboard
    case inAppDraft
    case inAppImmediate
    case quickRecord
    case liveActivity
    case watch
}

/// Shared constants used by both the main app and keyboard extension.
/// The App Group allows sharing files (models, transcripts) and UserDefaults between targets.
public enum AppConstants: Sendable {
    public static let appGroupIdentifier = "group.bontecou.Voxboard"
    public static let modelsDirectoryName = "WhisperModels"
    public static let recordingsDirectoryName = "Recordings"
    public static let recordingJobsDirectoryName = "RecordingJobs"
    public static let captureDirectoryName = "Capture"
    public static let captureLibraryFilename = CaptureLibraryStore.defaultFilename
    public static let captureHistoryFilename = "capture-history-v1.json"
    public static let activityStatsFilename = ActivityStatsStore.defaultFilename
    public static let captureUsageFilename = "capture-usage-v1.json"
    public static let captureUsageMirrorKey = "successfulCaptureDeliveries.v1"
    public static let selectedModelKey = "selectedWhisperModel"
    public static let selectedLanguageKey = "selectedLanguage"
    public static let selectedFallbackModelKey = "selectedFallbackTranscriptionModel"
    public static let externalModelBookmarkKeyPrefix = "externalTranscriptionModelBookmark.v1"
    public static let transcriptionSelectionMigrationKey = "transcriptionSelectionMigration.v1"
    public static let automaticBackendReadyKey = "automaticTranscriptionBackendReady"
    // Keep the existing raw keys so users retain their configured auto-stop behavior.
    public static let voiceAutoStopEnabledKey = "parakeetKeyboardAutoStopEnabled"
    public static let voiceAutoStopPauseDurationKey = "parakeetKeyboardPauseDuration"
    public static let defaultVoiceAutoStopPauseDuration: TimeInterval = 0.75
    public static let minimumVoiceAutoStopPauseDuration: TimeInterval = 0.5
    public static let maximumVoiceAutoStopPauseDuration: TimeInterval = 2.0
    public static let voiceAutoStopCapturePathKeyPrefix = "voiceAutoStop.capturePath"

    #if DEBUG
    public static let debugSharedContainerOverrideEnvironmentKey =
        "VOXBOARD_SHARED_CONTAINER_OVERRIDE"
    #endif

    // Legacy source-compatible aliases.
    public static let parakeetKeyboardAutoStopEnabledKey = voiceAutoStopEnabledKey
    public static let parakeetKeyboardPauseDurationKey = voiceAutoStopPauseDurationKey
    public static let defaultParakeetKeyboardPauseDuration = defaultVoiceAutoStopPauseDuration
    public static let minimumParakeetKeyboardPauseDuration = minimumVoiceAutoStopPauseDuration
    public static let maximumParakeetKeyboardPauseDuration = maximumVoiceAutoStopPauseDuration

    /// Legacy/local model default retained for the macOS app and as a fallback
    /// candidate. The iOS app defaults to the system-first Automatic backend.
    public static let defaultModelName = "ggml-base"

    public static var defaultTranscriptionBackendID: String {
        #if os(iOS)
        return TranscriptionBackendID.automatic
        #else
        return defaultModelName
        #endif
    }

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
        #if DEBUG
        if let overrideURL = debugSharedContainerOverrideURL(
            environment: ProcessInfo.processInfo.environment
        ) {
            try? FileManager.default.createDirectory(
                at: overrideURL,
                withIntermediateDirectories: true
            )
            return overrideURL
        }
        #endif

        if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return appGroupURL
        }

        #if os(macOS)
        // The macOS companion can run unsigned during local development, where
        // App Group containers are unavailable. Fall back to Application Support
        // so transcription history, models, and export settings still work.
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let fallbackURL = applicationSupportURL.appendingPathComponent("Voxboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallbackURL, withIntermediateDirectories: true)
        return fallbackURL
        #else
        return nil
        #endif
    }

    #if DEBUG
    static func debugSharedContainerOverrideURL(
        environment: [String: String]
    ) -> URL? {
        guard let path = environment[debugSharedContainerOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
    #endif

    public static var modelsDirectoryURL: URL? {
        sharedContainerURL?.appendingPathComponent(modelsDirectoryName)
    }

    public static var recordingsDirectoryURL: URL? {
        sharedContainerURL?.appendingPathComponent(recordingsDirectoryName)
    }

    public static var recordingJobsDirectoryURL: URL? {
        recordingsDirectoryURL?.appendingPathComponent(recordingJobsDirectoryName, isDirectory: true)
    }

    public static var captureDirectoryURL: URL? {
        sharedContainerURL?.appendingPathComponent(captureDirectoryName, isDirectory: true)
    }

    public static var captureLibraryURL: URL? {
        captureDirectoryURL?.appendingPathComponent(captureLibraryFilename)
    }

    public static var captureHistoryURL: URL? {
        captureDirectoryURL?.appendingPathComponent(captureHistoryFilename)
    }

    public static var activityStatsURL: URL? {
        captureDirectoryURL?.appendingPathComponent(activityStatsFilename)
    }

    public static var captureUsageURL: URL? {
        captureDirectoryURL?.appendingPathComponent(captureUsageFilename)
    }

    // File export settings
    public static let fileExportEnabledKey = "fileExportEnabled"
    public static let fileExportFormatKey = "fileExportFormat"
    public static let fileExportModeKey = "fileExportMode"
    public static let fileExportBookmarkKey = "fileExportFolderBookmark"
    public static let fileExportYAMLPropertiesKey = "fileExportYAMLProperties"
    public static let fileExportYAMLObsidianBasesKey = "fileExportYAMLObsidianBases"
    public static let fileExportMDObsidianKey = "fileExportMDObsidian"
    public static let fileExportNewFileNameTemplateKey = "fileExportNewFileNameTemplate"
    public static let fileExportAppendFileNameKey = "fileExportAppendFileName"

    // Obsidian-style file template: when enabled and a bookmark is set, the
    // exporter renders each note through `TemplateRenderer` using the chosen
    // template file and writes the result as `.md`.
    public static let fileExportTemplateEnabledKey = "fileExportTemplateEnabled"
    public static let fileExportTemplateBookmarkKey = "fileExportTemplateBookmark"
    public static let fileExportTemplateNameKey = "fileExportTemplateName"

    // Keyboard haptic feedback. Defaults to true when unset.
    public static let hapticsEnabledKey = "hapticsEnabled"

    // In-app interface language override. Unset follows the device language;
    // otherwise an AppLanguage code mirrored into AppleLanguages at launch.
    public static let appLanguageOverrideKey = "appLanguageOverride"

    // Persistent keyboard-listening preference. One-shot recordings deliberately
    // leave this off so the app returns to an idle audio session when done.
    public static let autoListenEnabledKey = "autoListenEnabled"

    // Lock Screen / Dynamic Island controls. Both default to true when unset.
    public static let liveActivityMonitorEnabledKey = "liveActivityMonitorEnabled"
    public static let lockScreenQuickRecordEnabledKey = "lockScreenQuickRecordEnabled"
    public static let pendingWidgetRecordKey = "pendingWidgetRecord"
    public static let pendingWidgetRecordFlowIdKey = "pendingWidgetRecordFlowId"

    // Cross-process Quick Capture launch requests from Shortcuts and controls.
    public static let pendingQuickCaptureOpenKey = "pendingOpenQuickCapture"
    public static let pendingQuickCaptureInputKey = "pendingQuickCaptureInput"
    public static let pendingQuickCaptureSourceKey = "pendingQuickCaptureSource"
    public static let pendingQuickCaptureVoxIdKey = "pendingQuickCaptureVoxId"

    // Smart folder routing (Apple Intelligence routes transcripts to the best folder).
    public static let smartFoldersEnabledKey = "smartFoldersEnabled"
    public static let smartFoldersKey = "smartFolders"

    // Auto-organize (Apple Intelligence generates subfolders under the base export folder).
    public static let autoOrganizeEnabledKey = "autoOrganizeEnabled"

    // Which enrichment fields flow into file exports. Each defaults to true
    // so users who turn enrichment on get the enriched export for free.
    public static let exportUseEnrichedTitleInFilenameKey = "exportUseEnrichedTitleInFilename"
    public static let exportEnrichedFilenameStyleKey = "exportEnrichedFilenameStyle"
    public static let exportUseCleanedTextKey = "exportUseCleanedText"
    public static let exportIncludeTagsKey = "exportIncludeTags"

    public static var hapticsEnabled: Bool {
        boolOrDefault(hapticsEnabledKey, default: true)
    }

    public static var liveActivityMonitorEnabled: Bool {
        boolOrDefault(liveActivityMonitorEnabledKey, default: true)
    }

    public static var lockScreenQuickRecordEnabled: Bool {
        boolOrDefault(lockScreenQuickRecordEnabledKey, default: true)
    }

    /// Live captures may end after locally detected silence when the optional
    /// voice-activity model is installed.
    public static var voiceAutoStopEnabled: Bool {
        get { boolOrDefault(voiceAutoStopEnabledKey, default: true) }
        set { sharedDefaults?.set(newValue, forKey: voiceAutoStopEnabledKey) }
    }

    public static var voiceAutoStopPauseDuration: TimeInterval {
        get {
            guard let defaults = sharedDefaults,
                  defaults.object(forKey: voiceAutoStopPauseDurationKey) != nil else {
                return defaultVoiceAutoStopPauseDuration
            }
            return clampedVoiceAutoStopPauseDuration(
                defaults.double(forKey: voiceAutoStopPauseDurationKey)
            )
        }
        set {
            sharedDefaults?.set(
                clampedVoiceAutoStopPauseDuration(newValue),
                forKey: voiceAutoStopPauseDurationKey
            )
        }
    }

    public static func clampedVoiceAutoStopPauseDuration(
        _ duration: TimeInterval
    ) -> TimeInterval {
        min(
            maximumVoiceAutoStopPauseDuration,
            max(minimumVoiceAutoStopPauseDuration, duration)
        )
    }

    public static func voiceAutoStopCapturePathKey(
        for path: VoiceAutoStopCapturePath
    ) -> String {
        "\(voiceAutoStopCapturePathKeyPrefix).\(path.rawValue).enabled"
    }

    /// The stored path preference without applying the global master switch.
    public static func voiceAutoStopCapturePathEnabled(
        _ path: VoiceAutoStopCapturePath
    ) -> Bool {
        boolOrDefault(voiceAutoStopCapturePathKey(for: path), default: true)
    }

    public static func setVoiceAutoStopCapturePathEnabled(
        _ enabled: Bool,
        for path: VoiceAutoStopCapturePath
    ) {
        sharedDefaults?.set(enabled, forKey: voiceAutoStopCapturePathKey(for: path))
    }

    public static func voiceAutoStopEnabled(
        for path: VoiceAutoStopCapturePath
    ) -> Bool {
        voiceAutoStopEnabled && voiceAutoStopCapturePathEnabled(path)
    }

    public static var parakeetKeyboardAutoStopEnabled: Bool {
        get { voiceAutoStopEnabled }
        set { voiceAutoStopEnabled = newValue }
    }

    public static var parakeetKeyboardPauseDuration: TimeInterval {
        get { voiceAutoStopPauseDuration }
        set { voiceAutoStopPauseDuration = newValue }
    }

    public static func clampedParakeetKeyboardPauseDuration(
        _ duration: TimeInterval
    ) -> TimeInterval {
        clampedVoiceAutoStopPauseDuration(duration)
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
        #if os(macOS)
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) != nil else {
            return .standard
        }
        #endif
        return UserDefaults(suiteName: appGroupIdentifier)
    }

    // MARK: - Smart Folder Routing

    public static var smartFoldersEnabled: Bool {
        boolOrDefault(smartFoldersEnabledKey, default: false)
    }

    public static var autoOrganizeEnabled: Bool {
        boolOrDefault(autoOrganizeEnabledKey, default: false)
    }

    public static func loadSmartFolders() -> [SmartFolder] {
        guard let data = sharedDefaults?.data(forKey: smartFoldersKey),
              let folders = try? JSONDecoder().decode([SmartFolder].self, from: data) else {
            return []
        }
        return folders
    }

    public static func saveSmartFolders(_ folders: [SmartFolder]) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        sharedDefaults?.set(data, forKey: smartFoldersKey)
    }
}
