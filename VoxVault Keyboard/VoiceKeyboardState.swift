import Foundation
import UIKit
import VoxVaultShared

private let log = KeyboardDebugLog.shared

/// Manages voice transcription state for the keyboard extension.
///
/// Recording and transcription happen in the main app (opened via URL scheme).
/// The app records in the background while the user stays in the keyboard.
///
/// Flow:
/// 1. User taps mic → keyboard opens voxvault://record → app starts recording
/// 2. User switches back → keyboard shows "Recording…" with timer + Stop button
/// 3. User taps Stop → keyboard sends stop command via IPC
/// 4. App stops recording, transcribes, writes response
/// 5. Keyboard picks up result and inserts text
@Observable
final class VoiceKeyboardState {

    enum Status: Equatable {
        case idle
        case openingApp          // Briefly shown while app is opening
        case recording           // App is recording in background
        case transcribing        // App is transcribing
        case error(String)
        case noModel
        case needsFullAccess
    }

    var status: Status = .idle
    var recordingDuration: TimeInterval = 0
    var selectedModelIndex: Int = 0

    /// Set when a transcription result arrives. The view layer should observe this,
    /// call `textDocumentProxy.insertText`, then clear it via `consumeTranscription()`.
    var pendingTranscription: String?

    /// Closure provided by KeyboardViewController to open URLs via the responder chain.
    var urlOpener: ((URL) -> Void)?

    /// Closure provided by KeyboardViewController to insert text via textDocumentProxy.
    /// Called directly when a transcription result arrives — avoids relying on SwiftUI onChange.
    var textInserter: ((String) -> Void)?

    // IPC state
    private var pendingRequestId: String?
    private var pollTimer: Timer?
    private var durationTimer: Timer?
    private var recordingStartedAt: TimeInterval?

    init() {
        registerResponseObserver()
        log.log("VoiceKeyboardState init — app-recording mode")

        // Check if we had a pending recording session (e.g. keyboard was reloaded)
        checkForExistingRecording()
    }

    deinit {
        unregisterResponseObserver()
    }

    // MARK: - Available Models

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

    // MARK: - Model Navigation

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

    // MARK: - Consume Transcription

    func consumeTranscription() {
        pendingTranscription = nil
        clearPendingText()
    }

    // MARK: - Start Recording (opens main app)

    func startRecording(hasFullAccess: Bool) {
        log.log("startRecording — hasFullAccess=\(hasFullAccess), status=\(status)")

        guard hasFullAccess else {
            status = .needsFullAccess
            log.log("❌ No full access")
            return
        }

        guard let model = currentModel else {
            status = .noModel
            log.log("❌ No model available. Downloaded: \(downloadedModels.map(\.id))")
            return
        }

        let requestId = UUID().uuidString
        let language = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey) ?? "auto"

        guard let url = AppConstants.recordURL(
            modelId: model.id,
            language: language,
            requestId: requestId
        ) else {
            log.log("❌ Could not build record URL")
            status = .error("Internal error")
            resetErrorAfterDelay()
            return
        }

        // Clear stale IPC data
        TranscriptionIPC.clearResponse()
        TranscriptionIPC.clearStatus()
        TranscriptionIPC.clearCommand()

        pendingRequestId = requestId
        status = .openingApp
        recordingDuration = 0

        log.log("📤 Opening app: \(url.absoluteString)")

        if let urlOpener {
            urlOpener(url)
        } else {
            log.log("❌ No URL opener available — was urlOpener set by KeyboardViewController?")
            status = .error("Internal error")
            resetErrorAfterDelay()
            return
        }

        // Start polling — we'll detect when the app actually starts recording
        startPolling()
    }

    // MARK: - Stop Recording (sends command to app)

    func stopRecording() {
        guard let requestId = pendingRequestId else {
            log.log("stopRecording — no pending request")
            return
        }

        log.log("⏹ Sending stop command for \(requestId)")

        // Write stop command + post notification
        let command = RecordingCommand(requestId: requestId, action: .stop)
        TranscriptionIPC.writeCommand(command)
        TranscriptionIPC.postStopCommandNotification()

        // Update UI immediately — don't wait for the poll
        status = .transcribing
        stopDurationTimer()
    }

    // MARK: - Cancel

    func cancelRecording() {
        log.log("Cancelling pending recording")
        // Send stop to clean up the app side too
        if let requestId = pendingRequestId {
            let command = RecordingCommand(requestId: requestId, action: .stop)
            TranscriptionIPC.writeCommand(command)
            TranscriptionIPC.postStopCommandNotification()
        }
        cleanupPending()
        status = .idle
    }

    // MARK: - Check for Existing Recording

    /// If the keyboard extension was reloaded while a recording was in progress,
    /// reconnect to it.
    private func checkForExistingRecording() {
        // Check for pending text that wasn't inserted before a reload
        if let text = readPendingText() {
            log.log("♻️ Found pending text from previous session (\(text.count) chars)")
            pendingTranscription = text
            // Will be inserted once textInserter is set — see tryInsertPendingText()
        }

        guard let ipcStatus = TranscriptionIPC.readStatus() else { return }

        switch ipcStatus.phase {
        case .recording:
            log.log("♻️ Reconnecting to existing recording: \(ipcStatus.requestId)")
            pendingRequestId = ipcStatus.requestId
            recordingStartedAt = ipcStatus.recordingStartedAt
            status = .recording
            startPolling()
            startDurationTimer()

        case .transcribing:
            log.log("♻️ Reconnecting to existing transcription: \(ipcStatus.requestId)")
            pendingRequestId = ipcStatus.requestId
            status = .transcribing
            startPolling()

        default:
            break
        }
    }

    /// Try to insert any pending transcription text. Called after textInserter is set.
    func tryInsertPendingText() {
        guard let text = pendingTranscription, let textInserter else { return }
        log.log("📝 Inserting recovered pending text (\(text.count) chars)")
        textInserter(text)
        pendingTranscription = nil
        clearPendingText()
        log.log("📝 Recovered text inserted and cleared")
    }

    // MARK: - Polling for Status & Response

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates() }
        }
    }

    @MainActor
    private func checkForUpdates() {
        guard let requestId = pendingRequestId else { return }

        // Check for status updates from the app
        if let ipcStatus = TranscriptionIPC.readStatus(), ipcStatus.requestId == requestId {
            switch ipcStatus.phase {
            case .recording:
                if status == .openingApp || status != .recording {
                    status = .recording
                    recordingStartedAt = ipcStatus.recordingStartedAt
                    startDurationTimer()
                    log.log("🎙 App confirmed recording started")
                }

            case .transcribing:
                if status != .transcribing {
                    status = .transcribing
                    stopDurationTimer()
                    log.log("⏳ App is transcribing")
                }

            case .done, .error:
                break // Handled by response check below
            }
        }

        // Check for completed response
        guard let response = TranscriptionIPC.readResponse(),
              response.requestId == requestId else { return }

        log.log("📥 Response received for \(requestId)")
        cleanupPending()
        TranscriptionIPC.clearResponse()
        TranscriptionIPC.clearStatus()

        if let text = response.text, !text.isEmpty {
            log.log("✅ Transcription ready (\(text.count) chars)")
            pendingTranscription = text
            status = .idle

            // Insert text directly via textDocumentProxy callback — more reliable
            // than relying on SwiftUI onChange with @Observable.
            if let textInserter {
                log.log("📝 Inserting text via textInserter")
                textInserter(text)
                pendingTranscription = nil
                log.log("📝 Text inserted and consumed")
            } else {
                // Persist to IPC so a keyboard reload can recover the text
                log.log("⚠️ No textInserter — persisting to IPC for recovery")
                writePendingText(text)
            }
        } else {
            let msg = response.error ?? "No speech detected"
            log.log("⚠️ \(msg)")
            status = .error(msg)
            resetErrorAfterDelay()
        }
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        stopDurationTimer()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.recordingStartedAt else { return }
                self.recordingDuration = Date().timeIntervalSince1970 - startedAt
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // MARK: - Cleanup

    private func cleanupPending() {
        pollTimer?.invalidate()
        pollTimer = nil
        stopDurationTimer()
        pendingRequestId = nil
        recordingStartedAt = nil
        recordingDuration = 0
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
                Task { @MainActor in state.checkForUpdates() }
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
        log.log("⚠️ didReceiveMemoryWarning — no heavy resources in extension")
    }

    // MARK: - Helpers

    private func resetErrorAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if case .error = status { status = .idle }
        }
    }

    // MARK: - Pending Text Persistence

    /// Persist pending transcription text to the shared container so it survives keyboard reloads.
    private func writePendingText(_ text: String) {
        guard let dir = AppConstants.sharedContainerURL else { return }
        let url = dir.appendingPathComponent("TranscriptionIPC").appendingPathComponent("pending_text.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Read pending text that was persisted before a keyboard reload.
    private func readPendingText() -> String? {
        guard let dir = AppConstants.sharedContainerURL else { return nil }
        let url = dir.appendingPathComponent("TranscriptionIPC").appendingPathComponent("pending_text.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    /// Clear persisted pending text after it has been inserted.
    private func clearPendingText() {
        guard let dir = AppConstants.sharedContainerURL else { return }
        let url = dir.appendingPathComponent("TranscriptionIPC").appendingPathComponent("pending_text.txt")
        try? FileManager.default.removeItem(at: url)
    }
}
