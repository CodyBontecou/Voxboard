import Foundation

/// Shared constants used by both the main app and keyboard extension.
/// The App Group allows sharing files (models, transcripts) and UserDefaults between targets.
public enum AppConstants: Sendable {
    public static let appGroupIdentifier = "group.bontecou.VoxVault"
    public static let modelsDirectoryName = "WhisperModels"
    public static let recordingsDirectoryName = "Recordings"
    public static let selectedModelKey = "selectedWhisperModel"
    public static let selectedLanguageKey = "selectedLanguage"
    public static let defaultModelName = "ggml-base"

    public static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    public static var modelsDirectoryURL: URL? {
        sharedContainerURL?.appendingPathComponent(modelsDirectoryName)
    }

    public static var recordingsDirectoryURL: URL? {
        sharedContainerURL?.appendingPathComponent(recordingsDirectoryName)
    }

    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }
}
