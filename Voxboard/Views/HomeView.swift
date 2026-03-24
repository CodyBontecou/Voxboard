import SwiftUI
import VoxboardShared

/// Main screen — brutal black/white aesthetic matching imghost.isolated.tech.
struct HomeView: View {
    @Environment(ModelManager.self) private var modelManager
    @Environment(TranscriptStore.self) private var transcriptStore

    @Bindable var persistentRecorder: PersistentRecorder
    @Binding var pendingKeyboardLaunch: Bool

    @State private var showHistory = false
    @State private var showSettings = false
    @State private var micPermissionGranted = false
    @State private var keyboardLaunchPhase: KeyboardLaunchPhase? = nil

    var body: some View {
        ZStack {
            Brutal.bg.ignoresSafeArea()

            BrutalGridBackground()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                BrutalDivider()
                Spacer()
                centerContent
                Spacer()
                BrutalDivider()
                bottomArea
            }

            if let phase = keyboardLaunchPhase {
                KeyboardLaunchOverlay(phase: phase)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: keyboardLaunchPhase)
        .gesture(
            DragGesture(minimumDistance: 40, coordinateSpace: .local)
                .onEnded { val in
                    if val.translation.height < -40,
                       abs(val.translation.height) > abs(val.translation.width) {
                        showHistory = true
                    }
                }
        )
        .sheet(isPresented: $showHistory) {
            HistoryView().environment(transcriptStore)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(modelManager)
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
            BrutalStatusBadge(
                label: persistentRecorder.isListening ? "Listening" : "Off",
                isActive: persistentRecorder.isListening
            )
            Spacer()
            Text("VOXBOARD")
                .font(Brutal.label(13))
                .foregroundColor(Brutal.text)
            Spacer()
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Brutal.faint)
                    .frame(width: 34, height: 34)
                    .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Center Content

    @ViewBuilder
    private var centerContent: some View {
        if !micPermissionGranted {
            noMicView
        } else if persistentRecorder.isListening {
            listeningContent
        } else {
            standbyView
        }
    }

    // MARK: Standby

    private var standbyView: some View {
        VStack(spacing: 28) {
            BrutalSectionLabel(number: "01", title: "Status")
            VStack(spacing: 8) {
                Text("STANDBY.")
                    .font(Brutal.display(60))
                    .foregroundColor(Brutal.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Text("Tap START LISTENING below")
                    .font(Brutal.body(12))
                    .foregroundColor(Brutal.faint)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: No Mic

    private var noMicView: some View {
        VStack(spacing: 20) {
            BrutalSectionLabel(number: "01", title: "Status")
            VStack(spacing: 8) {
                Text("NO MIC.")
                    .font(Brutal.display(52))
                    .foregroundColor(Brutal.faint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Text("Enable microphone access in Settings")
                    .font(Brutal.body(12))
                    .foregroundColor(Brutal.faint)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: Listening states

    @ViewBuilder
    private var listeningContent: some View {
        if persistentRecorder.isSegmentActive {
            recordingView
        } else if persistentRecorder.isTranscribing {
            transcribingView
        } else if let result = persistentRecorder.lastTranscriptionResult {
            resultView(result)
        } else {
            listeningIdleView
        }
    }

    private var listeningIdleView: some View {
        VStack(spacing: 28) {
            BrutalSectionLabel(number: "01", title: "Status")
            VStack(spacing: 16) {
                Text("LISTENING.")
                    .font(Brutal.display(52))
                    .foregroundColor(Brutal.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                IdleWaveformView()
                Text("Keyboard mic ready in any app")
                    .font(Brutal.body(12))
                    .foregroundColor(Brutal.faint)
            }
            Button(action: {
                persistentRecorder.lastTranscriptionResult = nil
                persistentRecorder.startInAppSegment()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill").font(.system(size: 11))
                    Text("RECORD IN APP")
                }
            }
            .buttonStyle(BrutalButtonStyle(variant: .secondary))
            .frame(maxWidth: 280)
        }
        .padding(.horizontal, 24)
    }

    private var recordingView: some View {
        VStack(spacing: 24) {
            BrutalSectionLabel(number: "01", title: "Status")
            VStack(spacing: 10) {
                Text("RECORDING.")
                    .font(Brutal.display(48))
                    .foregroundColor(Brutal.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Text(formatDuration(persistentRecorder.segmentDuration))
                    .font(.system(size: 54, weight: .heavy, design: .monospaced))
                    .foregroundColor(Brutal.text)
                    .monospacedDigit()
            }
            Text("Return to your app — recording continues")
                .font(Brutal.body(11))
                .foregroundColor(Brutal.faint)
                .multilineTextAlignment(.center)
            Button(action: { persistentRecorder.stopInAppSegment() }) {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill").font(.system(size: 11))
                    Text("STOP + TRANSCRIBE")
                }
            }
            .buttonStyle(BrutalButtonStyle(variant: .destructive))
            .frame(maxWidth: 280)
        }
        .padding(.horizontal, 24)
    }

    private var transcribingView: some View {
        VStack(spacing: 24) {
            BrutalSectionLabel(number: "01", title: "Status")
            TranscribingDotsView()
            Text("Processing audio on-device")
                .font(Brutal.body(12))
                .foregroundColor(Brutal.faint)
        }
        .padding(.horizontal, 24)
    }

    private func resultView(_ result: String) -> some View {
        VStack(spacing: 24) {
            BrutalSectionLabel(number: "01", title: "Status")
            Text("DONE.")
                .font(Brutal.display(52))
                .foregroundColor(Brutal.text)
                .lineLimit(1)
                .minimumScaleFactor(0.3)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("TRANSCRIPT")
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.faint)
                    Spacer()
                    Button(action: {
                        UIPasteboard.general.string = result
                        persistentRecorder.lastTranscriptionResult = nil
                    }) {
                        Text("COPY + CLEAR")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.text)
                    }
                    .buttonStyle(.plain)
                }
                Text(result)
                    .font(Brutal.body(14))
                    .foregroundColor(Brutal.text)
                    .lineSpacing(4)
            }
            .padding(16)
            .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))

            Button(action: {
                persistentRecorder.lastTranscriptionResult = nil
                persistentRecorder.startInAppSegment()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill").font(.system(size: 11))
                    Text("RECORD AGAIN")
                }
            }
            .buttonStyle(BrutalButtonStyle(variant: .secondary))
            .frame(maxWidth: 280)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Bottom Area

    private var bottomArea: some View {
        VStack(spacing: 0) {
            Button(action: { showHistory = true }) {
                HStack(spacing: 5) {
                    Text("↑")
                    Text("HISTORY")
                }
                .font(Brutal.caption(11))
                .foregroundColor(Brutal.faint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            BrutalDivider()

            Group {
                if persistentRecorder.isListening {
                    Button(action: { toggleListening() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "stop.fill").font(.system(size: 11))
                            Text("STOP LISTENING")
                        }
                    }
                    .buttonStyle(BrutalButtonStyle(variant: .secondary))
                } else {
                    Button(action: { toggleListening() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill").font(.system(size: 11))
                            Text("START LISTENING")
                        }
                    }
                    .buttonStyle(BrutalButtonStyle(variant: .primary))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Actions

    private func toggleListening() {
        if persistentRecorder.isListening {
            persistentRecorder.stopListening()
            AppConstants.sharedDefaults?.set(false, forKey: "autoListenEnabled")
        } else {
            persistentRecorder.startListening()
        }
    }

    func handleKeyboardLaunch() {
        keyboardLaunchPhase = .starting
        DispatchQueue.main.async {
            if !persistentRecorder.isListening {
                persistentRecorder.startListening()
            }
            withAnimation {
                keyboardLaunchPhase = persistentRecorder.isListening ? nil : .error
            }
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let m = Int(d) / 60
        let s = Int(d) % 60
        let t = Int((d * 10).truncatingRemainder(dividingBy: 10))
        return String(format: "%d:%02d.%d", m, s, t)
    }
}

// MARK: - Keyboard Launch Phase

enum KeyboardLaunchPhase: Equatable {
    case starting, ready, error
}

// MARK: - Keyboard Launch Overlay

private struct KeyboardLaunchOverlay: View {
    let phase: KeyboardLaunchPhase

    var body: some View {
        ZStack {
            Brutal.bg.opacity(0.95).ignoresSafeArea()
            VStack(spacing: 32) {
                Spacer()
                phaseIcon
                phaseText
                Spacer()
                Spacer()
            }
            .padding(32)
        }
    }

    @ViewBuilder
    private var phaseIcon: some View {
        switch phase {
        case .starting:
            ZStack {
                Rectangle()
                    .fill(Brutal.surface)
                    .frame(width: 80, height: 80)
                    .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(Brutal.text)
            }
        case .ready:
            Rectangle()
                .fill(Brutal.surface)
                .frame(width: 80, height: 80)
                .overlay(
                    Text("✓")
                        .font(Brutal.heading(40))
                        .foregroundColor(Brutal.text)
                )
                .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
        case .error:
            Rectangle()
                .fill(Brutal.surface)
                .frame(width: 80, height: 80)
                .overlay(
                    Text("!")
                        .font(Brutal.heading(40))
                        .foregroundColor(Brutal.error)
                )
                .overlay(Rectangle().stroke(Brutal.error, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var phaseText: some View {
        switch phase {
        case .starting:
            VStack(spacing: 10) {
                Text("STARTING MIC")
                    .font(Brutal.heading(20))
                    .foregroundColor(Brutal.text)
                Text("Setting up always-on listening...")
                    .font(Brutal.body(12))
                    .foregroundColor(Brutal.muted)
            }
        case .ready:
            VStack(spacing: 10) {
                Text("READY.")
                    .font(Brutal.heading(28))
                    .foregroundColor(Brutal.text)
                Text("Return to your app\nand tap Record on the keyboard.")
                    .font(Brutal.body(12))
                    .foregroundColor(Brutal.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        case .error:
            VStack(spacing: 10) {
                Text("MIC ERROR.")
                    .font(Brutal.heading(24))
                    .foregroundColor(Brutal.error)
                Text("Check microphone permissions\nin Settings.")
                    .font(Brutal.body(12))
                    .foregroundColor(Brutal.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
    }
}
