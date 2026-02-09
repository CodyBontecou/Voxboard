import SwiftUI
import VoxVaultShared

// MARK: - Controller (handles recording, stop commands, transcription)

/// Manages the full record → stop → transcribe lifecycle.
/// Listens for stop commands from the keyboard extension via Darwin notifications.
@Observable
final class RecordingFlowController {
    enum Phase {
        case starting
        case recording
        case transcribing
        case done
        case error
    }

    var phase: Phase = .starting
    var transcriptionResult: String?
    var errorMessage: String?

    let modelId: String
    let language: String
    let requestId: String

    private let recorder = AudioRecorder()
    private var commandPollTimer: Timer?

    /// Timestamp when recording started — shared with keyboard via IPC.
    private var recordingStartedAt: TimeInterval = 0

    var recordingDuration: TimeInterval {
        recorder.recordingDuration
    }

    init(modelId: String, language: String, requestId: String) {
        self.modelId = modelId
        self.language = language
        self.requestId = requestId
    }

    deinit {
        stopListeningForCommand()
    }

    // MARK: - Start

    func start() {
        let log = KeyboardDebugLog.shared
        log.log("[App:RecFlow] start() — model=\(modelId), requestId=\(requestId)")

        phase = .starting
        TranscriptionIPC.clearCommand()

        guard recorder.startRecording() else {
            phase = .error
            errorMessage = "Could not access microphone"
            TranscriptionIPC.writeStatus(RecordingStatus(
                requestId: requestId,
                phase: .error,
                message: "Mic unavailable"
            ))
            return
        }

        recordingStartedAt = Date().timeIntervalSince1970
        phase = .recording

        TranscriptionIPC.writeStatus(RecordingStatus(
            requestId: requestId,
            phase: .recording,
            recordingStartedAt: recordingStartedAt
        ))

        log.log("[App:RecFlow] ✅ Recording started, listening for stop command")
        listenForStopCommand()
    }

    // MARK: - Stop & Transcribe

    func stopAndTranscribe() {
        let log = KeyboardDebugLog.shared
        guard phase == .recording, recorder.isRecording else {
            log.log("[App:RecFlow] stopAndTranscribe — skipped (phase=\(phase), isRecording=\(recorder.isRecording))")
            return
        }
        stopListeningForCommand()

        log.log("[App:RecFlow] Stopping recording…")

        guard let audioURL = recorder.stopRecording() else {
            log.log("[App:RecFlow] ❌ No audio captured")
            phase = .error
            errorMessage = "No audio was captured"
            writeErrorResponse("No audio captured")
            return
        }

        log.log("[App:RecFlow] Audio saved: \(audioURL.lastPathComponent)")

        phase = .transcribing
        TranscriptionIPC.writeStatus(RecordingStatus(
            requestId: requestId,
            phase: .transcribing
        ))

        let duration = recorder.recordingDuration

        guard let model = WhisperModelInfo.availableModels.first(where: { $0.id == modelId }),
              let modelPath = model.localURL?.path,
              FileManager.default.fileExists(atPath: modelPath) else {
            log.log("[App:RecFlow] ❌ Model not found: \(modelId)")
            phase = .error
            errorMessage = "Model not found: \(modelId)"
            writeErrorResponse("Model not found")
            return
        }

        log.log("[App:RecFlow] Model found: \(model.name) at \(modelPath)")

        let modelName = model.name
        let lang = language
        let reqId = requestId

        // Request background time in case app is backgrounded
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask {
            log.log("[App:RecFlow] ⚠️ Background task expired")
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        log.log("[App:RecFlow] Starting transcription task (model=\(modelName), lang=\(lang))…")

        Task.detached(priority: .userInitiated) {
            let isBackground = await UIApplication.shared.applicationState != .active
            // Always use CPU to avoid Metal/GPU hangs — matches TranscriptionServer behaviour.
            // Metal compute from a backgrounded process is forbidden by iOS, and even in
            // foreground some devices stall during shader compilation on first run.
            let useGPU = false

            log.log("[App:RecFlow] Task started — isBackground=\(isBackground), useGPU=\(useGPU)")

            guard let ctx = WhisperContext(modelPath: modelPath, useGPU: useGPU) else {
                log.log("[App:RecFlow] ❌ WhisperContext init failed")
                await MainActor.run { [weak self] in
                    self?.phase = .error
                    self?.errorMessage = "Failed to load model"
                    self?.writeErrorResponse("Model load failed")
                    if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                }
                return
            }

            log.log("[App:RecFlow] WhisperContext ready, starting transcription…")
            let text = ctx.transcribe(audioURL: audioURL, language: lang)
            log.log("[App:RecFlow] Transcription complete — result: \(text.map { String($0.prefix(100)) } ?? "nil")")

            await MainActor.run { [weak self] in
                guard let self else {
                    log.log("[App:RecFlow] ⚠️ self deallocated before result could be applied")
                    if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                    return
                }

                if let text, !text.isEmpty {
                    self.transcriptionResult = text

                    let response = TranscriptionResponse(requestId: reqId, text: text)
                    try? TranscriptionIPC.writeResponse(response)
                    TranscriptionIPC.postResponseNotification()

                    TranscriptionIPC.writeStatus(RecordingStatus(
                        requestId: reqId,
                        phase: .done
                    ))

                    let transcript = Transcript(
                        text: text,
                        duration: duration,
                        modelUsed: modelName,
                        language: lang
                    )
                    TranscriptStore().add(transcript)

                    log.log("[App:RecFlow] ✅ Done — \(text.count) chars, phase → done")
                    self.phase = .done
                } else {
                    log.log("[App:RecFlow] ⚠️ No speech detected")
                    self.phase = .error
                    self.errorMessage = "No speech detected"
                    self.writeErrorResponse("No speech detected")
                }

                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
            }
        }
    }

    // MARK: - Stop Command Listening

    private func listenForStopCommand() {
        // Darwin notification
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let ctrl = Unmanaged<RecordingFlowController>
                    .fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { ctrl.handleStopCommandIfNeeded() }
            },
            TranscriptionIPC.stopCommandNotificationName,
            nil,
            .deliverImmediately
        )

        // Also poll as fallback
        commandPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.handleStopCommandIfNeeded()
        }
    }

    private func stopListeningForCommand() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center, observer,
            CFNotificationName(TranscriptionIPC.stopCommandNotificationName),
            nil
        )

        commandPollTimer?.invalidate()
        commandPollTimer = nil
    }

    private func handleStopCommandIfNeeded() {
        guard phase == .recording else { return }

        guard let command = TranscriptionIPC.readCommand(),
              command.requestId == requestId,
              command.action == .stop else { return }

        TranscriptionIPC.clearCommand()
        stopAndTranscribe()
    }

    // MARK: - Helpers

    private func writeErrorResponse(_ message: String) {
        let response = TranscriptionResponse(requestId: requestId, error: message)
        try? TranscriptionIPC.writeResponse(response)
        TranscriptionIPC.postResponseNotification()

        TranscriptionIPC.writeStatus(RecordingStatus(
            requestId: requestId,
            phase: .error,
            message: message
        ))
    }
}

// MARK: - View

/// Recording + transcription UI shown when the keyboard opens the app via URL scheme.
///
/// The user is prompted to switch back to their app. Recording continues in the
/// background. The keyboard sends a stop command when the user taps Stop.
struct RecordingFlowView: View {
    let controller: RecordingFlowController
    let onDismiss: () -> Void

    @State private var pulseAnimation = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                phaseIcon
                phaseText
                durationOrStatus

                Spacer()

                actionArea
            }
            .padding(24)
        }
        .onAppear {
            controller.start()
        }
    }

    // MARK: - Phase Icon

    @ViewBuilder
    private var phaseIcon: some View {
        switch controller.phase {
        case .starting:
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)

        case .recording:
            ZStack {
                Circle()
                    .fill(.red.opacity(0.15))
                    .frame(width: 120, height: 120)
                    .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                    .opacity(pulseAnimation ? 0.3 : 0.8)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulseAnimation)

                Image(systemName: "mic.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.red)
            }
            .onAppear { pulseAnimation = true }
            .onDisappear { pulseAnimation = false }

        case .transcribing:
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)

        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundColor(.orange)
        }
    }

    // MARK: - Phase Text

    @ViewBuilder
    private var phaseText: some View {
        switch controller.phase {
        case .starting:
            Text("Starting microphone…")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

        case .recording:
            VStack(spacing: 16) {
                Text("Recording")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)

                Text("Switch back to your app.\nRecording continues in the background.\nTap Stop in the keyboard when done.")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

        case .transcribing:
            Text("Transcribing…")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

        case .done:
            VStack(spacing: 12) {
                Text("Done!")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)

                if let text = controller.transcriptionResult {
                    Text(text)
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 16)
                }
            }

        case .error:
            VStack(spacing: 8) {
                Text("Error")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)

                Text(controller.errorMessage ?? "Something went wrong")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Duration

    @ViewBuilder
    private var durationOrStatus: some View {
        if controller.phase == .recording {
            Text(formatDuration(controller.recordingDuration))
                .font(.system(size: 48, weight: .light, design: .monospaced))
                .foregroundColor(.white)
        }
    }

    // MARK: - Action Area

    @ViewBuilder
    private var actionArea: some View {
        switch controller.phase {
        case .recording:
            Button(action: { controller.stopAndTranscribe() }) {
                HStack(spacing: 10) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16))
                    Text("Stop & Transcribe")
                        .font(.system(size: 18, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(.bottom, 48)

        case .done, .error:
            Button(action: { onDismiss() }) {
                Text("Close")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.bottom, 48)

        default:
            Spacer().frame(height: 48)
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
