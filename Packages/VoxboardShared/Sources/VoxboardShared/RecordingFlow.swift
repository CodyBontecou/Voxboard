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
        return trimmed.isEmpty ? "Untitled Flow" : trimmed
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

/// Export settings that can optionally override the global Files tab settings
/// for a single flow. When `usesCustomExportSettings` is false, Voxboard keeps
/// using the existing global export configuration for that flow.
public struct RecordingFlowExportSettings: Codable, Equatable, Sendable {
    public var usesCustomExportSettings: Bool
    public var exportEnabled: Bool
    public var format: ExportFileFormat
    public var mode: ExportFileMode
    public var folderBookmark: Data?
    public var folderName: String
    public var newFileNameTemplate: String
    public var appendFileName: String
    public var markdownTemplateEnabled: Bool
    public var markdownTemplateBookmark: Data?
    public var markdownTemplateName: String
    public var mdObsidianEnabled: Bool
    public var yamlUsesMarkdownExtension: Bool
    public var yamlProperties: Set<ExportYAMLProperty>

    public init(
        usesCustomExportSettings: Bool = false,
        exportEnabled: Bool = true,
        format: ExportFileFormat = .md,
        mode: ExportFileMode = .newFile,
        folderBookmark: Data? = nil,
        folderName: String = "",
        newFileNameTemplate: String = TranscriptFileExporter.defaultNewFileNameTemplate,
        appendFileName: String = TranscriptFileExporter.defaultAppendFileName,
        markdownTemplateEnabled: Bool = false,
        markdownTemplateBookmark: Data? = nil,
        markdownTemplateName: String = "",
        mdObsidianEnabled: Bool = false,
        yamlUsesMarkdownExtension: Bool = false,
        yamlProperties: Set<ExportYAMLProperty> = ExportYAMLProperty.defaultSelection
    ) {
        self.usesCustomExportSettings = usesCustomExportSettings
        self.exportEnabled = exportEnabled
        self.format = format
        self.mode = mode
        self.folderBookmark = folderBookmark
        self.folderName = folderName
        self.newFileNameTemplate = newFileNameTemplate
        self.appendFileName = appendFileName
        self.markdownTemplateEnabled = markdownTemplateEnabled
        self.markdownTemplateBookmark = markdownTemplateBookmark
        self.markdownTemplateName = markdownTemplateName
        self.mdObsidianEnabled = mdObsidianEnabled
        self.yamlUsesMarkdownExtension = yamlUsesMarkdownExtension
        self.yamlProperties = yamlProperties
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
            name: "Custom Flow",
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
            let flows = defaultFlows
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
        if migrated != stored { saveFlows(migrated, defaults: defaults) }
        return migrated
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
