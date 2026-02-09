import SwiftUI
import VoxVaultShared

/// The custom toolbar that sits above the KeyboardKit keyboard.
/// Shows model selector, status, and Start/Stop button.
///
/// In always-on mode, the Record/Stop buttons control transcription segments
/// entirely via IPC — no app switching required.
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
        .padding(.top, 6)
        .padding(.bottom, 6)
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
            Image(systemName: "brain.head.profile")
                .font(.system(size: 15))
                .foregroundColor(.red)
                .symbolEffect(.pulse, isActive: true)
        case .transcribing:
            ProgressView()
                .scaleEffect(0.7)
        default:
            Image(systemName: "brain")
                .font(.system(size: 15))
                .foregroundColor(.primary)
        }
    }

    // MARK: - Status Label

    private var statusLabel: some View {
        Group {
            switch voiceState.status {
            case .idle, .appNotListening:
                Text(voiceState.currentModelName)
            case .recording:
                Text(formatDuration(voiceState.recordingDuration))
                    .monospacedDigit()
            case .transcribing:
                Text("Transcribing…")
            case .error(let msg):
                Text(msg)
                    .foregroundColor(.red)
            case .noModel:
                Text("Open Voxboard to set up")
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
            // Red stop button — tapping stops the recording
            Button(action: { voiceState.stopRecording() }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.red)
                    .clipShape(Circle())
            }

        case .transcribing:
            // Spinner in a circle while transcribing
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 36, height: 36)
                .background(Color(.systemGray5))
                .clipShape(Circle())

        case .appNotListening:
            // Blue mic — opens app when tapped, auto-starts recording once app is ready
            Button(action: { voiceState.openApp(hasFullAccess: hasFullAccess) }) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.blue)
                    .clipShape(Circle())
            }

        default:
            // Blue mic — starts recording when tapped
            Button(action: { voiceState.startRecording(hasFullAccess: hasFullAccess) }) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.blue)
                    .clipShape(Circle())
            }
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ d: TimeInterval) -> String {
        let s = Int(d)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
