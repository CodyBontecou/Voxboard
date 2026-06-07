import Foundation

/// A named recording/export preset. Flows are the Voxboard equivalent of
/// v2md-style "flow tags": they let the user choose a workflow before
/// recording, then apply workflow-specific export, frontmatter, audio-retention,
/// and post-processing behavior.
public struct RecordingFlow: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbolName: String
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var kind: RecordingFlowKind
    public var exportSettings: RecordingFlowExportSettings
    public var staticFrontmatter: [String: String]
    public var postProcessingMode: RecordingFlowPostProcessingMode
    public var customPostProcessingInstruction: String
    public var audioSaveMode: RecordingFlowAudioSaveMode
    public var attachmentsFolderName: String

    public init(
        id: String,
        name: String,
        symbolName: String,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        kind: RecordingFlowKind = .custom,
        exportSettings: RecordingFlowExportSettings = RecordingFlowExportSettings(),
        staticFrontmatter: [String: String] = [:],
        postProcessingMode: RecordingFlowPostProcessingMode = .clean,
        customPostProcessingInstruction: String = "",
        audioSaveMode: RecordingFlowAudioSaveMode = .off,
        attachmentsFolderName: String = "attachments"
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.kind = kind
        self.exportSettings = exportSettings
        self.staticFrontmatter = staticFrontmatter
        self.postProcessingMode = postProcessingMode
        self.customPostProcessingInstruction = customPostProcessingInstruction
        self.audioSaveMode = audioSaveMode
        self.attachmentsFolderName = attachmentsFolderName
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

    public var resolvedPostProcessingInstruction: String? {
        switch postProcessingMode {
        case .none:
            return nil
        case .clean:
            return "Clean up the transcript with proper casing and punctuation while preserving the speaker's meaning."
        case .todoList:
            return "Convert the transcript into a concise Markdown task list. Each actionable item must be formatted as `- [ ] ...`. Do not invent tasks."
        case .meetingNotes:
            return "Format the transcript as meeting notes with useful Markdown sections such as Summary, Decisions, and Action Items. Do not invent details or speaker names."
        case .custom:
            let trimmed = customPostProcessingInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    public var staticTags: [String] {
        guard let raw = staticFrontmatter["tags"] ?? staticFrontmatter["tag"] else { return [] }
        return raw
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .split { $0 == "," || $0 == " " || $0 == "#" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    public var staticCategory: String? {
        let raw = staticFrontmatter["category"] ?? staticFrontmatter["type"]
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Whether this Vox should run on-device AI enrichment after transcription.
    /// Raw Transcript is the explicit per-Vox opt-out; every other mode uses
    /// Apple Intelligence when it is available so the app no longer needs a
    /// separate global enrichment toggle.
    public var usesAIEnrichment: Bool {
        postProcessingMode != .none
    }
}

public enum RecordingFlowKind: String, Codable, CaseIterable, Sendable {
    case general
    case dream
    case todo
    case meeting
    case custom
}

public enum RecordingFlowPostProcessingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case clean
    case todoList
    case meetingNotes
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "Raw Transcript"
        case .clean: return "Clean Prose"
        case .todoList: return "Todo Checklist"
        case .meetingNotes: return "Meeting Notes"
        case .custom: return "Custom Instruction"
        }
    }
}

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
    private static let deprecatedBuiltInFlowIds: Set<String> = ["dream", "todo", "meeting"]

    public static var defaultFlow: RecordingFlow {
        RecordingFlow(
            id: generalId,
            name: "Default",
            symbolName: "text.alignleft",
            isBuiltIn: true,
            kind: .general,
            staticFrontmatter: ["type": "voice-note"],
            postProcessingMode: .clean
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
            staticFrontmatter: ["type": "voice-note"],
            postProcessingMode: .custom
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
           migrated[defaultIndex].isBuiltIn,
           migrated[defaultIndex].name == "General Note" {
            migrated[defaultIndex].name = defaultFlow.name
        }
        if !migrated.contains(where: { $0.id == generalId }) {
            migrated.insert(defaultFlow, at: 0)
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
