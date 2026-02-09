import Foundation
import UIKit
import VoxVaultShared

private let log = KeyboardDebugLog.shared

/// Manages voice transcription state for the keyboard extension.
///
/// **Always-on flow** (primary — no app switching):
/// The main app runs a persistent recorder in the background. The keyboard
/// controls transcription segments entirely via IPC:
///
/// 1. User taps Record → keyboard writes `startSegment` command → app marks buffer position
/// 2. User taps Stop → keyboard writes `stopSegment` command → app extracts audio + transcribes
/// 3. App writes response → keyboard inserts text
///
/// If the app isn't listening yet, the keyboard prompts the user to open VoxVault once.
@Observable
final class VoiceKeyboardState {

    enum Status: Equatable {
        case idle               // App is listening, ready for user to tap Record
        case recording          // Segment is active — audio being captured
        case transcribing       // App is transcribing the segment
        case error(String)
        case noModel
        case needsFullAccess
        case appNotListening    // App isn't running the persistent recorder
    }

    var status: Status = .idle
    var recordingDuration: TimeInterval = 0
    var selectedModelIndex: Int = 0

    /// Set when a transcription result arrives. The view layer should observe this,
    /// call `textDocumentProxy.insertText`, then clear it via `consumeTranscription()`.
    var pendingTranscription: String?

    /// Closure provided by KeyboardViewController to open URLs via the responder chain.
    /// Used only to prompt opening the app when it's not listening.
    var urlOpener: ((URL) -> Void)?

    /// Closure provided by KeyboardViewController to insert text via textDocumentProxy.
    var textInserter: ((String) -> Void)?

    // IPC state
    private var pendingRequestId: String?
    private var pollTimer: Timer?
    private var durationTimer: Timer?
    private var recordingStartedAt: TimeInterval?

    init() {
        registerResponseObserver()
        registerListeningStateObserver()
        log.log("VoiceKeyboardState init — always-on mode")

        // Check if app is currently listening
        refreshListeningState()

        // Check if we had a pending recording session (e.g. keyboard was reloaded)
        checkForExistingSession()
    }

    deinit {
        unregisterObservers()
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

    // MARK: - Start Recording (send IPC command — no app switch!)

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

        // Check if app is listening
        let listeningState = TranscriptionIPC.readListeningState()
        guard listeningState?.isListening == true else {
            status = .appNotListening
            log.log("❌ App is not listening — user needs to open VoxVault once")
            return
        }

        let requestId = UUID().uuidString
        let language = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey) ?? "auto"

        // Clear stale IPC data
        TranscriptionIPC.clearResponse()
        TranscriptionIPC.clearStatus()

        pendingRequestId = requestId
        recordingStartedAt = Date().timeIntervalSince1970
        recordingDuration = 0
        status = .recording

        // Write startSegment command
        let command = RecordingCommand(
            requestId: requestId,
            action: .startSegment,
            modelId: model.id,
            language: language
        )
        TranscriptionIPC.writeCommand(command)
        TranscriptionIPC.postCommandNotification()

        log.log("📤 Sent startSegment command (requestId=\(requestId), model=\(model.id))")

        // Start local duration timer
        startDurationTimer()

        // Start polling for status updates
        startPolling()
    }

    // MARK: - Stop Recording (send IPC command — no app switch!)

    func stopRecording() {
        guard let requestId = pendingRequestId else {
            log.log("stopRecording — no pending request")
            return
        }

        log.log("⏹ Sending stopSegment command for \(requestId)")

        // Write stop command
        let command = RecordingCommand(
            requestId: requestId,
            action: .stopSegment
        )
        TranscriptionIPC.writeCommand(command)
        TranscriptionIPC.postCommandNotification()

        // Update UI immediately
        status = .transcribing
        stopDurationTimer()
    }

    // MARK: - Cancel

    func cancelRecording() {
        log.log("Cancelling segment")

        if let requestId = pendingRequestId {
            // Send stop to clean up the app side
            let command = RecordingCommand(requestId: requestId, action: .stopSegment)
            TranscriptionIPC.writeCommand(command)
            TranscriptionIPC.postCommandNotification()
        }

        cleanupPending()
        status = .idle
    }

    // MARK: - Open App (one-time prompt)

    func openApp() {
        guard let url = URL(string: "\(AppConstants.urlScheme)://listen") else { return }
        log.log("Opening app to start listening: \(url.absoluteString)")
        urlOpener?(url)
    }

    // MARK: - Listening State

    private func refreshListeningState() {
        let state = TranscriptionIPC.readListeningState()
        if state?.isListening != true {
            // Only show appNotListening if we're idle (don't interrupt active operations)
            if case .idle = status {
                // Do nothing — leave idle, the toolbar will check
            } else if case .appNotListening = status {
                // Already showing
            }
            // Check and potentially update to appNotListening
            if status == .idle || status == .appNotListening {
                status = .appNotListening
            }
        } else {
            // App is listening
            if status == .appNotListening {
                status = .idle
            }
        }
        log.log("refreshListeningState — isListening=\(state?.isListening ?? false), status=\(status)")
    }

    // MARK: - Check for Existing Session

    private func checkForExistingSession() {
        // Check for pending text that wasn't inserted before a reload
        if let text = readPendingText() {
            log.log("♻️ Found pending text from previous session (\(text.count) chars)")
            pendingTranscription = text
        }

        guard let ipcStatus = TranscriptionIPC.readStatus() else { return }

        switch ipcStatus.phase {
        case .recording:
            log.log("♻️ Reconnecting to existing segment: \(ipcStatus.requestId)")
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

        case .listening:
            status = .idle

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

        // Check for status updates
        if let ipcStatus = TranscriptionIPC.readStatus(), ipcStatus.requestId == requestId {
            switch ipcStatus.phase {
            case .recording:
                if status != .recording {
                    status = .recording
                    recordingStartedAt = ipcStatus.recordingStartedAt
                    startDurationTimer()
                    log.log("🎙 App confirmed segment recording")
                }

            case .transcribing:
                if status != .transcribing {
                    status = .transcribing
                    stopDurationTimer()
                    log.log("⏳ App is transcribing")
                }

            case .done, .error, .listening:
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

            if let textInserter {
                log.log("📝 Inserting text via textInserter")
                textInserter(text)
                pendingTranscription = nil
                log.log("📝 Text inserted and consumed")
            } else {
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

    // MARK: - Darwin Notification Observers

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

    private func registerListeningStateObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let state = Unmanaged<VoiceKeyboardState>
                    .fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in state.refreshListeningState() }
            },
            TranscriptionIPC.listeningStateNotificationName,
            nil,
            .deliverImmediately
        )
    }

    private func unregisterObservers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center, observer,
            CFNotificationName(TranscriptionIPC.responseNotificationName),
            nil
        )
        CFNotificationCenterRemoveObserver(
            center, observer,
            CFNotificationName(TranscriptionIPC.listeningStateNotificationName),
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
            if case .error = status {
                refreshListeningState()
            }
        }
    }

    // MARK: - Pending Text Persistence

    private func writePendingText(_ text: String) {
        guard let dir = AppConstants.sharedContainerURL else { return }
        let url = dir.appendingPathComponent("TranscriptionIPC").appendingPathComponent("pending_text.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func readPendingText() -> String? {
        guard let dir = AppConstants.sharedContainerURL else { return nil }
        let url = dir.appendingPathComponent("TranscriptionIPC").appendingPathComponent("pending_text.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    private func clearPendingText() {
        guard let dir = AppConstants.sharedContainerURL else { return }
        let url = dir.appendingPathComponent("TranscriptionIPC").appendingPathComponent("pending_text.txt")
        try? FileManager.default.removeItem(at: url)
    }
}
