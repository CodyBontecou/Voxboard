import Foundation

/// A modality-neutral Vox policy snapshot. The persisted recording-flow format
/// intentionally uses the same coding keys, allowing lightweight capture
/// clients (Shortcuts and the share extension) to read Voxes without linking
/// the transcription/export stack.
public struct CaptureVoxProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbolName: String
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var staticFrontmatter: [String: String]
    /// Document frontmatter is ideal for one-note-per-capture destinations;
    /// inline entry fields keep rolling/shared notes from being relabeled.
    public var metadataScope: CaptureVoxMetadataScope
    public var postProcessingMode: CaptureVoxProcessingMode
    public var customPostProcessingInstruction: String
    /// Existing Voxes remain capture-safe: processing typed or mixed Markdown
    /// is opt-in even though voice recordings continue using their mode.
    public var captureProcessingEnabled: Bool
    /// Optional local empty-state prompt shown when this Vox is active.
    public var capturePrompt: String
    /// The reusable route inherited by captures using this Vox.
    public var captureDestinationID: UUID?
    /// Optional Vox-level defaults layered over the selected route.
    public var captureEntryTemplateID: UUID?
    public var capturePlacementOverride: CapturePlacement?

    public init(
        id: String,
        name: String,
        symbolName: String,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        staticFrontmatter: [String: String] = [:],
        metadataScope: CaptureVoxMetadataScope = .document,
        postProcessingMode: CaptureVoxProcessingMode = .clean,
        customPostProcessingInstruction: String = "",
        captureProcessingEnabled: Bool = false,
        capturePrompt: String = "",
        captureDestinationID: UUID? = nil,
        captureEntryTemplateID: UUID? = nil,
        capturePlacementOverride: CapturePlacement? = nil
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.staticFrontmatter = staticFrontmatter
        self.metadataScope = metadataScope
        self.postProcessingMode = postProcessingMode
        self.customPostProcessingInstruction = customPostProcessingInstruction
        self.captureProcessingEnabled = captureProcessingEnabled
        self.capturePrompt = capturePrompt
        self.captureDestinationID = captureDestinationID
        self.captureEntryTemplateID = captureEntryTemplateID
        self.capturePlacementOverride = capturePlacementOverride
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Vox" : trimmed
    }

    public var resolvedPostProcessingInstruction: String? {
        switch postProcessingMode {
        case .none:
            return nil
        case .clean:
            return "Clean up the captured text with proper casing and punctuation while preserving its meaning and Markdown structure."
        case .todoList:
            return "Convert the captured text into a concise Markdown task list. Each actionable item must be formatted as `- [ ] ...`. Do not invent tasks."
        case .meetingNotes:
            return "Format the captured text as meeting notes with useful Markdown sections such as Summary, Decisions, and Action Items. Do not invent details or speaker names."
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

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case symbolName
        case isEnabled
        case isBuiltIn
        case staticFrontmatter
        case metadataScope
        case postProcessingMode
        case customPostProcessingInstruction
        case captureProcessingEnabled
        case capturePrompt
        case captureDestinationID
        case captureEntryTemplateID
        case capturePlacementOverride
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            symbolName: try container.decodeIfPresent(String.self, forKey: .symbolName) ?? "waveform",
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            isBuiltIn: try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false,
            staticFrontmatter: try container.decodeIfPresent([String: String].self, forKey: .staticFrontmatter) ?? [:],
            metadataScope: try container.decodeIfPresent(CaptureVoxMetadataScope.self, forKey: .metadataScope) ?? .document,
            postProcessingMode: try container.decodeIfPresent(CaptureVoxProcessingMode.self, forKey: .postProcessingMode) ?? .clean,
            customPostProcessingInstruction: try container.decodeIfPresent(String.self, forKey: .customPostProcessingInstruction) ?? "",
            captureProcessingEnabled: try container.decodeIfPresent(Bool.self, forKey: .captureProcessingEnabled) ?? false,
            capturePrompt: try container.decodeIfPresent(String.self, forKey: .capturePrompt) ?? "",
            captureDestinationID: try container.decodeIfPresent(UUID.self, forKey: .captureDestinationID),
            captureEntryTemplateID: try container.decodeIfPresent(UUID.self, forKey: .captureEntryTemplateID),
            capturePlacementOverride: try container.decodeIfPresent(CapturePlacement.self, forKey: .capturePlacementOverride)
        )
    }
}

public enum CaptureVoxMetadataScope: String, Codable, CaseIterable, Sendable, Identifiable {
    case document
    case entry

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .document: return "Note Frontmatter"
        case .entry: return "Inline Entry Fields"
        }
    }
}

public enum CaptureVoxProcessingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case clean
    case todoList
    case meetingNotes
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "Keep Original"
        case .clean: return "Clean Prose"
        case .todoList: return "Todo Checklist"
        case .meetingNotes: return "Meeting Notes"
        case .custom: return "Custom Instruction"
        }
    }
}

public enum CaptureVoxProcessingState: String, Codable, Sendable {
    case notRequested
    case pending
    case applied
}

public struct CaptureVoxReference: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbolName: String

    public init(id: String, name: String, symbolName: String) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
    }

    public init(profile: CaptureVoxProfile) {
        self.init(id: profile.id, name: profile.displayName, symbolName: profile.symbolName)
    }
}

public enum CaptureVoxRouteResolver {
    /// Resolves the route without mutating reusable settings.
    /// Precedence: explicit capture override → Vox default → library default → first route.
    public static func destinationID(
        selectionMode: CaptureDestinationSelectionMode,
        explicitDestinationID: UUID?,
        profile: CaptureVoxProfile?,
        destinations: [CaptureDestination],
        libraryDefaultDestinationID: UUID?
    ) -> UUID? {
        let validIDs = Set(destinations.map(\.id))
        if selectionMode == .explicit,
           let explicitDestinationID,
           validIDs.contains(explicitDestinationID) {
            return explicitDestinationID
        }
        if let voxDestinationID = profile?.captureDestinationID,
           validIDs.contains(voxDestinationID) {
            return voxDestinationID
        }
        if let libraryDefaultDestinationID,
           validIDs.contains(libraryDefaultDestinationID) {
            return libraryDefaultDestinationID
        }
        return destinations.first?.id
    }
}

/// Lightweight access to the existing App Group Vox records. Unknown
/// recording-only fields are ignored by `CaptureVoxProfile` decoding.
public enum CaptureVoxProfileStore {
    public static let profilesKey = "recordingFlows"
    public static let selectedProfileIDKey = "selectedRecordingFlowId"
    public static let selectedCaptureProfileIDKey = "selectedCaptureVoxId"
    public static let defaultProfileID = "general"

    public static func loadProfiles(defaults: UserDefaults?) -> [CaptureVoxProfile] {
        guard let data = defaults?.data(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([CaptureVoxProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    public static func enabledProfiles(defaults: UserDefaults?) -> [CaptureVoxProfile] {
        loadProfiles(defaults: defaults).filter(\.isEnabled)
    }

    public static func selectedProfileID(defaults: UserDefaults?) -> String? {
        let enabled = enabledProfiles(defaults: defaults)
        guard !enabled.isEmpty else { return nil }
        let captureStored = defaults?.string(forKey: selectedCaptureProfileIDKey)
        if enabled.contains(where: { $0.id == captureStored }) { return captureStored }
        let recordingStored = defaults?.string(forKey: selectedProfileIDKey)
        return enabled.contains(where: { $0.id == recordingStored }) ? recordingStored : enabled.first?.id
    }

    public static func selectCaptureProfile(id: String, defaults: UserDefaults?) {
        guard enabledProfiles(defaults: defaults).contains(where: { $0.id == id }) else { return }
        defaults?.set(id, forKey: selectedCaptureProfileIDKey)
    }

    public static func profile(id: String?, defaults: UserDefaults?) -> CaptureVoxProfile? {
        guard let id else { return nil }
        return loadProfiles(defaults: defaults).first(where: { $0.id == id })
    }
}
