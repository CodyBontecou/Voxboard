import SwiftUI
import VoxboardShared

// MARK: - Controller (unchanged — only view layer is redesigned)

@Observable
final class CapturePresetController {
    enum Phase {
        case starting, recording, transcribing, done, error
    }

    var phase: Phase = .starting
    var transcriptionResult: String?
    var errorMessage: String?
    var transcriptionProgress: TranscriptionProgress?

    let modelId: String
    let language: String
    let requestId: String

    private let recorder = AudioRecorder()
    private var commandPollTimer: Timer?
    private let transcriptStore: TranscriptStore
    private let transcriptionService: OnDeviceTranscriptionService
    private var recordingStartedAt: TimeInterval = 0
    private var transcriptionStartedAt: TimeInterval?
    private var lastPublishedProgressPercent: Int?

    var recordingDuration: TimeInterval { recorder.recordingDuration }

    init(
        modelId: String,
        language: String,
        requestId: String,
        transcriptStore: TranscriptStore,
        transcriptionService: OnDeviceTranscriptionService = AppTranscriptionServices.shared
    ) {
        self.modelId = modelId
        self.language = language
        self.requestId = requestId
        self.transcriptStore = transcriptStore
        self.transcriptionService = transcriptionService
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
        transcriptionProgress = nil
        lastPublishedProgressPercent = nil
        transcriptionStartedAt = Date().timeIntervalSince1970
        TranscriptionIPC.writeStatus(RecordingStatus(
            requestId: requestId,
            phase: .transcribing,
            recordingStartedAt: recordingStartedAt,
            recordingStoppedAt: transcriptionStartedAt
        ))
        let duration = recorder.recordingDuration

        let lang = language
        let reqId = requestId
        let selectedModelID = modelId
        let service = transcriptionService

        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid
        }

        Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: audioURL) }
            do {
                let result = try await service.transcribeResult(
                    audioURL: audioURL,
                    modelID: selectedModelID,
                    fallbackModelID: AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedFallbackModelKey),
                    language: lang,
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.requestId == reqId,
                                  self.phase == .transcribing else { return }
                            if let current = self.transcriptionProgress?.exactFractionCompleted {
                                guard let incoming = progress.exactFractionCompleted,
                                      incoming >= current else { return }
                            }
                            self.transcriptionProgress = progress
                            guard let percent = progress.wholePercentCompleted,
                                  let fraction = progress.exactFractionCompleted,
                                  percent != self.lastPublishedProgressPercent else { return }
                            self.lastPublishedProgressPercent = percent
                            TranscriptionIPC.writeStatus(RecordingStatus(
                                requestId: reqId,
                                phase: .transcribing,
                                recordingStartedAt: self.recordingStartedAt,
                                recordingStoppedAt: self.transcriptionStartedAt,
                                transcriptionProgress: fraction
                            ))
                        }
                    }
                )
                log.log("[App:RecFlow] Transcription complete")

                await MainActor.run { [weak self] in
                    guard let self else {
                        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                        return
                    }
                    self.transcriptionProgress = nil
                    self.transcriptionResult = result.text
                    let response = TranscriptionResponse(requestId: reqId, text: result.text)
                    try? TranscriptionIPC.writeResponse(response)
                    TranscriptionIPC.postResponseNotification()
                    TranscriptionIPC.writeStatus(RecordingStatus(requestId: reqId, phase: .done))
                    self.transcriptStore.add(Transcript(
                        text: result.text,
                        duration: duration,
                        modelUsed: result.backendName,
                        language: result.language
                    ))
                    ReviewPromptManager.shared.recordSuccessfulTranscription(
                        totalTranscriptionCount: self.transcriptStore.transcripts.count,
                        transcriptDates: self.transcriptStore.transcripts.map(\.date)
                    )
                    self.phase = .done
                    if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.transcriptionProgress = nil
                    self?.phase = .error
                    self?.errorMessage = error.localizedDescription
                    self?.writeErrorResponse(error.localizedDescription)
                    if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                }
            }
        }
    }

    private func listenForStopCommand() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let ctrl = Unmanaged<CapturePresetController>.fromOpaque(observer).takeUnretainedValue()
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

// MARK: - View (fully redesigned — Geist design system)

struct CapturePresetView: View {
    let controller: CapturePresetController
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Geist.bg.ignoresSafeArea()
            GeistGridBackground().ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 0) {
                // Top rule
                GeistDivider()

                Spacer()
                phaseContent
                Spacer()

                GeistDivider()
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
                GeistSectionLabel(number: "01", title: "Status")
                Text("Starting…")
                    .font(Geist.display(52))
                    .foregroundColor(Geist.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(Geist.text)
            }

        case .recording:
            VStack(spacing: 24) {
                GeistSectionLabel(number: "01", title: "Status")
                VStack(spacing: 12) {
                    Text("Recording")
                        .font(Geist.display(48))
                        .foregroundColor(Geist.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.3)
                    Text(formatDuration(controller.recordingDuration))
                        .font(Geist.display(54))
                        .foregroundColor(Geist.text)
                        .monospacedDigit()
                }

                // Swipe-back prompt
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text("←")
                            .font(Geist.label(.headline))
                        Text("Return to Your App")
                            .font(Geist.label())
                    }
                    .foregroundColor(Geist.text)
                    Text("Recording continues. Tap Stop on the keyboard when done.")
                        .font(Geist.body())
                        .foregroundColor(Geist.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .padding(16)
                .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))
            }

        case .transcribing:
            VStack(spacing: 24) {
                GeistSectionLabel(number: "01", title: "Status")
                if let progress = controller.transcriptionProgress,
                   let fraction = progress.exactFractionCompleted,
                   let percent = progress.formattedWholePercentCompleted {
                    VStack(spacing: 12) {
                        Text("Transcribing \(percent)")
                            .font(Geist.display(48))
                            .foregroundColor(Geist.text)
                            .minimumScaleFactor(0.4)
                        ProgressView(value: fraction)
                            .frame(maxWidth: 280)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Transcription \(percent) complete")
                } else {
                    TranscribingDotsView()
                }
                Text("Processing audio on-device")
                    .font(Geist.body())
                    .foregroundColor(Geist.muted)
            }

        case .done:
            VStack(spacing: 24) {
                GeistSectionLabel(number: "01", title: "Status")
                Text("Transcript Ready")
                    .font(Geist.display(52))
                    .foregroundColor(Geist.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                if let result = controller.transcriptionResult {
                    Text(result)
                        .font(Geist.body())
                        .foregroundColor(Geist.text)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .lineLimit(5)
                        .padding(16)
                        .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))
                }
            }

        case .error:
            VStack(spacing: 20) {
                GeistSectionLabel(number: "01", title: "Status")
                Text("Transcription Error")
                    .font(Geist.display(52))
                    .foregroundColor(Geist.error)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Text(controller.errorMessage ?? String(localized: "Something went wrong"))
                    .font(Geist.body())
                    .foregroundColor(Geist.muted)
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .overlay(Rectangle().stroke(Geist.error.opacity(0.4), lineWidth: 1))
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
                        Text("Stop and Transcribe")
                    }
                }
                .buttonStyle(GeistButtonStyle(variant: .destructive))

            case .done, .error:
                Button(action: { onDismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(.body, weight: .bold))
                }
                .buttonStyle(GeistButtonStyle(variant: .secondary))
                .accessibilityLabel("Close")

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
