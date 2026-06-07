import AppIntents
import Foundation
import VoxboardShared

@available(iOS 17.0, *)
struct StartRecordingLiveActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Starts a Voxboard recording segment.")

    init() {}

    func perform() async throws -> some IntentResult {
        guard AppConstants.liveActivityMonitorEnabled else { return .result() }

        let modelId = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
        let language = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey)
        let flowId = RecordingFlowStore.selectedFlowId()
        let cmd = LiveActivityCommandBuilder.buildStartCommand(
            modelId: modelId,
            language: language,
            flowId: flowId
        )
        LiveActivityCommandBuilder.enqueue(cmd)
        return .result()
    }
}

@available(iOS 17.0, *)
struct StopRecordingLiveActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the active Voxboard recording segment.")

    init() {}

    func perform() async throws -> some IntentResult {
        // The recorder uses its own stored requestId when a segment is active,
        // so any non-empty id works here.
        let cmd = LiveActivityCommandBuilder.buildStopCommand(requestId: UUID().uuidString)
        LiveActivityCommandBuilder.enqueue(cmd)
        return .result()
    }
}
