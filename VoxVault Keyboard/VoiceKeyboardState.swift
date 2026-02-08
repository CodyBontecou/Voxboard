import Foundation
import VoxVaultShared

private let log = KeyboardDebugLog.shared

/// Manages recording + transcription state for the keyboard extension.
///
/// Recording happens in-process (the extension has mic access with Full Access).
/// Transcription is offloaded to the main app via file-based IPC so there are
/// no memory-limit constraints on model size.
@Observable
final class VoiceKeyboardState {

    enum Status: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
        case noModel
        case needsFullAccess
    }

    var status: Status = .idle
    var recordingDuration: TimeInterval = 0
    var selectedModelIndex: Int = 0

    private var recorder = AudioRecorder()
    private var recordingTimer: Timer?
    private var recordStartTime: Date?

    // IPC state
    private var pendingRequestId: String?
    private var pendingCallback: (@MainActor (String) -> Void)?
    private var pendingDuration: TimeInterval = 0
    private var pendingModelName: String = ""
    private var pendingLanguage: String = ""
    private var pollTimer: Timer?
    private var timeoutTimer: Timer?

    init() {
        registerResponseObserver()
        log.log("VoiceKeyboardState init — IPC mode")
    }

    deinit {
        unregisterResponseObserver()
    }

    // MARK: - Available Models

    /// All downloaded models are available — the main app does the heavy lifting.
    var downloadedModels: [WhisperModelInfo] {
        WhisperModelInfo.availableModels.filter { $0.isDownloaded }
    }

    var currentModel: WhisperModelInfo? {
        let models = downloadedModels
        guard !models.isEmpty else { return nil }
        let idx = min(selectedModelIndex, models.count - 1)
        return models[max(0, idx)]
    }

    var currentModelName: String {
        currentModel?.name ?? "No Model"
    }

    // MARK: - Model Navigation (< > arrows)

    func previousModel() {
        let count = downloadedModels.count
        guard count > 0 else { return }
        selectedModelIndex = (selectedModelIndex - 1 + count) % count
        log.log("Model switched to: \(currentModelName)")
    }

    func nextModel() {
        let count = downloadedModels.count
        guard count > 0 else { return }
        selectedModelIndex = (selectedModelIndex + 1) % count
        log.log("Model switched to: \(currentModelName)")
    }

    // MARK: - Toggle Recording

    func toggleRecording(
        hasFullAccess: Bool,
        onTranscription: @escaping @MainActor (String) -> Void
    ) {
        log.log("toggleRecording — hasFullAccess=\(hasFullAccess), status=\(status)")

        guard hasFullAccess else {
            status = .needsFullAccess
            log.log("❌ No full access")
            return
        }

        guard currentModel != nil else {
            status = .noModel
            log.log("❌ No model available. Downloaded: \(downloadedModels.map(\.id))")
            return
        }

        switch status {
        case .recording:
            stopAndTranscribe(onTranscription: onTranscription)
        default:
            startRecording()
        }
    }

    // MARK: - Recording

    private func startRecording() {
        log.log("startRecording — requesting mic…")

        guard recorder.startRecording() else {
            status = .error("Mic unavailable")
            log.log("❌ Mic unavailable")
            resetErrorAfterDelay()
            return
        }

        status = .recording
        recordingDuration = 0
        recordStartTime = Date()
        log.log("✅ Recording started")

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    // MARK: - Stop & Send to App for Transcription

    private func stopAndTranscribe(onTranscription: @escaping @MainActor (String) -> Void) {
        log.log("stopAndTranscribe — stopping recorder…")
        recordingTimer?.invalidate()
        recordingTimer = nil

        guard let audioURL = recorder.stopRecording() else {
            status = .idle
            log.log("❌ stopRecording returned nil")
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? -1
        log.log("Recording stopped — file: \(audioURL.lastPathComponent), size: \(fileSize) bytes, duration: \(String(format: "%.1f", recordingDuration))s")

        status = .transcribing

        let modelId = currentModel?.id ?? "ggml-base"
        let language = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey) ?? "auto"
        let modelName = currentModel?.name ?? "Unknown"

        // Build IPC request
        let request = TranscriptionRequest(
            audioFileName: audioURL.lastPathComponent,
            modelId: modelId,
            language: language
        )

        do {
            try TranscriptionIPC.writeRequest(request)
        } catch {
            log.log("❌ Failed to write IPC request: \(error)")
            status = .error("IPC error")
            resetErrorAfterDelay()
            return
        }

        // Store pending state for when the response arrives
        pendingRequestId = request.id
        pendingCallback = onTranscription
        pendingDuration = recordingDuration
        pendingModelName = modelName
        pendingLanguage = language

        // Wake the main app
        log.log("📤 Request \(request.id) sent — model: \(modelId), lang: \(language)")
        TranscriptionIPC.postRequestNotification()

        // Poll for response file as a reliable fallback
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForResponse() }
        }

        // Timeout after 30 seconds — the app may not be running
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.handleTimeout() }
        }
    }

    // MARK: - Response Handling

    /// Called by Darwin notification or poll timer.
    @MainActor
    private func checkForResponse() {
        guard let requestId = pendingRequestId else { return }

        guard let response = TranscriptionIPC.readResponse(),
              response.requestId == requestId else { return }

        log.log("📥 Response received for \(requestId)")

        // Capture pending state before cleanup
        let callback = pendingCallback
        let duration = pendingDuration
        let modelName = pendingModelName
        let language = pendingLanguage

        cleanupPending()
        TranscriptionIPC.clearResponse()

        if let text = response.text, !text.isEmpty {
            log.log("✅ Inserting text (\(text.count) chars)")
            callback?(text)

            // Save to shared transcript history
            let transcript = Transcript(
                text: text,
                duration: duration,
                modelUsed: modelName,
                language: language
            )
            TranscriptStore().add(transcript)

            status = .idle
        } else {
            let msg = response.error ?? "No speech detected"
            log.log("⚠️ \(msg)")
            status = .error(msg)
            resetErrorAfterDelay()
        }
    }

    @MainActor
    private func handleTimeout() {
        guard pendingRequestId != nil else { return }
        log.log("⏰ Timeout — no response from app")
        cleanupPending()
        status = .error("Open VoxVault app")
        resetErrorAfterDelay()
    }

    private func cleanupPending() {
        pollTimer?.invalidate()
        pollTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        pendingRequestId = nil
        pendingCallback = nil
    }

    // MARK: - Darwin Notification Observer (response from app)

    private func registerResponseObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let state = Unmanaged<VoiceKeyboardState>
                    .fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in state.checkForResponse() }
            },
            TranscriptionIPC.responseNotificationName,
            nil,
            .deliverImmediately
        )
    }

    private func unregisterResponseObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center, observer,
            CFNotificationName(TranscriptionIPC.responseNotificationName),
            nil
        )
    }

    // MARK: - Memory Warning

    func handleMemoryWarning() {
        log.log("⚠️⚠️⚠️ didReceiveMemoryWarning")
        // No heavy resources to free anymore — transcription runs in the app.
        // Just log it for diagnostics.
    }

    // MARK: - Helpers

    private func resetErrorAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if case .error = status { status = .idle }
        }
    }
}
