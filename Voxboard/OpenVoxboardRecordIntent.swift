import AppIntents
import Foundation
import VoxboardShared

// MARK: - Vox App Entity

struct VoxEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Vox"
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

    init(flow: RecordingFlow) {
        self.init(id: flow.id, name: flow.displayName, symbolName: flow.symbolName)
    }

    static var fallback: VoxEntity {
        VoxEntity(flow: RecordingFlowStore.selectedFlow())
    }

    static func resolved(_ entity: VoxEntity?) -> VoxEntity {
        guard let id = entity?.id,
              let flow = RecordingFlowStore.flow(id: id),
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
        let enabled = RecordingFlowStore.loadFlows()
            .filter(\.isEnabled)
            .map(VoxEntity.init(flow:))
        return enabled.isEmpty ? RecordingFlowStore.defaultFlows.map(VoxEntity.init(flow:)) : enabled
    }
}

// MARK: - Record Intent

@available(iOS 18.0, *)
struct OpenVoxboardRecordIntent: AppIntent {
    static let title: LocalizedStringResource = "Record with Voxboard"
    static let description: IntentDescription = "Opens Voxboard and starts recording with the selected Vox."
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Vox", description: "The Vox preset to use for this recording.")
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

        // Signal the app to start recording, preserving the configured Vox so
        // Focus-mode Lock Screen / Control Center controls can route directly
        // into a Dream, Meeting, or other custom workflow.
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
              let flow = RecordingFlowStore.flow(id: id),
              flow.isEnabled else {
            return nil
        }
        return flow.id
    }
}

// MARK: - Control Configuration Intent

@available(iOS 18.0, *)
struct SelectVoxboardRecordVoxIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Vox"
    static let description = IntentDescription("Choose the Vox preset this control uses when starting a recording.")

    @Parameter(title: "Vox", description: "The Vox preset to use for recordings started by this control.")
    var vox: VoxEntity?

    init() {}

    init(vox: VoxEntity?) {
        self.vox = vox
    }
}
