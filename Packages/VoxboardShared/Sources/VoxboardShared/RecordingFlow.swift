import Foundation
import VoxboardCaptureCore

/// The persisted Vox model. Its capture-policy fields apply to every input
/// modality, while export and audio-retention fields preserve recording-specific
/// behavior and compatibility with existing Voxes.
public struct RecordingFlow: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbolName: String
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var kind: RecordingFlowKind
    public var exportSettings: RecordingFlowExportSettings
    public var staticFrontmatter: [String: String]
    public var metadataScope: CaptureVoxMetadataScope
    public var postProcessingMode: RecordingFlowPostProcessingMode
    public var customPostProcessingInstruction: String
    /// Opt-in for applying this Vox's processing mode to typed and multimodal
    /// Capture text. Existing Voxes decode as false to avoid rewriting Markdown.
    public var captureProcessingEnabled: Bool
    /// Optional local prompt shown in an empty Capture composer.
    public var capturePrompt: String
    public var audioSaveMode: RecordingFlowAudioSaveMode
    public var attachmentsFolderName: String
    /// Optional precise Markdown route shared with every capture modality.
    /// Nil inherits the Capture-library default, then falls back to legacy
    /// voice export only when no Capture destination exists.
    public var captureDestinationID: UUID?
    public var captureEntryTemplateID: UUID?
    public var capturePlacementOverride: CapturePlacement?

    public init(
        id: String,
        name: String,
        symbolName: String,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        kind: RecordingFlowKind = .custom,
        exportSettings: RecordingFlowExportSettings = RecordingFlowExportSettings(),
        staticFrontmatter: [String: String] = [:],
        metadataScope: CaptureVoxMetadataScope = .document,
        postProcessingMode: RecordingFlowPostProcessingMode = .clean,
        customPostProcessingInstruction: String = "",
        captureProcessingEnabled: Bool = false,
        capturePrompt: String = "",
        audioSaveMode: RecordingFlowAudioSaveMode = .off,
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
        self.captureProcessingEnabled = captureProcessingEnabled
        self.capturePrompt = capturePrompt
        self.audioSaveMode = audioSaveMode
        self.attachmentsFolderName = attachmentsFolderName
        self.captureDestinationID = captureDestinationID
        self.captureEntryTemplateID = captureEntryTemplateID
        self.capturePlacementOverride = capturePlacementOverride
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Vox" : trimmed
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

    public var captureProfile: CaptureVoxProfile {
        CaptureVoxProfile(
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

    /// Whether this Vox should run on-device AI enrichment after transcription.
    /// Keep Original is the explicit per-Vox opt-out; every other mode uses
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
        case captureProcessingEnabled
        case capturePrompt
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
                ?? RecordingFlowStore.defaultSymbolName,
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            isBuiltIn: try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false,
            kind: try container.decodeIfPresent(RecordingFlowKind.self, forKey: .kind) ?? .custom,
            exportSettings: try container.decodeIfPresent(RecordingFlowExportSettings.self, forKey: .exportSettings)
                ?? RecordingFlowExportSettings(),
            staticFrontmatter: try container.decodeIfPresent([String: String].self, forKey: .staticFrontmatter) ?? [:],
            metadataScope: try container.decodeIfPresent(CaptureVoxMetadataScope.self, forKey: .metadataScope) ?? .document,
            postProcessingMode: try container.decodeIfPresent(RecordingFlowPostProcessingMode.self, forKey: .postProcessingMode) ?? .clean,
            customPostProcessingInstruction: try container.decodeIfPresent(String.self, forKey: .customPostProcessingInstruction) ?? "",
            captureProcessingEnabled: try container.decodeIfPresent(Bool.self, forKey: .captureProcessingEnabled) ?? false,
            capturePrompt: try container.decodeIfPresent(String.self, forKey: .capturePrompt) ?? "",
            audioSaveMode: try container.decodeIfPresent(RecordingFlowAudioSaveMode.self, forKey: .audioSaveMode) ?? .off,
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
        try container.encode(captureProcessingEnabled, forKey: .captureProcessingEnabled)
        try container.encode(capturePrompt, forKey: .capturePrompt)
        try container.encode(audioSaveMode, forKey: .audioSaveMode)
        try container.encode(attachmentsFolderName, forKey: .attachmentsFolderName)
        try container.encodeIfPresent(captureDestinationID, forKey: .captureDestinationID)
        try container.encodeIfPresent(captureEntryTemplateID, forKey: .captureEntryTemplateID)
        try container.encodeIfPresent(capturePlacementOverride, forKey: .capturePlacementOverride)
    }
}

public enum RecordingFlowKind: String, Codable, CaseIterable, Sendable {
    case general
    case dream
    case todo
    case meeting
    case custom
}

public typealias RecordingFlowPostProcessingMode = CaptureVoxProcessingMode

public enum RecordingFlowAudioSaveMode: String, Codable, CaseIterable, Sendable, Identifiable {
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

public enum RecordingFlowAudioEmbedPlacement: String, Codable, CaseIterable, Sendable, Identifiable {
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

/// Per-flow file export settings. `usesCustomExportSettings` is kept for
/// migration from the old global Files tab; new flows set it to `true` so each
/// flow can choose its own note and audio destinations.
public struct RecordingFlowExportSettings: Codable, Equatable, Sendable {
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
    public var audioEmbedPlacement: RecordingFlowAudioEmbedPlacement

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
        audioEmbedPlacement: RecordingFlowAudioEmbedPlacement = .bottom
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
        audioEmbedPlacement = try container.decodeIfPresent(RecordingFlowAudioEmbedPlacement.self, forKey: .audioEmbedPlacement) ?? .bottom
    }
}

public enum RecordingFlowStore {
    public static let flowsKey = "recordingFlows"
    public static let selectedFlowIdKey = "selectedRecordingFlowId"

    public static let generalId = "general"
    public static let defaultSymbolName = "waveform"
    private static let deprecatedBuiltInFlowIds: Set<String> = ["dream", "todo", "meeting"]
    private static let legacyDefaultSymbolName = "text.alignleft"

    public static var defaultFlow: RecordingFlow {
        RecordingFlow(
            id: generalId,
            name: "Default",
            symbolName: defaultSymbolName,
            isBuiltIn: true,
            kind: .general,
            staticFrontmatter: ["type": "capture"],
            postProcessingMode: .clean,
            capturePrompt: "Capture an idea, task, link, file, scan, or recording."
        )
    }

    public static var defaultFlows: [RecordingFlow] {
        [defaultFlow]
    }

    public static func makeCustomFlow() -> RecordingFlow {
        RecordingFlow(
            id: "custom-\(UUID().uuidString.lowercased())",
            name: "Custom Vox",
            symbolName: "slider.horizontal.3",
            isBuiltIn: false,
            kind: .custom,
            staticFrontmatter: [:],
            postProcessingMode: .custom,
            capturePrompt: "What do you want to capture?"
        )
    }

    public static func loadFlows(defaults: UserDefaults? = AppConstants.sharedDefaults) -> [RecordingFlow] {
        guard let defaults else { return defaultFlows }
        let decoder = JSONDecoder()
        let stored = defaults.data(forKey: flowsKey)
            .flatMap { try? decoder.decode([RecordingFlow].self, from: $0) } ?? []

        if stored.isEmpty {
            var flows = defaultFlows
            if let legacySettings = legacyFileExportSettings(from: defaults) {
                for index in flows.indices {
                    flows[index].exportSettings = legacySettings
                }
            }
            saveFlows(flows, defaults: defaults)
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

        // Voxes now apply to every capture modality. The old generated default
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

        if migrated != stored { saveFlows(migrated, defaults: defaults) }
        return migrated
    }

    private static func migrateFileExportSettingsToFlows(_ flows: inout [RecordingFlow], defaults: UserDefaults) {
        let legacySettings = legacyFileExportSettings(from: defaults)
        for index in flows.indices where !flows[index].exportSettings.usesCustomExportSettings {
            if let legacySettings {
                flows[index].exportSettings = legacySettings
            } else {
                flows[index].exportSettings.usesCustomExportSettings = true
            }
        }
    }

    private static func legacyFileExportSettings(from defaults: UserDefaults) -> RecordingFlowExportSettings? {
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

        return RecordingFlowExportSettings(
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

    public static func saveFlows(_ flows: [RecordingFlow], defaults: UserDefaults? = AppConstants.sharedDefaults) {
        guard let defaults, let data = try? JSONEncoder().encode(flows) else { return }
        defaults.set(data, forKey: flowsKey)
    }

    /// Imports the retired Capture-library route map exactly once without
    /// overriding newer per-Vox choices. New library saves omit the old map.
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

    public static func selectedFlow(defaults: UserDefaults? = AppConstants.sharedDefaults) -> RecordingFlow {
        let flows = loadFlows(defaults: defaults)
        let selected = selectedFlowId(defaults: defaults)
        return flows.first(where: { $0.id == selected }) ?? flows.first ?? defaultFlows[0]
    }

    public static func flow(id: String?, defaults: UserDefaults? = AppConstants.sharedDefaults) -> RecordingFlow? {
        guard let id else { return nil }
        return loadFlows(defaults: defaults).first(where: { $0.id == id })
    }

    public static func selectFlow(id: String, defaults: UserDefaults? = AppConstants.sharedDefaults) {
        defaults?.set(id, forKey: selectedFlowIdKey)
    }

    @discardableResult
    public static func selectNextFlow(defaults: UserDefaults? = AppConstants.sharedDefaults) -> RecordingFlow {
        let enabled = loadFlows(defaults: defaults).filter(\.isEnabled)
        guard !enabled.isEmpty else { return defaultFlows[0] }
        let current = selectedFlowId(defaults: defaults)
        let currentIndex = enabled.firstIndex(where: { $0.id == current }) ?? -1
        let next = enabled[(currentIndex + 1 + enabled.count) % enabled.count]
        selectFlow(id: next.id, defaults: defaults)
        return next
    }
}
