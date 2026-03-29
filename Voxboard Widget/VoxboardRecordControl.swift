import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Control Widget (iOS 18+ lock screen bottom slots)

@available(iOS 18.0, *)
struct VoxboardRecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "VoxboardRecordControl") {
            ControlWidgetButton(action: OpenVoxboardRecordIntent()) {
                Label("Record", systemImage: "mic.fill")
            }
        }
        .displayName("Voxboard Record")
        .description("Tap to open Voxboard and start recording.")
    }
}
