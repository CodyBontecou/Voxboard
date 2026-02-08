import SwiftUI
import VoxVaultShared

/// The main app screen — dark, minimal, centered record button.
/// Matches the design: muted mic (top-left), "Voice >" title (center), gear (top-right),
/// big triangle record button (bottom), "swipe up for history" hint.
struct HomeView: View {
    @Environment(ModelManager.self) private var modelManager
    @Environment(TranscriptStore.self) private var transcriptStore

    @State private var recorder = AudioRecorder()
    @State private var isTranscribing = false
    @State private var lastTranscription: String?
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var micPermissionGranted = false
    @State private var pulseAnimation = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerContent
                Spacer()
                historyHint
                recordButton
            }
        }
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
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // Mic status indicator
            Button(action: { toggleRecording() }) {
                Image(systemName: recorder.isRecording ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(10)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
            }

            Spacer()

            // Title
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14))
                Text("Voice")
                    .font(.system(size: 17, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
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

    // MARK: - Center Content

    @ViewBuilder
    private var centerContent: some View {
        if isTranscribing {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white)
                Text("Transcribing...")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.5))
            }
        } else if recorder.isRecording {
            VStack(spacing: 16) {
                Circle()
                    .fill(.red)
                    .frame(width: 12, height: 12)
                    .opacity(pulseAnimation ? 0.3 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseAnimation)
                    .onAppear { pulseAnimation = true }
                    .onDisappear { pulseAnimation = false }

                Text(formatDuration(recorder.recordingDuration))
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .foregroundColor(.white)
            }
        } else if let text = lastTranscription {
            VStack(spacing: 12) {
                Text(text)
                    .font(.system(size: 17))
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button("Copy") {
                    UIPasteboard.general.string = text
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            }
        } else if !micPermissionGranted {
            VStack(spacing: 12) {
                Image(systemName: "mic.slash")
                    .font(.system(size: 40))
                    .foregroundColor(.white.opacity(0.3))
                Text("Microphone access required")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    // MARK: - History Hint

    private var historyHint: some View {
        Button(action: { showHistory = true }) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.up")
                Text("Swipe up to see your history")
                Image(systemName: "chevron.up")
            }
            .font(.system(size: 14))
            .foregroundColor(.white.opacity(0.35))
        }
        .padding(.bottom, 24)
    }

    // MARK: - Record Button

    private var recordButton: some View {
        Button(action: { toggleRecording() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.white.opacity(recorder.isRecording ? 0.2 : 0.08))
                    .frame(width: 140, height: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    )

                Image(systemName: recorder.isRecording ? "stop.fill" : "triangle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(recorder.isRecording ? .red : .white)
            }
        }
        .padding(.bottom, 48)
    }

    // MARK: - Actions

    private func toggleRecording() {
        if recorder.isRecording {
            guard let audioURL = recorder.stopRecording() else { return }
            isTranscribing = true
            lastTranscription = nil

            let modelPath = modelManager.selectedModel?.localURL?.path
            let language = modelManager.selectedLanguage
            let modelName = modelManager.selectedModel?.name ?? "Unknown"
            let duration = recorder.recordingDuration

            Task.detached(priority: .userInitiated) {
                var result: String?

                if let modelPath {
                    let ctx = WhisperContext(modelPath: modelPath)
                    result = ctx?.transcribe(audioURL: audioURL, language: language)
                }

                let transcribedText = result
                await MainActor.run {
                    isTranscribing = false
                    lastTranscription = transcribedText

                    if let transcribedText {
                        let transcript = Transcript(
                            text: transcribedText,
                            duration: duration,
                            modelUsed: modelName,
                            language: language
                        )
                        transcriptStore.add(transcript)
                    }
                }
            }
        } else {
            lastTranscription = nil
            _ = recorder.startRecording()
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
