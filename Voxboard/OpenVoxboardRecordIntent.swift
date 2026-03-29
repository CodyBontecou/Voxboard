import AppIntents
import Foundation

@available(iOS 18.0, *)
struct OpenVoxboardRecordIntent: AppIntent {
    static let title: LocalizedStringResource = "Record with Voxboard"
    static let description: IntentDescription = "Opens Voxboard and starts recording."
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Signal the app to start recording
        let defaults = UserDefaults(suiteName: "group.bontecou.Voxboard")
        defaults?.set(true, forKey: "pendingWidgetRecord")
        return .result()
    }
}
