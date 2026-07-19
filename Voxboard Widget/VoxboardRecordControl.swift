import AppIntents
import SwiftUI
import VoxboardShared
import WidgetKit

// MARK: - Control Widget (iOS 18+ lock screen bottom slots / Control Center)

@available(iOS 18.0, *)
struct VoxboardRecordControl: ControlWidget {
    static let kind = "VoxboardRecordControl"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: Provider()) { state in
            ControlWidgetButton(action: OpenVoxboardRecordIntent(vox: state.vox)) {
                Label(
                    state.isEnabled ? state.vox.name : "Off",
                    systemImage: state.isEnabled ? state.vox.symbolName : "mic.slash"
                )
                .controlWidgetActionHint(
                    state.isEnabled
                        ? "Record with \(state.vox.name)"
                        : "Disabled in Vox.md Settings"
                )
            }
            .disabled(!state.isEnabled)
        }
        .displayName("Vox.md Record")
        .description("Start recording with a configurable Capture Preset.")
        .promptsForUserConfiguration()
    }

    struct State {
        let isEnabled: Bool
        let vox: VoxEntity
    }

    private struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: SelectVoxboardRecordVoxIntent) -> State {
            State(isEnabled: true, vox: VoxEntity.resolved(configuration.vox))
        }

        func currentValue(configuration: SelectVoxboardRecordVoxIntent) async throws -> State {
            State(
                isEnabled: AppConstants.lockScreenQuickRecordEnabled,
                vox: VoxEntity.resolved(configuration.vox)
            )
        }
    }
}
