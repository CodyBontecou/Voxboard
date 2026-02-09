import SwiftUI
import VoxVaultShared

/// The main app screen — centered around the always-on listening mode.
///
/// The user taps "Start Listening" once. After that, the microphone stays active
/// in the background and the keyboard controls everything. The user only needs
/// to return here to stop listening, view history, or change settings.
struct HomeView: View {
    @Environment(ModelManager.self) private var modelManager
    @Environment(TranscriptStore.self) private var transcriptStore

    @Bindable var persistentRecorder: PersistentRecorder
    @Binding var pendingKeyboardLaunch: Bool

    @State private var showHistory = false
    @State private var showSettings = false
    @State private var micPermissionGranted = false
    @State private var pulseAnimation = false

    /// Tracks the keyboard-launch flow: nil = normal launch, .starting/.ready = overlay shown.
    @State private var keyboardLaunchPhase: KeyboardLaunchPhase? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerContent
                Spacer()
                historyHint
                listenButton
            }

            // Keyboard-launch overlay
            if let phase = keyboardLaunchPhase {
                KeyboardLaunchOverlay(phase: phase)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: keyboardLaunchPhase)
        .gesture(
            DragGesture(minimumDistance: 40, coordinateSpace: .local)
                .onEnded { value in
                    // Swipe up: negative vertical translation, more vertical than horizontal
                    if value.translation.height < -40,
                       abs(value.translation.height) > abs(value.translation.width) {
                        showHistory = true
                    }
                }
        )
        .sheet(isPresented: $showHistory) {
            HistoryView()
                .environment(transcriptStore)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(modelManager)
        }
        .task {
            micPermissionGranted = await AudioRecorder.requestMicrophonePermission()
        }
        .onChange(of: pendingKeyboardLaunch) { _, isPending in
            if isPending {
                pendingKeyboardLaunch = false
                handleKeyboardLaunch()
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // Listening status indicator
            listeningBadge

            Spacer()

            // Title
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14))
                Text("VoxVault")
                    .font(.system(size: 17, weight: .medium))
            }
            .foregroundColor(.white)

            Spacer()

            // Settings
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var listeningBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(persistentRecorder.isListening ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            Text(persistentRecorder.isListening ? "Listening" : "Off")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(persistentRecorder.isListening ? .green : .gray)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }

    // MARK: - Center Content

    @ViewBuilder
    private var centerContent: some View {
        if persistentRecorder.isListening {
            listeningActiveView
        } else if !micPermissionGranted {
            micPermissionView
        } else {
            readyToListenView
        }
    }

    private var listeningActiveView: some View {
        VStack(spacing: 24) {
            // Pulsing waveform icon
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.08))
                    .frame(width: 140, height: 140)
                    .scaleEffect(pulseAnimation ? 1.15 : 1.0)
                    .opacity(pulseAnimation ? 0.4 : 0.8)
                    .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: pulseAnimation)

                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 100, height: 100)

                Image(systemName: "waveform")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundColor(.green)
            }
            .onAppear { pulseAnimation = true }
            .onDisappear { pulseAnimation = false }

            VStack(spacing: 12) {
                Text("Listening")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)

                if persistentRecorder.isSegmentActive {
                    Text("Recording segment…")
                        .font(.system(size: 15))
                        .foregroundColor(.orange)
                } else if persistentRecorder.isTranscribing {
                    Text("Transcribing…")
                        .font(.system(size: 15))
                        .foregroundColor(.blue)
                } else {
                    Text("Switch to any app and use the keyboard\nto record and transcribe your voice.")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
            }

            // Inline status for active operations
            if persistentRecorder.isSegmentActive {
                Text(formatDuration(persistentRecorder.segmentDuration))
                    .font(.system(size: 36, weight: .light, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
    }

    private var readyToListenView: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.3))

            VStack(spacing: 8) {
                Text("Ready to Listen")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)

                Text("Tap below to start always-on listening.\nThen use the keyboard to record anytime.")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
    }

    private var micPermissionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.slash")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.3))
            Text("Microphone access required")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    // MARK: - History Hint

    private var historyHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.up")
            Text("Swipe up to see your history")
            Image(systemName: "chevron.up")
        }
        .font(.system(size: 14))
        .foregroundColor(.white.opacity(0.35))
        .padding(.bottom, 24)
        .onTapGesture { showHistory = true }
    }

    // MARK: - Listen Button

    private var listenButton: some View {
        Button(action: { toggleListening() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(persistentRecorder.isListening
                          ? Color.red.opacity(0.15)
                          : Color.green.opacity(0.15))
                    .frame(width: 200, height: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28)
                            .strokeBorder(
                                persistentRecorder.isListening
                                    ? Color.red.opacity(0.3)
                                    : Color.green.opacity(0.3),
                                lineWidth: 1
                            )
                    )

                HStack(spacing: 10) {
                    Image(systemName: persistentRecorder.isListening ? "stop.fill" : "play.fill")
                        .font(.system(size: 16))
                    Text(persistentRecorder.isListening ? "Stop Listening" : "Start Listening")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(persistentRecorder.isListening ? .red : .green)
            }
        }
        .padding(.bottom, 48)
    }

    // MARK: - Actions

    private func toggleListening() {
        if persistentRecorder.isListening {
            persistentRecorder.stopListening()
            AppConstants.sharedDefaults?.set(false, forKey: "autoListenEnabled")
            pulseAnimation = false
        } else {
            persistentRecorder.startListening()
        }
    }

    // MARK: - Keyboard Launch Flow

    /// Called by VoxVaultApp when opened via `voxvault://listen`.
    func handleKeyboardLaunch() {
        keyboardLaunchPhase = .starting

        // Small delay so the overlay is visible before we do audio setup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !persistentRecorder.isListening {
                persistentRecorder.startListening()
            }

            withAnimation {
                keyboardLaunchPhase = persistentRecorder.isListening ? .ready : .error
            }

            // Auto-dismiss shortly after
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation {
                    keyboardLaunchPhase = nil
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ d: TimeInterval) -> String {
        let m = Int(d) / 60
        let s = Int(d) % 60
        let t = Int((d * 10).truncatingRemainder(dividingBy: 10))
        return String(format: "%d:%02d.%d", m, s, t)
    }
}

// MARK: - Keyboard Launch Phase

enum KeyboardLaunchPhase: Equatable {
    case starting
    case ready
    case error
}

// MARK: - Keyboard Launch Overlay

/// Full-screen overlay shown when the app is opened from the keyboard.
/// Shows a brief loading state, then a "Ready" confirmation before auto-dismissing.
private struct KeyboardLaunchOverlay: View {
    let phase: KeyboardLaunchPhase

    @State private var checkmarkScale: CGFloat = 0.3

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                icon
                text

                Spacer()
                Spacer()
            }
            .padding(32)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch phase {
        case .starting:
            ZStack {
                Circle()
                    .stroke(Color.green.opacity(0.15), lineWidth: 4)
                    .frame(width: 100, height: 100)

                ProgressView()
                    .scaleEffect(1.8)
                    .tint(.green)
            }

        case .ready:
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 100, height: 100)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.green)
                    .scaleEffect(checkmarkScale)
            }
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    checkmarkScale = 1.0
                }
            }

        case .error:
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.12))
                    .frame(width: 100, height: 100)

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private var text: some View {
        switch phase {
        case .starting:
            VStack(spacing: 10) {
                Text("Starting Microphone…")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)

                Text("Setting up always-on listening")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.4))
            }

        case .ready:
            VStack(spacing: 10) {
                Text("Ready!")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text("Go back to your app and\ntap Record on the keyboard.")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

        case .error:
            VStack(spacing: 10) {
                Text("Could Not Start")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)

                Text("Check microphone permissions\nin Settings.")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
    }
}
