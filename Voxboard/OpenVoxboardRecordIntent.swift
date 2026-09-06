import AppIntents
import Foundation
import VoxboardShared

// MARK: - Capture Preset App Entity (legacy type name retained for App Intents)

struct VoxEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Capture Preset"
    static var defaultQuery = VoxEntityQuery()

    let id: String
    let name: String
    let symbolName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            image: .init(systemName: symbolName)
        )
    }

    init(id: String, name: String, symbolName: String) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
    }

    init(flow: CapturePreset) {
        self.init(id: flow.id, name: flow.displayName, symbolName: flow.symbolName)
    }

    static var fallback: VoxEntity {
        VoxEntity(flow: CapturePresetStore.selectedFlow())
    }

    static func resolved(_ entity: VoxEntity?) -> VoxEntity {
        guard let id = entity?.id,
              let flow = CapturePresetStore.flow(id: id),
              flow.isEnabled else {
            return fallback
        }
        return VoxEntity(flow: flow)
    }
}

struct VoxEntityQuery: EntityQuery, EnumerableEntityQuery {
    func entities(for identifiers: [VoxEntity.ID]) async throws -> [VoxEntity] {
        let requested = Set(identifiers)
        return Self.enabledVoxes().filter { requested.contains($0.id) }
    }

    func suggestedEntities() async throws -> [VoxEntity] {
        Self.enabledVoxes()
    }

    func allEntities() async throws -> [VoxEntity] {
        Self.enabledVoxes()
    }

    func defaultResult() async -> VoxEntity? {
        VoxEntity.fallback
    }

    private static func enabledVoxes() -> [VoxEntity] {
        let enabled = CapturePresetStore.loadFlows()
            .filter(\.isEnabled)
            .map(VoxEntity.init(flow:))
        return enabled.isEmpty ? CapturePresetStore.defaultFlows.map(VoxEntity.init(flow:)) : enabled
    }
}

// MARK: - Record Intent

@available(iOS 17.0, *)
struct OpenVoxboardRecordIntent: AppIntent {
    static let title: LocalizedStringResource = "Record with Vox.md"
    static let description: IntentDescription = "Opens Vox.md and starts recording with the selected Capture Preset."
    static var openAppWhenRun: Bool = true

    /// Chained fallbacks from background intents (such as the iOS 26 recording
    /// toggle) rely on this bringing the app forward; declaring it explicitly
    /// keeps that contract under the unified intents model.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Preset", description: "The Capture Preset to use for this recording.")
    var vox: VoxEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Record with \(\.$vox)")
    }

    init() {}

    init(vox: VoxEntity?) {
        self.vox = vox
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard AppConstants.lockScreenQuickRecordEnabled else { return .result() }

        // Signal the app to start recording, preserving the configured preset
        // so Lock Screen and Control Center actions use the same workflow.
        if let flowId = resolvedFlowId {
            AppConstants.sharedDefaults?.set(flowId, forKey: AppConstants.pendingWidgetRecordFlowIdKey)
        } else {
            AppConstants.sharedDefaults?.removeObject(forKey: AppConstants.pendingWidgetRecordFlowIdKey)
        }
        AppConstants.sharedDefaults?.set(true, forKey: AppConstants.pendingWidgetRecordKey)
        return .result()
    }

    private var resolvedFlowId: String? {
        guard let id = vox?.id,
              let flow = CapturePresetStore.flow(id: id),
              flow.isEnabled else {
            return nil
        }
        return flow.id
    }
}

// MARK: - Pending Widget Recording Selection

struct WidgetRecordingFlowSelection {
    let flowID: String
    let explicitlyRequestedFlow: CapturePreset?

    static func persistRequestedFlowID(
        from url: URL,
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) {
        let requestedFlowID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "flowId" })?
            .value
        if let requestedFlowID, !requestedFlowID.isEmpty {
            defaults?.set(requestedFlowID, forKey: AppConstants.pendingWidgetRecordFlowIdKey)
        } else {
            defaults?.removeObject(forKey: AppConstants.pendingWidgetRecordFlowIdKey)
        }
    }

    static func resolve(
        requestedFlowID: String?,
        defaults: UserDefaults? = AppConstants.sharedDefaults
    ) -> WidgetRecordingFlowSelection {
        if let requestedFlowID,
           let flow = CapturePresetStore.flow(id: requestedFlowID, defaults: defaults),
           flow.isEnabled {
            return WidgetRecordingFlowSelection(
                flowID: flow.id,
                explicitlyRequestedFlow: flow
            )
        }

        return WidgetRecordingFlowSelection(
            flowID: CapturePresetStore.selectedFlowId(defaults: defaults),
            explicitlyRequestedFlow: nil
        )
    }
}

// MARK: - Control Configuration Intent

@available(iOS 18.0, *)
struct SelectVoxboardRecordVoxIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Capture Preset"
    static let description = IntentDescription("Choose the Capture Preset this control uses when starting a recording.")

    @Parameter(title: "Preset", description: "The Capture Preset to use for recordings started by this control.")
    var vox: VoxEntity?

    init() {}

    init(vox: VoxEntity?) {
        self.vox = vox
    }
}
