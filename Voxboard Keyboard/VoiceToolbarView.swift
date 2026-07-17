import SwiftUI
import VoxboardShared

// MARK: - Geist dark-theme tokens

private enum K {
    static let bg       = Color.black
    static let surface  = Color(red: 0.102, green: 0.102, blue: 0.102)
    static let border   = Color.white.opacity(0.141)
    static let borderHi = Color.white.opacity(0.239)
    static let text     = Color(red: 0.929, green: 0.929, blue: 0.929)
    static let muted    = Color(red: 0.627, green: 0.627, blue: 0.627)
    static let faint    = Color(red: 0.561, green: 0.561, blue: 0.561)
    static let error    = Color(red: 1.0, green: 0.337, blue: 0.373)

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
            flowPill
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

    // MARK: - Flow selector

    private var flowPill: some View {
        Button(action: { voiceState.nextFlow(); modelChangeCount += 1 }) {
            Text(voiceState.currentFlowShortLabel)
                .font(K.caption(.caption2))
                .foregroundColor(K.text)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(K.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(K.borderHi, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recording Vox: \(voiceState.currentFlowName). Tap to change Vox.")
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
                Text(formatDuration(voiceState.recordingDuration))
                    .monospacedDigit()
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

        case .appNotListening:
            // Mic icon — prompts opening app
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
