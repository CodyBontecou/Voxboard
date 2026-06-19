import AppIntents
import WidgetKit

struct ToggleVoxboardWatchRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Record to Voxboard"
    static let description = IntentDescription("Opens Voxboard on Apple Watch to record a voice note locally.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct StartVoxboardWatchRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Record to Voxboard"
    static let description = IntentDescription("Opens Voxboard on Apple Watch to start a local voice note.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct StopVoxboardWatchRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Record to Voxboard"
    static let description = IntentDescription("Opens Voxboard on Apple Watch to stop or manage a local voice note.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
