import AppIntents
import SwiftUI
import VoxboardShared
import WidgetKit

// MARK: - Control Widget (iOS 18+ lock screen bottom slots)

@available(iOS 18.0, *)
struct VoxboardRecordControl: ControlWidget {
    static let kind = "VoxboardRecordControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { isEnabled in
            ControlWidgetButton(action: OpenVoxboardRecordIntent()) {
                Label(isEnabled ? "Record" : "Off", systemImage: isEnabled ? "mic.fill" : "mic.slash")
                    .controlWidgetActionHint(isEnabled ? "Record with Voxboard" : "Disabled in Voxboard Settings")
            }
            .disabled(!isEnabled)
        }
        .displayName("Voxboard Record")
        .description("Tap to open Voxboard and start recording.")
    }

    private struct Provider: ControlValueProvider {
        var previewValue: Bool { true }

        func currentValue() async throws -> Bool {
            AppConstants.lockScreenQuickRecordEnabled
        }
    }
}
