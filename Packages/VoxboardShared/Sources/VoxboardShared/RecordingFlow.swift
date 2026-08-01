import Darwin
import Foundation
import VoxboardCaptureCore

/// The persisted Capture Preset model. Its policy applies to every input
/// modality, while export and audio-retention fields preserve recording-specific
/// behavior and compatibility with older installs.
public struct CapturePreset: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbolName: String
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var kind: CapturePresetKind
    public var exportSettings: CapturePresetExportSettings
    public var staticFrontmatter: [String: String]
    public var metadataScope: CapturePresetMetadataScope
    public var postProcessingMode: CapturePresetProcessingMode
    public var customPostProcessingInstruction: String
    /// Opt-in for a second, fully on-device pass that labels anonymous
    /// speakers in voice recordings. Existing presets decode as disabled.
    public var speakerDiarizationEnabled: Bool
    /// Opt-in for applying this preset’s processing mode to typed and
    /// multimodal Capture text. Existing records decode as false to avoid
    /// rewriting Markdown.
    public var captureProcessingEnabled: Bool
    /// Optional local prompt shown in an empty Capture composer.
    public var capturePrompt: String
    /// Controls whether Apple Watch recordings are transcribed or delivered as
    /// standalone audio files. Other Capture inputs continue using this preset's
    /// normal processing and destination policy.
    public var watchOutputMode: CapturePresetWatchOutputMode
    public var watchRecordingSettings: CapturePresetWatchRecordingSettings
    public var audioSaveMode: CapturePresetAudioSaveMode
    public var attachmentsFolderName: String
    /// The Markdown destination owned by this preset. Nil means the preset
    /// still needs destination setup; the old library default remains only as
    /// a migration fallback.
    public var captureDestinationID: UUID?
    public var captureEntryTemplateID: UUID?
    public var capturePlacementOverride: CapturePlacement?

    public init(
        id: String,
        name: String,
        symbolName: String,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        kind: CapturePresetKind = .custom,
        exportSettings: CapturePresetExportSettings = CapturePresetExportSettings(),
        staticFrontmatter: [String: String] = [:],
        metadataScope: CapturePresetMetadataScope = .document,
        postProcessingMode: CapturePresetProcessingMode = .clean,
        customPostProcessingInstruction: String = "",
        speakerDiarizationEnabled: Bool = false,
        captureProcessingEnabled: Bool = false,
        capturePrompt: String = "",
        watchOutputMode: CapturePresetWatchOutputMode = .transcript,
        watchRecordingSettings: CapturePresetWatchRecordingSettings = CapturePresetWatchRecordingSettings(),
        audioSaveMode: CapturePresetAudioSaveMode = .off,
        attachmentsFolderName: String = "attachments",
        captureDestinationID: UUID? = nil,
        captureEntryTemplateID: UUID? = nil,
        capturePlacementOverride: CapturePlacement? = nil
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.kind = kind
        self.exportSettings = exportSettings
        self.staticFrontmatter = staticFrontmatter
        self.metadataScope = metadataScope
        self.postProcessingMode = postProcessingMode
        self.customPostProcessingInstruction = customPostProcessingInstruction
        self.speakerDiarizationEnabled = speakerDiarizationEnabled
        self.captureProcessingEnabled = captureProcessingEnabled
        self.capturePrompt = capturePrompt
        self.watchOutputMode = watchOutputMode
        self.watchRecordingSettings = watchRecordingSettings
        self.audioSaveMode = audioSaveMode
        self.attachmentsFolderName = attachmentsFolderName
        self.captureDestinationID = captureDestinationID
        self.captureEntryTemplateID = captureEntryTemplateID
        self.capturePlacementOverride = capturePlacementOverride
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Preset" : trimmed
    }

    public var shortLabel: String {
        displayName
            .split(separator: " ")
            .compactMap { $0.first }
            .prefix(3)
            .map { String($0) }
            .joined()
            .uppercased()
    }

    public var captureProfile: CapturePresetProfile {
        CapturePresetProfile(
            id: id,
            name: name,
            symbolName: symbolName,
            isEnabled: isEnabled,
            isBuiltIn: isBuiltIn,
            staticFrontmatter: staticFrontmatter,
            metadataScope: metadataScope,
            postProcessingMode: postProcessingMode,
            customPostProcessingInstruction: customPostProcessingInstruction,
            captureProcessingEnabled: captureProcessingEnabled,
            capturePrompt: capturePrompt,
            captureDestinationID: captureDestinationID,
            captureEntryTemplateID: captureEntryTemplateID,
            capturePlacementOverride: capturePlacementOverride
        )
    }

    public var resolvedPostProcessingInstruction: String? {
        captureProfile.resolvedPostProcessingInstruction
    }

    public var staticTags: [String] { captureProfile.staticTags }

    public var staticCategory: String? { captureProfile.staticCategory }

    /// Whether this preset should run on-device AI enrichment after transcription.
    /// Keep Original is the explicit per-preset opt-out; every other mode uses
    /// Apple Intelligence when it is available so the app no longer needs a
    /// separate global enrichment toggle.
    public var usesAIEnrichment: Bool {
        postProcessingMode != .none
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case symbolName
        case isEnabled
        case isBuiltIn
        case kind
        case exportSettings
        case staticFrontmatter
        case metadataScope
        case postProcessingMode
        case customPostProcessingInstruction
        case speakerDiarizationEnabled
        case captureProcessingEnabled
        case capturePrompt
        case watchOutputMode
        case watchRecordingSettings
        case audioSaveMode
        case attachmentsFolderName
        case captureDestinationID
        case captureEntryTemplateID
        case capturePlacementOverride
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            symbolName: try container.decodeIfPresent(String.self, forKey: .symbolName)
                ?? CapturePresetStore.defaultSymbolName,
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            isBuiltIn: try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false,
            kind: try container.decodeIfPresent(CapturePresetKind.self, forKey: .kind) ?? .custom,
            exportSettings: try container.decodeIfPresent(CapturePresetExportSettings.self, forKey: .exportSettings)
                ?? CapturePresetExportSettings(),
            staticFrontmatter: try container.decodeIfPresent([String: String].self, forKey: .staticFrontmatter) ?? [:],
            metadataScope: try container.decodeIfPresent(CapturePresetMetadataScope.self, forKey: .metadataScope) ?? .document,
            postProcessingMode: try container.decodeIfPresent(CapturePresetProcessingMode.self, forKey: .postProcessingMode) ?? .clean,
            customPostProcessingInstruction: try container.decodeIfPresent(String.self, forKey: .customPostProcessingInstruction) ?? "",
            speakerDiarizationEnabled: try container.decodeIfPresent(Bool.self, forKey: .speakerDiarizationEnabled) ?? false,
            captureProcessingEnabled: try container.decodeIfPresent(Bool.self, forKey: .captureProcessingEnabled) ?? false,
            capturePrompt: try container.decodeIfPresent(String.self, forKey: .capturePrompt) ?? "",
            watchOutputMode: try container.decodeIfPresent(CapturePresetWatchOutputMode.self, forKey: .watchOutputMode) ?? .transcript,
            watchRecordingSettings: try container.decodeIfPresent(CapturePresetWatchRecordingSettings.self, forKey: .watchRecordingSettings)
                ?? CapturePresetWatchRecordingSettings(),
            audioSaveMode: try container.decodeIfPresent(CapturePresetAudioSaveMode.self, forKey: .audioSaveMode) ?? .off,
            attachmentsFolderName: try container.decodeIfPresent(String.self, forKey: .attachmentsFolderName) ?? "attachments",
            captureDestinationID: try container.decodeIfPresent(UUID.self, forKey: .captureDestinationID),
            captureEntryTemplateID: try container.decodeIfPresent(UUID.self, forKey: .captureEntryTemplateID),
            capturePlacementOverride: try container.decodeIfPresent(CapturePlacement.self, forKey: .capturePlacementOverride)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(symbolName, forKey: .symbolName)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        try container.encode(kind, forKey: .kind)
        try container.encode(exportSettings, forKey: .exportSettings)
        try container.encode(staticFrontmatter, forKey: .staticFrontmatter)
        try container.encode(metadataScope, forKey: .metadataScope)
        try container.encode(postProcessingMode, forKey: .postProcessingMode)
        try container.encode(customPostProcessingInstruction, forKey: .customPostProcessingInstruction)
        try container.encode(speakerDiarizationEnabled, forKey: .speakerDiarizationEnabled)
        try container.encode(captureProcessingEnabled, forKey: .captureProcessingEnabled)
        try container.encode(capturePrompt, forKey: .capturePrompt)
        try container.encode(watchOutputMode, forKey: .watchOutputMode)
        try container.encode(watchRecordingSettings, forKey: .watchRecordingSettings)
        try container.encode(audioSaveMode, forKey: .audioSaveMode)
        try container.encode(attachmentsFolderName, forKey: .attachmentsFolderName)
        try container.encodeIfPresent(captureDestinationID, forKey: .captureDestinationID)
        try container.encodeIfPresent(captureEntryTemplateID, forKey: .captureEntryTemplateID)
        try container.encodeIfPresent(capturePlacementOverride, forKey: .capturePlacementOverride)
    }
}

public enum CapturePresetKind: String, Codable, CaseIterable, Sendable {
    case general
    case dream
    case todo
    case meeting
    case custom
}

public enum CapturePresetWatchOutputMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case transcript
    case recordingOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .transcript: return "Transcript"
        case .recordingOnly: return "Recording Only"
        }
    }
}

public struct CapturePresetWatchRecordingSettings: Codable, Equatable, Sendable {
    public static let defaultFilenameTemplate = "recording-{timestamp}-{id8}"

    public var folderBookmark: Data?
    public var folderName: String
    public var filenameTemplate: String

    public init(
        folderBookmark: Data? = nil,
        folderName: String = "",
        filenameTemplate: String = defaultFilenameTemplate
    ) {
        self.folderBookmark = folderBookmark
        self.folderName = folderName
        self.filenameTemplate = filenameTemplate
    }

    private enum CodingKeys: String, CodingKey {
        case folderBookmark
        case folderName
        case filenameTemplate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folderBookmark = try container.decodeIfPresent(Data.self, forKey: .folderBookmark)
        folderName = try container.decodeIfPresent(String.self, forKey: .folderName) ?? ""
        filenameTemplate = try container.decodeIfPresent(String.self, forKey: .filenameTemplate)
            ?? Self.defaultFilenameTemplate
    }
}

public enum CapturePresetAudioSaveMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    case alongsideTranscript
    case attachmentsFolder

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .alongsideTranscript: return "Alongside Note"
        case .attachmentsFolder: return "Attachments Folder"
        }
    }
}

public enum CapturePresetAudioEmbedPlacement: String, Codable, CaseIterable, Sendable, Identifiable {
    case top
    case bottom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        }
    }
}

/// Per-preset legacy file export settings. `usesCustomExportSettings` is kept
/// for migration from the old global Files tab.
public struct CapturePresetExportSettings: Codable, Equatable, Sendable {
    public var usesCustomExportSettings: Bool
    public var exportEnabled: Bool
    public var format: ExportFileFormat
    public var mode: ExportFileMode
    public var folderBookmark: Data?
    public var folderName: String
    public var audioFolderBookmark: Data?
    public var audioFolderName: String
    public var newFileNameTemplate: String
    public var appendFileName: String
    public var markdownTemplateEnabled: Bool
    public var markdownTemplateBookmark: Data?
    public var markdownTemplateName: String
    public var mdObsidianEnabled: Bool
    public var yamlUsesMarkdownExtension: Bool
    public var yamlProperties: Set<ExportYAMLProperty>
    public var embedAudioInMarkdown: Bool
    public var audioEmbedPlacement: CapturePresetAudioEmbedPlacement

    public init(
        usesCustomExportSettings: Bool = true,
        exportEnabled: Bool = true,
        format: ExportFileFormat = .md,
        mode: ExportFileMode = .newFile,
        folderBookmark: Data? = nil,
        folderName: String = "",
        audioFolderBookmark: Data? = nil,
        audioFolderName: String = "",
        newFileNameTemplate: String = TranscriptFileExporter.defaultNewFileNameTemplate,
        appendFileName: String = TranscriptFileExporter.defaultAppendFileName,
        markdownTemplateEnabled: Bool = false,
        markdownTemplateBookmark: Data? = nil,
        markdownTemplateName: String = "",
        mdObsidianEnabled: Bool = false,
        yamlUsesMarkdownExtension: Bool = false,
        yamlProperties: Set<ExportYAMLProperty> = ExportYAMLProperty.defaultSelection,
        embedAudioInMarkdown: Bool = false,
        audioEmbedPlacement: CapturePresetAudioEmbedPlacement = .bottom
    ) {
        self.usesCustomExportSettings = usesCustomExportSettings
        self.exportEnabled = exportEnabled
        self.format = format
        self.mode = mode
        self.folderBookmark = folderBookmark
        self.folderName = folderName
        self.audioFolderBookmark = audioFolderBookmark
        self.audioFolderName = audioFolderName
        self.newFileNameTemplate = newFileNameTemplate
        self.appendFileName = appendFileName
        self.markdownTemplateEnabled = markdownTemplateEnabled
        self.markdownTemplateBookmark = markdownTemplateBookmark
        self.markdownTemplateName = markdownTemplateName
        self.mdObsidianEnabled = mdObsidianEnabled
        self.yamlUsesMarkdownExtension = yamlUsesMarkdownExtension
        self.yamlProperties = yamlProperties
        self.embedAudioInMarkdown = embedAudioInMarkdown
        self.audioEmbedPlacement = audioEmbedPlacement
    }

    private enum CodingKeys: String, CodingKey {
        case usesCustomExportSettings
        case exportEnabled
        case format
        case mode
        case folderBookmark
        case folderName
        case audioFolderBookmark
        case audioFolderName
        case newFileNameTemplate
        case appendFileName
        case markdownTemplateEnabled
        case markdownTemplateBookmark
        case markdownTemplateName
        case mdObsidianEnabled
        case yamlUsesMarkdownExtension
        case yamlProperties
        case embedAudioInMarkdown
        case audioEmbedPlacement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usesCustomExportSettings = try container.decodeIfPresent(Bool.self, forKey: .usesCustomExportSettings) ?? false
        exportEnabled = try container.decodeIfPresent(Bool.self, forKey: .exportEnabled) ?? true
        format = try container.decodeIfPresent(ExportFileFormat.self, forKey: .format) ?? .md
        mode = try container.decodeIfPresent(ExportFileMode.self, forKey: .mode) ?? .newFile
        folderBookmark = try container.decodeIfPresent(Data.self, forKey: .folderBookmark)
        folderName = try container.decodeIfPresent(String.self, forKey: .folderName) ?? ""
        audioFolderBookmark = try container.decodeIfPresent(Data.self, forKey: .audioFolderBookmark)
        audioFolderName = try container.decodeIfPresent(String.self, forKey: .audioFolderName) ?? ""
        newFileNameTemplate = try container.decodeIfPresent(String.self, forKey: .newFileNameTemplate)
            ?? TranscriptFileExporter.defaultNewFileNameTemplate
        appendFileName = try container.decodeIfPresent(String.self, forKey: .appendFileName)
            ?? TranscriptFileExporter.defaultAppendFileName
        markdownTemplateEnabled = try container.decodeIfPresent(Bool.self, forKey: .markdownTemplateEnabled) ?? false
        markdownTemplateBookmark = try container.decodeIfPresent(Data.self, forKey: .markdownTemplateBookmark)
        markdownTemplateName = try container.decodeIfPresent(String.self, forKey: .markdownTemplateName) ?? ""
        mdObsidianEnabled = try container.decodeIfPresent(Bool.self, forKey: .mdObsidianEnabled) ?? false
        yamlUsesMarkdownExtension = try container.decodeIfPresent(Bool.self, forKey: .yamlUsesMarkdownExtension) ?? false
        let decodedYAMLProperties = try container.decodeIfPresent(Set<ExportYAMLProperty>.self, forKey: .yamlProperties)
        if let decodedYAMLProperties, !decodedYAMLProperties.isEmpty {
            yamlProperties = decodedYAMLProperties
        } else {
            yamlProperties = ExportYAMLProperty.defaultSelection
        }
        embedAudioInMarkdown = try container.decodeIfPresent(Bool.self, forKey: .embedAudioInMarkdown) ?? false
        audioEmbedPlacement = try container.decodeIfPresent(CapturePresetAudioEmbedPlacement.self, forKey: .audioEmbedPlacement) ?? .bottom
    }
}

private enum CapturePresetWriteLockError: Error {
    case unavailable
}

public enum CapturePresetStore {
    /// Stable legacy storage keys. The user-facing concept is now a Capture
    /// Preset, but existing installs, widgets, shortcuts, and extensions must
    /// continue reading the same App Group records.
    public static let flowsKey = "recordingFlows"
    public static let selectedFlowIdKey = "selectedRecordingFlowId"
    private static let retiredRouteIDsKey = "retiredCapturePresetRouteIDs"
    private static let retiredPresetIDsKey = "retiredCapturePresetIDs"

    public static let generalId = "general"
    public static let defaultSymbolName = "waveform"
    private static let deprecatedBuiltInFlowIds: Set<String> = ["dream", "todo", "meeting"]
    private static let legacyDefaultSymbolName = "text.alignleft"

    public static var defaultFlow: CapturePreset {
        CapturePreset(
            id: generalId,
            name: "Default",
            symbolName: defaultSymbolName,
            isBuiltIn: true,
            kind: .general,
            staticFrontmatter: ["type": "capture"],
            postProcessingMode: .clean,
            captureProcessingEnabled: false,
            capturePrompt: "Capture an idea, task, link, file, scan, or recording."
        )
    }

    public static var defaultFlows: [CapturePreset] {
        [defaultFlow]
    }

    public static func makeCustomFlow() -> CapturePreset {
        CapturePreset(
            id: "custom-\(UUID().uuidString.lowercased())",
            name: "Custom Preset",
            symbolName: "slider.horizontal.3",
            isBuiltIn: false,
            kind: .custom,
            staticFrontmatter: [:],
            postProcessingMode: .custom,
            captureProcessingEnabled: false,
            capturePrompt: "What do you want to capture?"
        )
    }

    public static func loadFlows(
        defaults: UserDefaults? = AppConstants.sharedDefaults,
        persistMigrations: Bool = true
    ) -> [CapturePreset] {
        guard let defaults else { return defaultFlows }
        let decoder = JSONDecoder()
        let stored = defaults.data(forKey: flowsKey)
            .flatMap { try? decoder.decode([CapturePreset].self, from: $0) } ?? []

        if stored.isEmpty {
            var flows = defaultFlows
            if let legacySettings = legacyFileExportSettings(from: defaults) {
                for index in flows.indices {
                    flows[index].exportSettings = legacySettings
                }
            }
            if persistMigrations {
                saveFlows(flows, defaults: defaults)
            }
            return flows
        }

        // Keep the single default flow and user-created custom flows. Earlier
        // builds shipped Dream/Todo/Meeting built-ins; migrate those away while
        // preserving any custom flows the user created.
        var migrated = stored.filter { flow in
            !deprecatedBuiltInFlowIds.contains(flow.id) && !(flow.isBuiltIn && flow.id != generalId)
        }
        if let defaultIndex = migrated.firstIndex(where: { $0.id == generalId }),
           migrated[defaultIndex].isBuiltIn {
            if migrated[defaultIndex].name == "General Note" {
                migrated[defaultIndex].name = defaultFlow.name
            }
            if migrated[defaultIndex].symbolName == legacyDefaultSymbolName {
                migrated[defaultIndex].symbolName = defaultFlow.symbolName
            }
        }
        if !migrated.contains(where: { $0.id == generalId }) {
            migrated.insert(defaultFlow, at: 0)
        }

        // Capture Presets now apply to every capture modality. The old generated default
        // would otherwise label typed, photo, file, and scan captures as voice.
        for index in migrated.indices {
            let legacyType = migrated[index].staticFrontmatter["type"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if legacyType == "voice-note" {
                migrated[index].staticFrontmatter["type"] = "capture"
            }
        }

        migrateFileExportSettingsToFlows(&migrated, defaults: defaults)

        if persistMigrations, migrated != stored {
            saveFlows(migrated, defaults: defaults)
        }
        return migrated
    }

    private static func migrateFileExportSettingsToFlows(_ flows: inout [CapturePreset], defaults: UserDefaults) {
        let legacySettings = legacyFileExportSettings(from: defaults)
        for index in flows.indices where !flows[index].exportSettings.usesCustomExportSettings {
            if let legacySettings {
                flows[index].exportSettings = legacySettings
            } else {
                flows[index].exportSettings.usesCustomExportSettings = true
            }
        }
    }

    private static func legacyFileExportSettings(from defaults: UserDefaults) -> CapturePresetExportSettings? {
        let legacyKeys = [
            AppConstants.fileExportEnabledKey,
            AppConstants.fileExportFormatKey,
            AppConstants.fileExportModeKey,
            AppConstants.fileExportBookmarkKey,
            AppConstants.fileExportYAMLPropertiesKey,
            AppConstants.fileExportYAMLObsidianBasesKey,
            AppConstants.fileExportMDObsidianKey,
            AppConstants.fileExportNewFileNameTemplateKey,
            AppConstants.fileExportAppendFileNameKey,
            AppConstants.fileExportTemplateEnabledKey,
            AppConstants.fileExportTemplateBookmarkKey,
            AppConstants.fileExportTemplateNameKey,
        ]
        guard legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return nil }

        let formatRaw = defaults.string(forKey: AppConstants.fileExportFormatKey) ?? ExportFileFormat.txt.rawValue
        let modeRaw = defaults.string(forKey: AppConstants.fileExportModeKey) ?? ExportFileMode.newFile.rawValue
        let bookmark = defaults.data(forKey: AppConstants.fileExportBookmarkKey)
        let templateBookmark = defaults.data(forKey: AppConstants.fileExportTemplateBookmarkKey)
        let yamlRaw = defaults.array(forKey: AppConstants.fileExportYAMLPropertiesKey) as? [String]
        let yamlProperties = Set((yamlRaw ?? []).compactMap(ExportYAMLProperty.init(rawValue:)))

        return CapturePresetExportSettings(
            usesCustomExportSettings: true,
            exportEnabled: defaults.bool(forKey: AppConstants.fileExportEnabledKey),
            format: ExportFileFormat(rawValue: formatRaw) ?? .txt,
            mode: ExportFileMode(rawValue: modeRaw) ?? .newFile,
            folderBookmark: bookmark,
            folderName: bookmark.flatMap(resolvedBookmarkName(_:)) ?? "",
            newFileNameTemplate: defaults.string(forKey: AppConstants.fileExportNewFileNameTemplateKey)
                ?? TranscriptFileExporter.defaultNewFileNameTemplate,
            appendFileName: defaults.string(forKey: AppConstants.fileExportAppendFileNameKey)
                ?? TranscriptFileExporter.defaultAppendFileName,
            markdownTemplateEnabled: defaults.bool(forKey: AppConstants.fileExportTemplateEnabledKey),
            markdownTemplateBookmark: templateBookmark,
            markdownTemplateName: defaults.string(forKey: AppConstants.fileExportTemplateNameKey)
                ?? templateBookmark.flatMap(resolvedBookmarkName(_:))
                ?? "",
            mdObsidianEnabled: defaults.bool(forKey: AppConstants.fileExportMDObsidianKey),
            yamlUsesMarkdownExtension: defaults.bool(forKey: AppConstants.fileExportYAMLObsidianBasesKey),
            yamlProperties: yamlProperties.isEmpty ? ExportYAMLProperty.defaultSelection : yamlProperties
        )
    }

    private static func resolvedBookmarkName(_ bookmarkData: Data) -> String? {
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale).lastPathComponent
    }

    public static func saveFlows(
        _ flows: [CapturePreset],
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) {
        guard let defaults else { return }
        withPresetWriteLock(at: presetWriteLockURL) {
            saveFlowsWithoutLock(
                preservingMigratedRouteOwnership(in: flows, defaults: defaults),
                defaults: defaults
            )
        }
    }

    fileprivate static func saveFlowsWithoutLock(
        _ flows: [CapturePreset],
        defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(flows) else { return }
        defaults.set(data, forKey: flowsKey)
    }

    private static func preservingMigratedRouteOwnership(
        in incoming: [CapturePreset],
        defaults: UserDefaults
    ) -> [CapturePreset] {
        let retiredPresetIDs = Set(defaults.stringArray(forKey: retiredPresetIDsKey) ?? [])
        let activeIncoming = incoming.filter { !retiredPresetIDs.contains($0.id) }
        guard CapturePresetProfileStore.hasOwnedRouteMigration(defaults: defaults),
              let data = defaults.data(forKey: flowsKey),
              let current = try? JSONDecoder().decode([CapturePreset].self, from: data) else {
            return activeIncoming
        }
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let retiredRouteIDs = retiredRouteIDs(defaults: defaults)
        var currentRouteOwners: [UUID: String] = [:]
        for preset in current {
            if let routeID = preset.captureDestinationID,
               currentRouteOwners[routeID] == nil {
                currentRouteOwners[routeID] = preset.id
            }
        }
        return activeIncoming.map { proposed in
            guard let saved = currentByID[proposed.id] else { return proposed }
            let routeBelongsToAnotherPreset = proposed.captureDestinationID.flatMap {
                currentRouteOwners[$0]
            }.map { $0 != proposed.id } == true
            let savedRouteWasExplicitlyRetired = saved.captureDestinationID.map {
                retiredRouteIDs.contains($0)
            } == true
            let wouldEraseMigratedOwnership = saved.captureDestinationID != nil
                && proposed.captureDestinationID != saved.captureDestinationID
                && !savedRouteWasExplicitlyRetired
            let containsLegacyOverrides = proposed.capturePlacementOverride != nil
                || proposed.captureEntryTemplateID != nil
            guard routeBelongsToAnotherPreset
                    || wouldEraseMigratedOwnership
                    || containsLegacyOverrides else {
                return proposed
            }
            var merged = proposed
            merged.captureDestinationID = saved.captureDestinationID
            merged.capturePlacementOverride = nil
            merged.captureEntryTemplateID = nil
            return merged
        } + current.filter { saved in
            !activeIncoming.contains(where: { $0.id == saved.id })
                && !retiredPresetIDs.contains(saved.id)
        }
    }

    private static var presetWriteLockURL: URL {
        (AppConstants.captureDirectoryURL ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("capture-preset-writes.lock", isDirectory: false)
    }

    fileprivate static func withPresetWriteLock(
        at lockURL: URL,
        operation: () -> Void
    ) {
        guard let descriptor = presetWriteLockDescriptor(at: lockURL),
              acquirePresetWriteLock(descriptor) else {
            return
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        operation()
    }

    fileprivate static func withPresetWriteLock<T>(
        at lockURL: URL,
        operation: () async throws -> T
    ) async throws -> T {
        guard let descriptor = presetWriteLockDescriptor(at: lockURL),
              acquirePresetWriteLock(descriptor) else {
            throw CapturePresetWriteLockError.unavailable
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return try await operation()
    }

    private static func presetWriteLockDescriptor(at lockURL: URL) -> Int32? {
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }
        while true {
            let descriptor = open(
                lockURL.path,
                O_CREAT | O_RDWR,
                S_IRUSR | S_IWUSR
            )
            if descriptor >= 0 { return descriptor }
            if errno != EINTR { return nil }
        }
    }

    private static func acquirePresetWriteLock(_ descriptor: Int32) -> Bool {
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR {
                close(descriptor)
                return false
            }
        }
        return true
    }

    fileprivate struct OwnedRouteMigrationPlan: Sendable {
        var library: CaptureLibraryEnvelope
        var presets: [CapturePreset]
        var marksInitialMigrationComplete: Bool
    }

    /// Converts the old many-to-many workflow + Destination library into one
    /// owned Markdown route per Capture Preset. Planning is pure: callers must
    /// save the route library first, then publish the matching preset records.
    /// Clone IDs are deterministic so an interrupted migration can be replayed
    /// without producing dangling references or losing legacy overrides.
    fileprivate static func ownedRouteMigrationPlan(
        library originalLibrary: CaptureLibraryEnvelope,
        defaults: UserDefaults
    ) -> OwnedRouteMigrationPlan? {
        let originalPresets = loadFlows(
            defaults: defaults,
            persistMigrations: false
        )
        var presets = originalPresets
        var library = originalLibrary
        guard !presets.isEmpty else { return nil }

        let isInitialMigration = !CapturePresetProfileStore.hasOwnedRouteMigration(defaults: defaults)
        let retiredIDs = retiredRouteIDs(defaults: defaults)
        let validRouteIDs = Set(library.destinations.map(\.id))
        let fallbackID: UUID? = isInitialMigration
            ? library.defaultDestinationID.flatMap {
                validRouteIDs.contains($0) && !retiredIDs.contains($0) ? $0 : nil
            } ?? library.destinations.first(where: { !retiredIDs.contains($0.id) })?.id
            : nil
        let selectedID = CapturePresetProfileStore.selectedProfileID(defaults: defaults)

        var orderedIndices: [Int] = []
        if let selectedID,
           let selectedIndex = presets.firstIndex(where: { $0.id == selectedID }) {
            orderedIndices.append(selectedIndex)
        }
        if let defaultIndex = presets.firstIndex(where: { $0.id == generalId }),
           !orderedIndices.contains(defaultIndex) {
            orderedIndices.append(defaultIndex)
        }
        orderedIndices.append(contentsOf: presets.indices.filter { !orderedIndices.contains($0) })

        var claimedRouteIDs = Set<UUID>()
        for index in orderedIndices {
            let currentID = presets[index].captureDestinationID
                .flatMap { validRouteIDs.contains($0) && !retiredIDs.contains($0) ? $0 : nil }
            let legacyID = isInitialMigration
                ? library.legacyFlowBindings[presets[index].id]
                    .flatMap { validRouteIDs.contains($0) && !retiredIDs.contains($0) ? $0 : nil }
                : nil
            let requestedID = currentID ?? legacyID ?? fallbackID
            guard let requestedID,
                  let source = library.destinations.first(where: { $0.id == requestedID }) else {
                presets[index].captureDestinationID = nil
                continue
            }

            var owned = source
            if claimedRouteIDs.contains(requestedID) {
                owned.id = deterministicOwnedRouteID(
                    presetID: presets[index].id,
                    sourceRouteID: requestedID
                )
            }
            owned.name = presets[index].displayName
            if let placement = presets[index].capturePlacementOverride {
                owned.placement = placement
            }
            if let templateID = presets[index].captureEntryTemplateID {
                owned.entryTemplateID = templateID
            }
            if owned.markdownTemplatePath == nil,
               owned.entryTemplateID == nil,
               owned.entryPrefix.isEmpty,
               owned.entrySuffix.isEmpty,
               let templatePath = migratedVaultTemplatePath(
                   from: presets[index].exportSettings,
                   destination: owned
               ) {
                owned.markdownTemplatePath = templatePath
                // The destination now owns the live template. Clearing the
                // retired voice-only setting prevents a later user removal
                // from being re-imported on every library load.
                presets[index].exportSettings.markdownTemplateEnabled = false
                presets[index].exportSettings.markdownTemplateBookmark = nil
                presets[index].exportSettings.markdownTemplateName = ""
            }

            if let existingIndex = library.destinations.firstIndex(where: { $0.id == owned.id }) {
                library.destinations[existingIndex] = owned
            } else {
                library.destinations.append(owned)
            }
            presets[index].captureDestinationID = owned.id
            presets[index].capturePlacementOverride = nil
            presets[index].captureEntryTemplateID = nil
            claimedRouteIDs.insert(owned.id)
        }

        // Only the one-time legacy migration promotes unbound destinations.
        // New presets deliberately remain unconfigured until the user chooses
        // their destination; retired routes remain hidden for queued delivery.
        if isInitialMigration {
            let orphanedRoutes = library.destinations.filter {
                !claimedRouteIDs.contains($0.id) && !retiredIDs.contains($0.id)
            }
            for route in orphanedRoutes {
                let presetID = "route-\(route.id.uuidString.lowercased())"
                if let existingIndex = presets.firstIndex(where: { $0.id == presetID }) {
                    presets[existingIndex].captureDestinationID = route.id
                } else {
                    presets.append(CapturePreset(
                        id: presetID,
                        name: route.name,
                        symbolName: "folder",
                        isBuiltIn: false,
                        kind: .custom,
                        staticFrontmatter: [:],
                        postProcessingMode: .none,
                        captureProcessingEnabled: false,
                        capturePrompt: "What do you want to capture?",
                        audioSaveMode: .off,
                        captureDestinationID: route.id
                    ))
                }
                claimedRouteIDs.insert(route.id)
            }
        }

        if let selectedID,
           let selectedRouteID = presets.first(where: { $0.id == selectedID })?.captureDestinationID {
            library.defaultDestinationID = selectedRouteID
        } else {
            library.defaultDestinationID = presets.compactMap(\.captureDestinationID).first
        }

        let changed = library != originalLibrary
            || presets != originalPresets
            || isInitialMigration
        guard changed else { return nil }
        return OwnedRouteMigrationPlan(
            library: library,
            presets: presets,
            marksInitialMigrationComplete: isInitialMigration
        )
    }

    /// Direct compatibility entry point used by tests and migrations that
    /// already own their persistence transaction.
    @discardableResult
    static func migrateToOwnedPresetRoutes(
        library: inout CaptureLibraryEnvelope,
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) -> Bool {
        guard let defaults,
              let plan = ownedRouteMigrationPlan(library: library, defaults: defaults) else {
            return false
        }
        library = plan.library
        saveFlows(plan.presets, defaults: defaults)
        if plan.marksInitialMigrationComplete {
            defaults.set(
                CapturePresetProfileStore.currentOwnedRouteMigrationVersion,
                forKey: CapturePresetProfileStore.ownedRouteMigrationVersionKey
            )
        }
        return true
    }

    /// Carries a preset's retired voice-export template into a newly created
    /// unified destination when the file is inside that destination's vault.
    /// Existing destination formatting always wins.
    public static func migratingLegacyMarkdownTemplate(
        into destination: CaptureDestination,
        from settings: CapturePresetExportSettings
    ) -> CaptureDestination {
        guard destination.markdownTemplatePath == nil,
              destination.entryTemplateID == nil,
              destination.entryPrefix.isEmpty,
              destination.entrySuffix.isEmpty,
              let templatePath = migratedVaultTemplatePath(
                  from: settings,
                  destination: destination
              ) else { return destination }
        var migrated = destination
        migrated.markdownTemplatePath = templatePath
        return migrated
    }

    private static func migratedVaultTemplatePath(
        from settings: CapturePresetExportSettings,
        destination: CaptureDestination
    ) -> String? {
        guard settings.markdownTemplateEnabled,
              let templateBookmark = settings.markdownTemplateBookmark,
              !destination.rootBookmark.isEmpty,
              let rootResolution = try? CaptureBookmarkResolver.resolve(destination.rootBookmark),
              let templateResolution = try? CaptureBookmarkResolver.resolve(templateBookmark),
              !rootResolution.isStale,
              !templateResolution.isStale else { return nil }

        let rootURL = rootResolution.url.standardizedFileURL
        let templateURL = templateResolution.url.standardizedFileURL
        let rootAccess = rootURL.startAccessingSecurityScopedResource()
        let templateAccess = templateURL.startAccessingSecurityScopedResource()
        defer {
            if templateAccess { templateURL.stopAccessingSecurityScopedResource() }
            if rootAccess { rootURL.stopAccessingSecurityScopedResource() }
        }

        guard templateURL.pathExtension.lowercased() == "md" else { return nil }
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard templateURL.path.hasPrefix(rootPrefix) else { return nil }
        let relativePath = String(templateURL.path.dropFirst(rootPrefix.count))
        guard (try? CapturePathValidation.validateRelativePath(relativePath)) != nil,
              FileManager.default.fileExists(atPath: templateURL.path),
              let containedURL = try? CapturePathValidation.containedFileURL(
                  relativePath: relativePath,
                  rootURL: rootURL
              ),
              containedURL.resolvingSymlinksInPath().standardizedFileURL
                == templateURL.resolvingSymlinksInPath().standardizedFileURL else {
            return nil
        }
        return relativePath
    }

    private static func deterministicOwnedRouteID(
        presetID: String,
        sourceRouteID: UUID
    ) -> UUID {
        let bytes = Array("\(sourceRouteID.uuidString.lowercased())|\(presetID)".utf8)
        func fnv1a(seed: UInt64) -> UInt64 {
            bytes.reduce(seed) { hash, byte in
                (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        let first = fnv1a(seed: 14_695_981_039_346_656_037)
        let second = fnv1a(seed: 7_809_847_782_469_553_709)
        let hex = String(format: "%016llx%016llx", first, second)
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-5\(hex.dropFirst(13).prefix(3))-a\(hex.dropFirst(17).prefix(3))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuidString)!
    }

    public static func retireOwnedRoute(
        _ routeID: UUID?,
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) {
        guard let routeID, let defaults else { return }
        withPresetWriteLock(at: presetWriteLockURL) {
            retireOwnedRouteWithoutLock(routeID, defaults: defaults)
        }
    }

    private static func retireOwnedRouteWithoutLock(
        _ routeID: UUID,
        defaults: UserDefaults
    ) {
        var ids = retiredRouteIDs(defaults: defaults)
        ids.insert(routeID)
        defaults.set(ids.map(\.uuidString), forKey: retiredRouteIDsKey)
    }

    fileprivate static func retiredRouteIDs(defaults: UserDefaults) -> Set<UUID> {
        Set((defaults.stringArray(forKey: retiredRouteIDsKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    public static func retirePreset(
        id: String,
        ownedRouteID: UUID?,
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) {
        guard let defaults else { return }
        withPresetWriteLock(at: presetWriteLockURL) {
            var ids = Set(defaults.stringArray(forKey: retiredPresetIDsKey) ?? [])
            ids.insert(id)
            defaults.set(Array(ids), forKey: retiredPresetIDsKey)
            if let ownedRouteID {
                retireOwnedRouteWithoutLock(ownedRouteID, defaults: defaults)
            }
            guard let data = defaults.data(forKey: flowsKey),
                  var presets = try? JSONDecoder().decode([CapturePreset].self, from: data) else {
                return
            }
            presets.removeAll { $0.id == id }
            saveFlowsWithoutLock(presets, defaults: defaults)
        }
    }

    /// Imports the retired Capture-library route map exactly once without
    /// overriding newer per-preset choices. New library saves omit the old map.
    @discardableResult
    public static func migrateLegacyCaptureBindings(
        _ bindings: [String: UUID],
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) -> Int {
        guard !bindings.isEmpty else { return 0 }
        var flows = loadFlows(defaults: defaults)
        var migrated = 0
        for index in flows.indices where flows[index].captureDestinationID == nil {
            if let destinationID = bindings[flows[index].id] {
                flows[index].captureDestinationID = destinationID
                migrated += 1
            }
        }
        if migrated > 0 { saveFlows(flows, defaults: defaults) }
        return migrated
    }

    /// Removes stale precise routes when a capture destination is deleted.
    /// Legacy per-flow export settings remain untouched as a safe fallback.
    @discardableResult
    public static func clearCaptureDestination(
        _ destinationID: UUID,
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) -> Int {
        retireOwnedRoute(destinationID, defaults: defaults)
        var flows = loadFlows(defaults: defaults)
        var cleared = 0
        for index in flows.indices where flows[index].captureDestinationID == destinationID {
            flows[index].captureDestinationID = nil
            cleared += 1
        }
        if cleared > 0 { saveFlows(flows, defaults: defaults) }
        return cleared
    }

    /// Removes stale reusable entry-template defaults when a template is deleted.
    @discardableResult
    public static func clearCaptureEntryTemplate(
        _ templateID: UUID,
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) -> Int {
        var flows = loadFlows(defaults: defaults)
        var cleared = 0
        for index in flows.indices where flows[index].captureEntryTemplateID == templateID {
            flows[index].captureEntryTemplateID = nil
            cleared += 1
        }
        if cleared > 0 { saveFlows(flows, defaults: defaults) }
        return cleared
    }

    public static func selectedFlowId(defaults: UserDefaults? = AppConstants.sharedDefaults) -> String {
        let flows = loadFlows(defaults: defaults)
        let enabled = flows.filter(\.isEnabled)
        let fallback = enabled.first?.id ?? generalId
        guard let stored = defaults?.string(forKey: selectedFlowIdKey),
              flows.contains(where: { $0.id == stored && $0.isEnabled }) else {
            defaults?.set(fallback, forKey: selectedFlowIdKey)
            return fallback
        }
        return stored
    }

    public static func selectedFlow(defaults: UserDefaults? = AppConstants.sharedDefaults) -> CapturePreset {
        let flows = loadFlows(defaults: defaults)
        let selected = selectedFlowId(defaults: defaults)
        return flows.first(where: { $0.id == selected }) ?? flows.first ?? defaultFlows[0]
    }

    public static func flow(id: String?, defaults: UserDefaults? = AppConstants.sharedDefaults) -> CapturePreset? {
        guard let id else { return nil }
        return loadFlows(defaults: defaults).first(where: { $0.id == id })
    }

    public static func selectFlow(id: String, defaults: UserDefaults? = AppConstants.sharedDefaults) {
        defaults?.set(id, forKey: selectedFlowIdKey)
    }

    @discardableResult
    public static func selectNextFlow(defaults: UserDefaults? = AppConstants.sharedDefaults) -> CapturePreset {
        let enabled = loadFlows(defaults: defaults).filter(\.isEnabled)
        guard !enabled.isEmpty else { return defaultFlows[0] }
        let current = selectedFlowId(defaults: defaults)
        let currentIndex = enabled.firstIndex(where: { $0.id == current }) ?? -1
        let next = enabled[(currentIndex + 1 + enabled.count) % enabled.count]
        selectFlow(id: next.id, defaults: defaults)
        return next
    }
}

public enum CapturePresetRouteLibrary {
    /// Loads the route library and commits the one-time ownership migration as
    /// a coordinated file transaction. Matching App Group preset records are
    /// published only after the file succeeds. Deterministic IDs make the
    /// operation safely replayable after interruption or concurrent attempts.
    public static func load(
        from store: CaptureLibraryStore,
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) async throws -> CaptureLibraryEnvelope {
        guard let defaults else { return try await store.load() }
        let libraryURL = await store.fileURL
        let lockURL = libraryURL.deletingLastPathComponent()
            .appendingPathComponent("capture-preset-writes.lock", isDirectory: false)
        return try await CapturePresetStore.withPresetWriteLock(at: lockURL) {
            let preview = try await store.load()
            guard CapturePresetStore.ownedRouteMigrationPlan(
                library: preview,
                defaults: defaults
            ) != nil else {
                return preview
            }

            let (library, plan) = try await store.updateReturning { latest in
                let plan = CapturePresetStore.ownedRouteMigrationPlan(
                    library: latest,
                    defaults: defaults
                )
                if let plan {
                    latest = plan.library
                }
                return plan
            }
            if let plan {
                CapturePresetStore.saveFlowsWithoutLock(
                    plan.presets,
                    defaults: defaults
                )
                if plan.marksInitialMigrationComplete {
                    defaults.set(
                        CapturePresetProfileStore.currentOwnedRouteMigrationVersion,
                        forKey: CapturePresetProfileStore.ownedRouteMigrationVersionKey
                    )
                }
            }
            return library
        }
    }
}

// MARK: - Legacy source compatibility

public typealias RecordingFlow = CapturePreset
public typealias RecordingFlowStore = CapturePresetStore
public typealias RecordingFlowKind = CapturePresetKind
public typealias RecordingFlowPostProcessingMode = CapturePresetProcessingMode
public typealias RecordingFlowAudioSaveMode = CapturePresetAudioSaveMode
public typealias RecordingFlowAudioEmbedPlacement = CapturePresetAudioEmbedPlacement
public typealias RecordingFlowExportSettings = CapturePresetExportSettings
