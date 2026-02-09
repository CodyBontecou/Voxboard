import SwiftUI
import VoxVaultShared

/// The custom toolbar that sits above the KeyboardKit keyboard.
/// Shows model selector, status, and Start/Stop button.
struct VoiceToolbarView: View {
    @Bindable var voiceState: VoiceKeyboardState
    let hasFullAccess: Bool

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
        case .openingApp:
            Image(systemName: "mic.fill")
                .font(.system(size: 15))
                .foregroundColor(.orange)
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
            case .openingApp:
                Text("Opening VoxVault…")
            case .recording:
                Text(formatDuration(voiceState.recordingDuration))
                    .monospacedDigit()
            case .transcribing:
                Text("Transcribing…")
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

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        switch voiceState.status {
        case .recording:
            // Stop button — sends stop command to the app
            Button(action: { voiceState.stopRecording() }) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                    Text("Stop")
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.red.opacity(0.15))
                .foregroundColor(.red)
                .clipShape(Capsule())
            }

        case .openingApp:
            // Cancel button
            Button(action: { voiceState.cancelRecording() }) {
                HStack(spacing: 5) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                    Text("Cancel")
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
            }

        case .transcribing:
            // Disabled spinner
            HStack(spacing: 5) {
                ProgressView()
                    .scaleEffect(0.6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(.systemGray5))
            .clipShape(Capsule())

        default:
            // Start button — opens the app to record
            Button(action: { voiceState.startRecording(hasFullAccess: hasFullAccess) }) {
                HStack(spacing: 5) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10))
                    Text("Record")
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
            }
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ d: TimeInterval) -> String {
        let s = Int(d)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
