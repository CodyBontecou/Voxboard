import AppIntents
import Foundation
import VoxboardShared

@available(iOS 17.0, *)
struct StartRecordingLiveActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Starts a Vox.md recording segment.")

    init() {}

    func perform() async throws -> some IntentResult {
        guard AppConstants.liveActivityMonitorEnabled else { return .result() }

        let modelId = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
        let language = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey)
        let flowId = CapturePresetStore.selectedFlowId()
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
    static let description = IntentDescription("Stops the active Vox.md recording segment.")

    @Parameter(title: "Recording")
    var requestId: String?

    init() {
        requestId = nil
    }

    init(requestId: String?) {
        self.requestId = requestId
    }

    func perform() async throws -> some IntentResult {
        // Bind Stop to the segment displayed by this exact activity. A stale
        // duplicate must never stop a newer recording that reused the monitor.
        guard let requestId, !requestId.isEmpty else { return .result() }
        let cmd = LiveActivityCommandBuilder.buildStopCommand(requestId: requestId)
        LiveActivityCommandBuilder.enqueue(cmd)
        return .result()
    }
}
