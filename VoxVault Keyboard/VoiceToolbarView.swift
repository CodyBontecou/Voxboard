import SwiftUI
import VoxVaultShared

/// The custom toolbar that sits above the KeyboardKit keyboard.
/// Layout matches the design: [< 🎤 >] ModelName ... [▶ Start]
struct VoiceToolbarView: View {
    @Bindable var voiceState: VoiceKeyboardState
    let hasFullAccess: Bool
    var onTranscription: @MainActor (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            modelNavigator
            statusLabel
            Spacer()
            actionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Model Navigator: [< 🎤 >]

    private var modelNavigator: some View {
        HStack(spacing: 8) {
            Button(action: { voiceState.previousModel() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.7))
            }

            micIcon

            Button(action: { voiceState.nextModel() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(.systemGray5))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var micIcon: some View {
        switch voiceState.status {
        case .recording:
            Image(systemName: "mic.fill")
                .font(.system(size: 15))
                .foregroundColor(.red)
                .symbolEffect(.pulse, isActive: true)
        case .transcribing:
            ProgressView()
                .scaleEffect(0.7)
        default:
            Image(systemName: "mic")
                .font(.system(size: 15))
                .foregroundColor(.primary)
        }
    }

    // MARK: - Status Label

    private var statusLabel: some View {
        Group {
            switch voiceState.status {
            case .idle:
                Text(voiceState.currentModelName)
            case .recording:
                Text(formatDuration(voiceState.recordingDuration))
                    .monospacedDigit()
            case .transcribing:
                Text("Transcribing...")
            case .error(let msg):
                Text(msg)
                    .foregroundColor(.red)
            case .noModel:
                Text("Open VoxVault to set up")
                    .foregroundColor(.orange)
            case .needsFullAccess:
                Text("Enable Full Access in Settings")
                    .foregroundColor(.orange)
            }
        }
        .font(.system(size: 14))
        .foregroundColor(.secondary)
        .lineLimit(1)
    }

    // MARK: - Action Button: [▶ Start] / [■ Stop]

    private var actionButton: some View {
        Button(action: {
            voiceState.toggleRecording(
                hasFullAccess: hasFullAccess,
                onTranscription: onTranscription
            )
        }) {
            HStack(spacing: 5) {
                switch voiceState.status {
                case .recording:
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                    Text("Stop")
                        .font(.system(size: 14, weight: .medium))
                case .transcribing:
                    ProgressView()
                        .scaleEffect(0.6)
                default:
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 10))
                    Text("Start")
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(.systemGray5))
            .clipShape(Capsule())
        }
        .disabled(voiceState.status == .transcribing)
    }

    // MARK: - Helpers

    private func formatDuration(_ d: TimeInterval) -> String {
        let s = Int(d)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
