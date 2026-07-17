import SwiftUI
import UIKit

struct QuickCaptureVoiceView: View {
    @Bindable var session: QuickCaptureVoiceSession

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .idle, .recording:
                    recordingView
                case .saving:
                    savingView
                case .transcribing:
                    transcribingView
                case .review:
                    reviewView
                case .error(let message):
                    errorView(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brutal.bg.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Task {
                            await session.cancel()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel voice recording")
                }
            }
        }
        .interactiveDismissDisabled(
            session.phase == .recording
                || session.phase == .saving
                || session.phase == .transcribing
        )
        .task {
            if session.phase == .idle { await session.start() }
        }
    }

    private var navigationTitle: String {
        switch session.phase {
        case .recording, .idle: return String(localized: "Voice Recording")
        case .saving: return String(localized: "Saving Recording")
        case .transcribing: return String(localized: "Generating Transcript")
        case .review: return String(localized: "Voice Recording")
        case .error: return String(localized: "Voice Recording")
        }
    }

    private var recordingView: some View {
        VStack(spacing: 28) {
            Spacer()
            Text(session.phase == .recording ? "Start talking…" : "Preparing microphone…")
                .font(Brutal.heading(.title2))

            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<12, id: \.self) { index in
                    Capsule()
                        .fill(Brutal.text)
                        .frame(width: 5, height: barHeight(index))
                        .animation(.easeOut(duration: 0.08), value: session.level)
                }
            }
            .frame(height: 72)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Microphone level")
            .accessibilityValue(session.level > 0.15 ? "Speech detected" : "Quiet")

            Text(durationLabel(session.elapsed))
                .font(.system(size: 42, weight: .light, design: .monospaced))
                .accessibilityLabel("Recording duration \(durationLabel(session.elapsed))")

            Toggle("Generate Transcript", isOn: $session.generateTranscript)
                .tint(Brutal.text)
                .disabled(!session.hasDownloadedModel)
                .padding(.horizontal, 28)

            if !session.hasDownloadedModel {
                Text("Download a model to enable on-device transcription. Audio recording still works.")
                    .font(Brutal.caption())
                    .foregroundStyle(Brutal.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Button {
                Task { await session.finishRecording() }
            } label: {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BrutalButtonStyle(variant: .primary))
            .disabled(session.phase != .recording)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("capture_voice_done")
            Spacer()
        }
    }

    private var savingView: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Saving the recording to your durable draft…")
                .font(Brutal.body())
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
    }

    private var transcribingView: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Transcribing entirely on this device…")
                .font(Brutal.body())
            Text("The recording remains available even if transcription fails.")
                .font(Brutal.caption())
                .foregroundStyle(Brutal.muted)
            Spacer()
        }
        .padding(24)
    }

    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()

            if let transcript = session.transcript {
                ScrollView {
                    Text(transcript)
                        .font(Brutal.body())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 280)
                .padding(14)
                .background(Brutal.surface)
                .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 72, weight: .thin))
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }

            if let message = session.transcriptionMessage {
                Text(message)
                    .font(Brutal.caption())
                    .foregroundStyle(Brutal.muted)
            }

            Button {
                session.togglePlayback()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    Text(durationLabel(session.duration)).monospacedDigit()
                    Spacer()
                    Text(session.isPlaying ? "Pause" : "Play")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(BrutalButtonStyle(variant: .secondary))

            HStack(spacing: 10) {
                Button {
                    Task { await session.retry() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BrutalButtonStyle(variant: .secondary))

                if let transcript = session.transcript {
                    Button {
                        UIPasteboard.general.string = transcript
                        UIAccessibility.post(notification: .announcement, argument: "Transcript copied")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrutalButtonStyle(variant: .secondary))
                }
            }

            Button {
                insert()
            } label: {
                Label("Insert", systemImage: "text.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BrutalButtonStyle(variant: .primary))
            .disabled(session.stagedAsset == nil)
            .accessibilityIdentifier("capture_voice_insert")
            Spacer()
        }
        .padding(20)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
            Text(message)
                .font(Brutal.body())
                .multilineTextAlignment(.center)
            Button {
                Task { await session.retry() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BrutalButtonStyle(variant: .primary))
            Spacer()
        }
        .padding(24)
    }

    private func insert() {
        guard session.stagedAsset != nil else { return }
        session.markInsertedAndCleanup()
        UIAccessibility.post(notification: .announcement, argument: "Voice recording attached")
        dismiss()
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let shape = 0.35 + 0.65 * abs(sin(Double(index + 1) * 1.7))
        return 8 + CGFloat(shape) * 58 * CGFloat(max(0.08, session.level))
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let safe = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", safe / 60, safe % 60)
    }
}
