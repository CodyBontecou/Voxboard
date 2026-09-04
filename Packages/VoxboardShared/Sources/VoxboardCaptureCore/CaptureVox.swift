import Foundation

/// A modality-neutral Capture Preset policy snapshot. The persisted legacy
/// recording-flow format intentionally uses the same coding keys, allowing
/// lightweight clients to read presets without linking the transcription and
/// export stack.
public struct CapturePresetProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbolName: String
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var staticFrontmatter: [String: String]
    /// Opt-in origin-time location capture and rendering policy. Missing legacy
    /// values decode disabled.
    public var locationPolicy: CapturePresetLocationPolicy
    /// Document frontmatter is ideal for one-note-per-capture destinations;
    /// inline entry fields keep rolling/shared notes from being relabeled.
    public var metadataScope: CapturePresetMetadataScope
    public var postProcessingMode: CapturePresetProcessingMode
    public var customPostProcessingInstruction: String
    /// Unified Apple Intelligence gate: when true (and the mode isn't Keep
    /// Original), captured text is processed on device using the selected
    /// mode, limited to the modalities selected by `captureProcessingScope`.
    public var captureProcessingEnabled: Bool
    /// Which modalities the selected processing mode applies to when the
    /// master gate is on. Missing legacy values decode as `.both`.
    public var captureProcessingScope: CapturePresetProcessingScope
    /// Optional local empty-state prompt shown when this preset is active.
    public var capturePrompt: String
    /// The owned destination inherited by captures using this preset.
    public var captureDestinationID: UUID?
    /// Legacy preset-level overrides folded into the owned route on migration.
    public var captureEntryTemplateID: UUID?
    public var capturePlacementOverride: CapturePlacement?

    public init(
        id: String,
        name: String,
        symbolName: String,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        staticFrontmatter: [String: String] = [:],
        locationPolicy: CapturePresetLocationPolicy = CapturePresetLocationPolicy(),
        metadataScope: CapturePresetMetadataScope = .document,
        postProcessingMode: CapturePresetProcessingMode = .clean,
        customPostProcessingInstruction: String = "",
        captureProcessingEnabled: Bool = false,
        captureProcessingScope: CapturePresetProcessingScope = .both,
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
        self.locationPolicy = locationPolicy
        self.metadataScope = metadataScope
        self.postProcessingMode = postProcessingMode
        self.customPostProcessingInstruction = customPostProcessingInstruction
        self.captureProcessingEnabled = captureProcessingEnabled
        self.captureProcessingScope = captureProcessingScope
        self.capturePrompt = capturePrompt
        self.captureDestinationID = captureDestinationID
        self.captureEntryTemplateID = captureEntryTemplateID
        self.capturePlacementOverride = capturePlacementOverride
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Preset" : trimmed
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
        case locationPolicy
        case metadataScope
        case postProcessingMode
        case customPostProcessingInstruction
        case captureProcessingEnabled
        case captureProcessingScope
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
            locationPolicy: try container.decodeIfPresent(CapturePresetLocationPolicy.self, forKey: .locationPolicy)
                ?? CapturePresetLocationPolicy(),
            metadataScope: try container.decodeIfPresent(CapturePresetMetadataScope.self, forKey: .metadataScope) ?? .document,
            postProcessingMode: try container.decodeIfPresent(CapturePresetProcessingMode.self, forKey: .postProcessingMode) ?? .clean,
            customPostProcessingInstruction: try container.decodeIfPresent(String.self, forKey: .customPostProcessingInstruction) ?? "",
            captureProcessingEnabled: try container.decodeIfPresent(Bool.self, forKey: .captureProcessingEnabled) ?? false,
            captureProcessingScope: try container.decodeIfPresent(CapturePresetProcessingScope.self, forKey: .captureProcessingScope) ?? .both,
            capturePrompt: try container.decodeIfPresent(String.self, forKey: .capturePrompt) ?? "",
            captureDestinationID: try container.decodeIfPresent(UUID.self, forKey: .captureDestinationID),
            captureEntryTemplateID: try container.decodeIfPresent(UUID.self, forKey: .captureEntryTemplateID),
            capturePlacementOverride: try container.decodeIfPresent(CapturePlacement.self, forKey: .capturePlacementOverride)
        )
    }
}

public enum CapturePresetMetadataScope: String, Codable, CaseIterable, Sendable, Identifiable {
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

public enum CapturePresetProcessingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case clean
    case todoList
    case meetingNotes
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return String(localized: "Keep Original", bundle: .main)
        case .clean: return String(localized: "Clean Prose", bundle: .main)
        case .todoList: return String(localized: "Todo Checklist", bundle: .main)
        case .meetingNotes: return String(localized: "Meeting Notes", bundle: .main)
        case .custom: return String(localized: "Custom Instruction", bundle: .main)
        }
    }
}

/// Which capture modalities the selected processing mode applies to when the
/// "Use Apple Intelligence" master gate is on. `.both` is the default; legacy
/// records missing the field decode as `.both` and the preset-store migration
/// refines legacy installs to their exact prior behavior.
public enum CapturePresetProcessingScope: String, Codable, CaseIterable, Sendable, Identifiable {
    case both
    case voiceOnly
    case textOnly

    public var id: String { rawValue }

    /// True when voice transcriptions (recording pipelines and capture-draft
    /// audio payloads) should be processed.
    public var appliesToVoice: Bool { self != .textOnly }

    /// True when typed or OCR-extracted Capture text should be processed.
    public var appliesToTypedText: Bool { self != .voiceOnly }

    public var displayName: String {
        switch self {
        case .both: return String(localized: "Voice & Text", bundle: .main)
        case .voiceOnly: return String(localized: "Voice Only", bundle: .main)
        case .textOnly: return String(localized: "Text Only", bundle: .main)
        }
    }
}

public enum CapturePresetProcessingState: String, Codable, Sendable {
    case notRequested
    case pending
    case applied
}

public struct CapturePresetReference: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbolName: String

    public init(id: String, name: String, symbolName: String) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
    }

    public init(profile: CapturePresetProfile) {
        self.init(id: profile.id, name: profile.displayName, symbolName: profile.symbolName)
    }
}

public enum CapturePresetRouteResolver {
    /// Resolves the route without mutating reusable settings.
    /// Precedence: explicit legacy override → Preset destination → compatibility
    /// library default → first legacy route.
    public static func destinationID(
        selectionMode: CaptureDestinationSelectionMode,
        explicitDestinationID: UUID?,
        profile: CapturePresetProfile?,
        destinations: [CaptureDestination],
        libraryDefaultDestinationID: UUID?,
        allowsLegacyFallback: Bool = true
    ) -> UUID? {
        let validIDs = Set(destinations.map(\.id))
        if selectionMode == .explicit,
           let explicitDestinationID,
           validIDs.contains(explicitDestinationID) {
            return explicitDestinationID
        }
        if let presetDestinationID = profile?.captureDestinationID,
           validIDs.contains(presetDestinationID) {
            return presetDestinationID
        }
        guard allowsLegacyFallback else { return nil }
        if let libraryDefaultDestinationID,
           validIDs.contains(libraryDefaultDestinationID) {
            return libraryDefaultDestinationID
        }
        return destinations.first?.id
    }
}

/// Lightweight access to existing App Group preset records. Unknown
/// recording-only fields are ignored by `CapturePresetProfile` decoding.
public enum CapturePresetProfileStore {
    public static let profilesKey = "recordingFlows"
    public static let selectedProfileIDKey = "selectedRecordingFlowId"
    public static let selectedCaptureProfileIDKey = "selectedCaptureVoxId"
    public static let ownedRouteMigrationVersionKey = "capturePresetOwnedRouteMigrationVersion"
    public static let currentOwnedRouteMigrationVersion = 1
    public static let defaultProfileID = "general"

    public static func hasOwnedRouteMigration(defaults: UserDefaults?) -> Bool {
        (defaults?.integer(forKey: ownedRouteMigrationVersionKey) ?? 0)
            >= currentOwnedRouteMigrationVersion
    }

    public static func loadProfiles(defaults: UserDefaults?) -> [CapturePresetProfile] {
        guard let data = defaults?.data(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([CapturePresetProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    public static func enabledProfiles(defaults: UserDefaults?) -> [CapturePresetProfile] {
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

    @discardableResult
    public static func selectCaptureProfile(id: String, defaults: UserDefaults?) -> Bool {
        guard let defaults,
              enabledProfiles(defaults: defaults).contains(where: { $0.id == id }) else {
            return false
        }
        defaults.set(id, forKey: selectedCaptureProfileIDKey)
        return defaults.string(forKey: selectedCaptureProfileIDKey) == id
    }

    public static func profile(id: String?, defaults: UserDefaults?) -> CapturePresetProfile? {
        guard let id else { return nil }
        return loadProfiles(defaults: defaults).first(where: { $0.id == id })
    }
}

// MARK: - Legacy source compatibility

public typealias CaptureVoxProfile = CapturePresetProfile
public typealias CaptureVoxMetadataScope = CapturePresetMetadataScope
public typealias CaptureVoxProcessingMode = CapturePresetProcessingMode
public typealias CaptureVoxProcessingState = CapturePresetProcessingState
public typealias CaptureVoxReference = CapturePresetReference
public typealias CaptureVoxRouteResolver = CapturePresetRouteResolver
public typealias CaptureVoxProfileStore = CapturePresetProfileStore
