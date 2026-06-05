import AppIntents
import Foundation
import VoxboardShared

@available(iOS 18.0, *)
struct OpenVoxboardRecordIntent: AppIntent {
    static let title: LocalizedStringResource = "Record with Voxboard"
    static let description: IntentDescription = "Opens Voxboard and starts recording."
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard AppConstants.lockScreenQuickRecordEnabled else { return .result() }

        // Signal the app to start recording
        AppConstants.sharedDefaults?.set(true, forKey: "pendingWidgetRecord")
        return .result()
    }
}
