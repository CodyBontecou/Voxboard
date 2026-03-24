import SwiftUI
import VoxboardShared

// MARK: - Local design tokens (keyboard extension cannot import BrutalTheme from main app)

private enum K {
    static let bg       = Color(red: 0,    green: 0,    blue: 0)
    static let surface  = Color(white: 0.08)
    static let border   = Color(white: 0.18)
    static let borderHi = Color(white: 0.32)
    static let text     = Color.white
    static let muted    = Color(white: 0.5)
    static let faint    = Color(white: 0.28)
    static let error    = Color(red: 1.0, green: 0.271, blue: 0.227)

    static func label(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
    static func caption(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
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
        .overlay(Rectangle().fill(K.border).frame(height: 0.5), alignment: .bottom)
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
                    .font(K.label(15))
                    .foregroundColor(K.muted)
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
                        .tint(K.text)
                default:
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(K.muted)
                }
            }
            .frame(width: 20, height: 28)

            // Next
            Button(action: { voiceState.nextModel(); modelChangeCount += 1 }) {
                Text("›")
                    .font(K.label(15))
                    .foregroundColor(K.muted)
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
        }
        .overlay(Rectangle().stroke(K.border, lineWidth: 1))
        .background(K.surface)
    }

    // MARK: - Status Label

    private var statusLabel: some View {
        Group {
            switch voiceState.status {
            case .idle, .appNotListening:
                Text(voiceState.currentModelName.uppercased())
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
        .font(K.caption(11))
        .foregroundColor(K.muted)
        .lineLimit(1)
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        switch voiceState.status {
        case .recording:
            // Square stop button — error color
            Button(action: { voiceState.stopRecording() }) {
                Rectangle()
                    .fill(K.error)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(K.text)
                    )
            }
            .buttonStyle(.plain)

        case .transcribing:
            // Bordered square spinner
            ZStack {
                Rectangle()
                    .fill(K.surface)
                    .frame(width: 32, height: 32)
                    .overlay(Rectangle().stroke(K.border, lineWidth: 1))
                ProgressView()
                    .scaleEffect(0.55)
                    .tint(K.muted)
            }

        case .appNotListening:
            // Square mic button — prompts opening app
            Button(action: { voiceState.openApp(hasFullAccess: hasFullAccess) }) {
                Rectangle()
                    .fill(K.surface)
                    .frame(width: 32, height: 32)
                    .overlay(Rectangle().stroke(K.borderHi, lineWidth: 1))
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(K.text)
                    )
            }
            .buttonStyle(.plain)

        default:
            // Square mic button — start recording
            Button(action: { voiceState.startRecording(hasFullAccess: hasFullAccess) }) {
                Rectangle()
                    .fill(K.text)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(K.bg)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ d: TimeInterval) -> String {
        String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
    }
}
