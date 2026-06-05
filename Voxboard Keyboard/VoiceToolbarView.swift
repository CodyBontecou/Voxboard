import SwiftUI
import VoxboardShared

// MARK: - Local design tokens (keyboard extension cannot import BrutalTheme from main app)

private enum K {
    static let bg       = Color(red: 0,    green: 0,    blue: 0)
    static let surface  = Color(white: 0.08)
    static let border   = Color(white: 0.18)
    static let borderHi = Color(white: 0.32)
    static let text     = Color.white
    static let muted    = Color(white: 0.72)
    static let faint    = Color(white: 0.60)
    static let error    = Color(red: 1.0, green: 0.271, blue: 0.227)

    static func label(_ style: Font.TextStyle = .callout) -> Font {
        .system(style, design: .monospaced, weight: .semibold)
    }
    static func caption(_ style: Font.TextStyle = .footnote) -> Font {
        .system(style, design: .monospaced, weight: .regular)
    }
}

// MARK: - Toolbar View

/// Brutal keyboard toolbar: model navigator · status · waveform · action button.
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
                .overlay(Rectangle().stroke(K.borderHi, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recording Vox: \(voiceState.currentFlowName). Tap to change Vox.")
    }

    // MARK: - Status Label

    private var statusLabel: some View {
        Group {
            switch voiceState.status {
            case .idle:
                Text(voiceState.currentModelName.uppercased())
            case .appNotListening:
                Text("OPEN VOXBOARD")
            case .recording:
                Text(formatDuration(voiceState.recordingDuration))
                    .monospacedDigit()
            case .transcribing:
                Text("TRANSCRIBING...")
            case .error(let msg):
                Text(msg.uppercased())
                    .foregroundColor(K.error)
            case .noModel:
                Text("OPEN VOXBOARD")
                    .foregroundColor(K.error)
            case .needsFullAccess:
                Text("ENABLE FULL ACCESS")
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
