import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Control Widget (iOS 18+ lock screen bottom slots / Control Center)

@available(iOS 18.0, *)
struct VoxboardQuickCaptureControl: ControlWidget {
    static let kind = "VoxboardQuickCaptureControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenVoxboardQuickCaptureIntent()) {
                Label("Quick Capture", systemImage: "square.and.pencil")
                    .controlWidgetActionHint("Open Quick Capture")
            }
        }
        .displayName("Quick Capture")
        .description("Open a durable Markdown capture draft in Vox.md.")
    }
}
