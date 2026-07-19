import SwiftUI
import VoxboardShared

// MARK: - Geist dark-theme tokens

private enum K {
    static let error = Color(red: 1.0, green: 0.337, blue: 0.373)

    static func label(_ style: Font.TextStyle = .callout) -> Font {
        .system(style, design: .default, weight: .medium)
    }
    static func caption(_ style: Font.TextStyle = .footnote) -> Font {
        .system(style, design: .default, weight: .regular)
    }
}

// MARK: - Toolbar View

/// Compact Geist toolbar: model navigator, status, waveform, and action.
struct VoiceToolbarView: View {
    @Bindable var voiceState: VoiceKeyboardState
    let hasFullAccess: Bool

    @State private var modelChangeCount = 0

    var body: some View {
        HStack(spacing: 10) {
            modelNavigator
            statusLabel
            Spacer()
            if voiceState.status == .recording {
                SoundWaveView(levels: voiceState.audioLevels)
                    .transition(.opacity)
            }
            actionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.clear)
        .onChange(of: voiceState.status) { old, new in
            if new == .recording || new == .transcribing {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } else if old == .transcribing, case .idle = new {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else if case .error = new {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
        .onChange(of: modelChangeCount) {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    // MARK: - Model Navigator  [< MODEL >]

    private var modelNavigator: some View {
        HStack(spacing: 0) {
            // Prev
            Button(action: { voiceState.previousModel(); modelChangeCount += 1 }) {
                Text("‹")
                    .font(K.label(.subheadline))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)

            // Center: model name or mic icon
            ZStack {
                switch voiceState.status {
                case .recording:
                    Rectangle()
                        .fill(K.error)
                        .frame(width: 6, height: 6)
                case .transcribing:
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.secondary)
                default:
                    Image(systemName: "mic.fill")
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 28)

            // Next
            Button(action: { voiceState.nextModel(); modelChangeCount += 1 }) {
                Text("›")
                    .font(K.label(.subheadline))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Status Label

    private var statusLabel: some View {
        Group {
            switch voiceState.status {
            case .idle:
                Text(voiceState.currentModelName)
            case .appNotListening:
                Text("Open Vox.md")
            case .recording:
                if let volatile = voiceState.volatileTranscription, !volatile.isEmpty {
                    Text(volatile)
                } else {
                    Text(formatDuration(voiceState.recordingDuration))
                        .monospacedDigit()
                }
            case .transcribing:
                Text("Transcribing…")
            case .error(let msg):
                Text(msg)
                    .foregroundColor(K.error)
            case .noModel:
                Text("Open Vox.md")
                    .foregroundColor(K.error)
            case .needsFullAccess:
                Text("Enable Full Access")
                    .foregroundColor(K.error)
            }
        }
        .font(K.caption())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        switch voiceState.status {
        case .recording:
            // Stop button — error color icon, no background
            Button(action: { voiceState.stopRecording() }) {
                Image(systemName: "stop.fill")
                    .font(.system(.title3, weight: .bold))
                    .foregroundColor(K.error)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

        case .transcribing:
            // Spinner, no background
            ProgressView()
                .scaleEffect(0.7)
                .tint(.secondary)
                .frame(width: 32, height: 32)

        case .appNotListening, .noModel:
            // Mic icon — prompts opening the app to start listening or prepare transcription.
            Button(action: { voiceState.openApp(hasFullAccess: hasFullAccess) }) {
                Image(systemName: "mic.fill")
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

        default:
            // Mic icon — start recording
            Button(action: { voiceState.startRecording(hasFullAccess: hasFullAccess) }) {
                Image(systemName: "mic.fill")
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ d: TimeInterval) -> String {
        String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
    }
}
