import AppIntents
import VoxboardShared

@available(iOS 18.0, *)
struct OpenVoxboardQuickCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Capture"
    static let description = IntentDescription("Unlocks and opens Vox.md to a durable Markdown capture draft.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppConstants.sharedDefaults?.set(true, forKey: AppConstants.pendingQuickCaptureOpenKey)
        AppConstants.sharedDefaults?.set(
            CaptureSource.widget.rawValue,
            forKey: AppConstants.pendingQuickCaptureSourceKey
        )
        AppConstants.sharedDefaults?.removeObject(forKey: AppConstants.pendingQuickCaptureInputKey)
        return .result()
    }
}
