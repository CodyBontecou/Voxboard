import SwiftUI
import VoxboardShared

// MARK: - Controller (unchanged — only view layer is redesigned)

@Observable
final class RecordingFlowController {
    enum Phase {
        case starting, recording, transcribing, done, error
    }

    var phase: Phase = .starting
    var transcriptionResult: String?
    var errorMessage: String?

    let modelId: String
    let language: String
    let requestId: String

    private let recorder = AudioRecorder()
    private var commandPollTimer: Timer?
    private let transcriptStore: TranscriptStore
    private var recordingStartedAt: TimeInterval = 0

    var recordingDuration: TimeInterval { recorder.recordingDuration }

    init(modelId: String, language: String, requestId: String, transcriptStore: TranscriptStore) {
        self.modelId = modelId
        self.language = language
        self.requestId = requestId
        self.transcriptStore = transcriptStore
    }

    deinit { stopListeningForCommand() }

    func start() {
        let log = KeyboardDebugLog.shared
        log.log("[App:RecFlow] start() — model=\(modelId), requestId=\(requestId)")
        phase = .starting
        TranscriptionIPC.clearCommand()

        guard recorder.startRecording() else {
            phase = .error
            errorMessage = String(localized: "Could not access microphone")
            TranscriptionIPC.writeStatus(RecordingStatus(requestId: requestId, phase: .error, message: String(localized: "Mic unavailable")))
            return
        }

        recordingStartedAt = Date().timeIntervalSince1970
        phase = .recording
        TranscriptionIPC.writeStatus(RecordingStatus(requestId: requestId, phase: .recording, recordingStartedAt: recordingStartedAt))
        listenForStopCommand()
    }

    func stopAndTranscribe() {
        let log = KeyboardDebugLog.shared
        guard phase == .recording, recorder.isRecording else { return }
        stopListeningForCommand()

        guard let audioURL = recorder.stopRecording() else {
            phase = .error; errorMessage = String(localized: "No audio was captured")
            writeErrorResponse(String(localized: "No audio captured")); return
        }

        phase = .transcribing
        TranscriptionIPC.writeStatus(RecordingStatus(requestId: requestId, phase: .transcribing))
        let duration = recorder.recordingDuration

        guard let model = WhisperModelInfo.availableModels.first(where: { $0.id == modelId }),
              let modelPath = model.localURL?.path,
              FileManager.default.fileExists(atPath: modelPath) else {
            phase = .error; errorMessage = String(format: String(localized: "Model not found: %@"), modelId)
            writeErrorResponse(String(localized: "Model not found")); return
        }

        let modelName = model.name
        let lang = language
        let reqId = requestId

        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid
        }

        Task.detached(priority: .userInitiated) {
            guard let ctx = WhisperContext(modelPath: modelPath, useGPU: false) else {
                await MainActor.run { [weak self] in
                    self?.phase = .error; self?.errorMessage = String(localized: "Failed to load model")
                    self?.writeErrorResponse(String(localized: "Model load failed"))
                    if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                }; return
            }

            let text = ctx.transcribe(audioURL: audioURL, language: lang)
            log.log("[App:RecFlow] Transcription complete")

            await MainActor.run { [weak self] in
                guard let self else {
                    if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }; return
                }
                if let text, !text.isEmpty {
                    self.transcriptionResult = text
                    let response = TranscriptionResponse(requestId: reqId, text: text)
                    try? TranscriptionIPC.writeResponse(response)
                    TranscriptionIPC.postResponseNotification()
                    TranscriptionIPC.writeStatus(RecordingStatus(requestId: reqId, phase: .done))
                    self.transcriptStore.add(Transcript(text: text, duration: duration, modelUsed: modelName, language: lang))
                    self.phase = .done
                } else {
                    self.phase = .error; self.errorMessage = String(localized: "No speech detected")
                    self.writeErrorResponse(String(localized: "No speech detected"))
                }
                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
            }
        }
    }

    private func listenForStopCommand() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let ctrl = Unmanaged<RecordingFlowController>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { ctrl.handleStopCommandIfNeeded() }
        }, TranscriptionIPC.stopCommandNotificationName, nil, .deliverImmediately)

        commandPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.handleStopCommandIfNeeded()
        }
    }

    private func stopListeningForCommand() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(
            center, Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(TranscriptionIPC.stopCommandNotificationName), nil
        )
        commandPollTimer?.invalidate(); commandPollTimer = nil
    }

    private func handleStopCommandIfNeeded() {
        guard phase == .recording,
              let command = TranscriptionIPC.readCommand(),
              command.requestId == requestId,
              command.action == .stop else { return }
        TranscriptionIPC.clearCommand()
        stopAndTranscribe()
    }

    private func writeErrorResponse(_ message: String) {
        let response = TranscriptionResponse(requestId: requestId, error: message)
        try? TranscriptionIPC.writeResponse(response)
        TranscriptionIPC.postResponseNotification()
        TranscriptionIPC.writeStatus(RecordingStatus(requestId: requestId, phase: .error, message: message))
    }
}

// MARK: - View (fully redesigned — brutal aesthetic)

struct RecordingFlowView: View {
    let controller: RecordingFlowController
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Brutal.bg.ignoresSafeArea()
            BrutalGridBackground().ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 0) {
                // Top rule
                BrutalDivider()

                Spacer()
                phaseContent
                Spacer()

                BrutalDivider()
                actionBar
            }
            .padding(.horizontal, 24)
        }
        .onAppear { controller.start() }
    }

    // MARK: - Phase Content

    @ViewBuilder
    private var phaseContent: some View {
        switch controller.phase {
        case .starting:
            VStack(spacing: 20) {
                BrutalSectionLabel(number: "01", title: "Status")
                Text("STARTING.")
                    .font(Brutal.display(52))
                    .foregroundColor(Brutal.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(Brutal.text)
            }

        case .recording:
            VStack(spacing: 24) {
                BrutalSectionLabel(number: "01", title: "Status")
                VStack(spacing: 12) {
                    Text("RECORDING.")
                        .font(Brutal.display(48))
                        .foregroundColor(Brutal.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.3)
                    Text(formatDuration(controller.recordingDuration))
                        .font(Brutal.display(54))
                        .foregroundColor(Brutal.text)
                        .monospacedDigit()
                }

                // Swipe-back prompt
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text("←")
                            .font(Brutal.label(.headline))
                        Text("SWIPE BACK TO YOUR APP")
                            .font(Brutal.label())
                    }
                    .foregroundColor(Brutal.text)
                    Text("Recording continues. Tap Stop on the keyboard when done.")
                        .font(Brutal.body())
                        .foregroundColor(Brutal.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .padding(16)
                .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))
            }

        case .transcribing:
            VStack(spacing: 24) {
                BrutalSectionLabel(number: "01", title: "Status")
                TranscribingDotsView()
                Text("Processing audio on-device")
                    .font(Brutal.body())
                    .foregroundColor(Brutal.muted)
            }

        case .done:
            VStack(spacing: 24) {
                BrutalSectionLabel(number: "01", title: "Status")
                Text("DONE.")
                    .font(Brutal.display(52))
                    .foregroundColor(Brutal.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                if let result = controller.transcriptionResult {
                    Text(result)
                        .font(Brutal.body())
                        .foregroundColor(Brutal.text)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .lineLimit(5)
                        .padding(16)
                        .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))
                }
            }

        case .error:
            VStack(spacing: 20) {
                BrutalSectionLabel(number: "01", title: "Status")
                Text("ERROR.")
                    .font(Brutal.display(52))
                    .foregroundColor(Brutal.error)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Text(controller.errorMessage ?? String(localized: "Something went wrong"))
                    .font(Brutal.body())
                    .foregroundColor(Brutal.muted)
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .overlay(Rectangle().stroke(Brutal.error.opacity(0.4), lineWidth: 1))
            }
        }
    }

    // MARK: - Action Bar

    @ViewBuilder
    private var actionBar: some View {
        Group {
            switch controller.phase {
            case .recording:
                Button(action: { controller.stopAndTranscribe() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill").font(.system(.footnote))
                        Text("STOP + TRANSCRIBE")
                    }
                }
                .buttonStyle(BrutalButtonStyle(variant: .destructive))

            case .done, .error:
                Button(action: { onDismiss() }) {
                    Text("CLOSE")
                }
                .buttonStyle(BrutalButtonStyle(variant: .secondary))

            default:
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 54)
            }
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 16)
    }

    // MARK: - Helpers

    private func formatDuration(_ d: TimeInterval) -> String {
        let m = Int(d) / 60
        let s = Int(d) % 60
        let t = Int((d * 10).truncatingRemainder(dividingBy: 10))
        return String(format: "%d:%02d.%d", m, s, t)
    }
}
