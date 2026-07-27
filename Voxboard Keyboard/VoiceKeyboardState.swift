import Foundation
import UIKit
import VoxboardShared

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
/// If the app isn't listening yet, the keyboard prompts the user to open Voxboard once.
@MainActor
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
    var selectedFlowId: String = CapturePresetStore.selectedFlowId()

    /// Rolling audio levels for the waveform animation (most recent last).
    /// Updated from the poll timer during recording.
    var audioLevels: [Float] = Array(repeating: 0, count: 7)

    /// Text retained when the document proxy is temporarily unavailable. The
    /// controller inserts it on the next appearance and then clears persistence.
    var pendingTranscription: String?

    /// Tentative Apple Speech tail for toolbar display only. It is never inserted
    /// into another app because volatile recognition can be revised.
    var volatileTranscription: String?

    private var deliveredLiveText = ""
    private var deliveredLiveRevision = 0

    /// Closure provided by KeyboardViewController to open URLs via the responder chain.
    /// Used only to prompt opening the app when it's not listening.
    var urlOpener: ((URL) -> Void)?

    /// Closure provided by KeyboardViewController to insert text via textDocumentProxy.
    var textInserter: ((String) -> Void)?

    private struct BackendOption {
        let id: String
        let name: String
        let localModel: WhisperModelInfo?
    }

    // Automatic is always available as a selection. Local model options only
    // appear after the user explicitly downloads them in the main app.
    private var cachedBackendOptions: [BackendOption] = []
    private var cachedDownloadedModels: [WhisperModelInfo] = []
    private var cachedFlows: [CapturePreset] = []

    // When the user taps the mic button while app isn't listening,
    // we open the app and set this flag so recording auto-starts
    // once the app signals it's listening.
    private var pendingAutoRecord = false
    private var cachedHasFullAccess = false

    // IPC state
    private var pendingRequestId: String?
    private var pollTimer: Timer?
    private var durationTimer: Timer?
    private var recordingStartedAt: TimeInterval?
    private var transcribingStartedAt: TimeInterval?
    private var recordingAcknowledged = false
    private var stopRequestedBeforeAcknowledgement = false
    private var lastCommandNotificationAt: TimeInterval?
    /// Wall-clock time when the user tapped Stop — used by the transcript-store fallback.
    private var segmentStopTime: Date?

    private let startAcknowledgementTimeout: TimeInterval = 3
    private let commandNotificationRetryInterval: TimeInterval = 0.5

    /// Apple may need to prepare a system-managed locale asset on first use.
    /// Keep the existing resilient transcript-store fallback alive long enough.
    private let transcriptionTimeout: TimeInterval = 90

    init() {
        // Ensure the shared IPC directory exists before recovery reads and writes.
        TranscriptionIPC.ensureDirectory()

        // Cache downloaded models and flows so Record tap doesn't hit the filesystem
        refreshModelCache()
        refreshFlowCache()

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

    /// Refresh Automatic plus the models the user has explicitly downloaded.
    func refreshModelCache() {
        cachedDownloadedModels = WhisperModelInfo.availableModels.filter { $0.isDownloaded }
        cachedBackendOptions = [
            BackendOption(
                id: TranscriptionBackendID.automatic,
                name: String(localized: "Automatic"),
                localModel: nil
            )
        ] + cachedDownloadedModels.map {
            BackendOption(id: $0.id, name: $0.name, localModel: $0)
        }

        let persistedID = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
            ?? AppConstants.defaultTranscriptionBackendID
        selectedModelIndex = cachedBackendOptions.firstIndex(where: { $0.id == persistedID }) ?? 0

        log.log("refreshModelCache — \(cachedBackendOptions.count) backends cached, selected: \(currentModelName)")
    }

    var downloadedModels: [WhisperModelInfo] {
        cachedDownloadedModels
    }

    private var currentBackend: BackendOption? {
        guard !cachedBackendOptions.isEmpty else { return nil }
        let index = min(selectedModelIndex, cachedBackendOptions.count - 1)
        return cachedBackendOptions[max(0, index)]
    }

    var currentModelName: String {
        currentBackend?.name ?? String(localized: "Automatic")
    }

    var currentFlow: CapturePreset {
        let flows = cachedFlows.filter(\.isEnabled)
        return flows.first(where: { $0.id == selectedFlowId })
            ?? CapturePresetStore.selectedFlow()
    }

    var currentFlowName: String {
        currentFlow.displayName
    }

    var currentFlowShortLabel: String {
        currentFlow.shortLabel
    }

    func refreshFlowCache() {
        cachedFlows = CapturePresetStore.loadFlows()
        selectedFlowId = CapturePresetStore.selectedFlowId()
    }

    func nextFlow() {
        refreshFlowCache()
        let next = CapturePresetStore.selectNextFlow()
        selectedFlowId = next.id
        refreshFlowCache()
        log.log("Flow switched to: \(next.displayName)")
    }

    // MARK: - Model Navigation

    func previousModel() {
        let count = cachedBackendOptions.count
        guard count > 0 else { return }
        selectedModelIndex = (selectedModelIndex - 1 + count) % count
        persistSelectedModel()
        log.log("Model switched to: \(currentModelName)")
    }

    func nextModel() {
        let count = cachedBackendOptions.count
        guard count > 0 else { return }
        selectedModelIndex = (selectedModelIndex + 1) % count
        persistSelectedModel()
        log.log("Model switched to: \(currentModelName)")
    }

    /// Save the current backend selection to shared UserDefaults so it survives
    /// keyboard restarts and stays in sync with the main app's settings.
    private func persistSelectedModel() {
        guard let backend = currentBackend else { return }
        AppConstants.sharedDefaults?.set(backend.id, forKey: AppConstants.selectedModelKey)
        if let localModel = backend.localModel {
            AppConstants.sharedDefaults?.set(localModel.id, forKey: AppConstants.selectedFallbackModelKey)
        }
    }

    // MARK: - Start Recording (send IPC command — no app switch!)

    func startRecording(hasFullAccess: Bool) {
        log.log("startRecording — hasFullAccess=\(hasFullAccess), status=\(status)")

        guard hasFullAccess else {
            status = .needsFullAccess
            log.log("❌ No full access")
            return
        }

        guard let backend = currentBackend else {
            refreshModelCache()
            guard currentBackend != nil else {
                status = .noModel
                log.log("❌ No transcription backend available")
                return
            }
            startRecording(hasFullAccess: hasFullAccess)
            return
        }

        if backend.id == TranscriptionBackendID.automatic,
           AppConstants.sharedDefaults?.bool(forKey: AppConstants.automaticBackendReadyKey) != true {
            refreshModelCache()
            if cachedDownloadedModels.isEmpty {
                status = .noModel
                log.log("❌ Automatic backend is not ready — open Vox.md to prepare Apple Speech or download a fallback")
                return
            }
        }

        // Check if free tier is exhausted
        if UsageTracker.staticIsAtLimit {
            status = .error(String(localized: "Limit reached — open Vox.md to unlock"))
            log.log("🔒 startRecording blocked — free tier limit reached")
            resetErrorAfterDelay()
            return
        }

        // Check if app is listening (cached — fast read). Require a fresh
        // heartbeat so we don't send commands to a stale state file left behind
        // after iOS kills the background app.
        let listeningState = TranscriptionIPC.readListeningState()
        guard TranscriptionIPC.isListeningStateFresh(listeningState) else {
            status = .appNotListening
            log.log("❌ App is not listening or heartbeat is stale — opening Vox.md once")
            openApp(hasFullAccess: hasFullAccess)
            return
        }

        refreshFlowCache()
        let requestId = UUID().uuidString
        let language = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey) ?? "auto"
        let flowId = currentFlow.id

        // Update UI immediately — don't wait for IPC round-trip
        TranscriptionIPC.clearLiveTranscriptionState()
        deliveredLiveText = ""
        deliveredLiveRevision = 0
        volatileTranscription = nil
        pendingRequestId = requestId
        recordingStartedAt = Date().timeIntervalSince1970
        recordingDuration = 0
        recordingAcknowledged = false
        stopRequestedBeforeAcknowledgement = false
        status = .recording

        // Write startSegment command and post notification immediately
        // Skip clearing stale response/status — requestId filtering handles it
        let command = RecordingCommand(
            requestId: requestId,
            action: .startSegment,
            modelId: backend.id,
            language: language,
            flowId: flowId,
            origin: .keyboardExtension
        )
        TranscriptionIPC.writeCommand(command)
        TranscriptionIPC.postCommandNotification()
        lastCommandNotificationAt = Date().timeIntervalSince1970

        log.log("📤 Sent startSegment command (requestId=\(requestId), backend=\(backend.id), flow=\(flowId))")

        // Start local duration timer
        startDurationTimer()

        // Start polling for status updates
        startPolling()
    }

    // MARK: - Stop Recording (send IPC command — no app switch!)

    func stopRecording() {
        guard status == .recording, let requestId = pendingRequestId else {
            log.log("stopRecording — no active recording")
            return
        }

        guard recordingAcknowledged else {
            // Never overwrite an unclaimed start command with stop. Remember the
            // user's intent and stop immediately once the app acknowledges start.
            stopRequestedBeforeAcknowledgement = true
            TranscriptionIPC.postCommandNotification()
            lastCommandNotificationAt = Date().timeIntervalSince1970
            log.log("⏹ Stop requested while waiting for app start acknowledgement")
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
        lastCommandNotificationAt = Date().timeIntervalSince1970

        // Update UI immediately
        status = .transcribing
        transcribingStartedAt = Date().timeIntervalSince1970
        segmentStopTime = Date()
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

    func openApp(hasFullAccess: Bool = true) {
        guard let url = URL(string: "\(AppConstants.urlScheme)://listen") else { return }
        log.log("Opening app to start listening: \(url.absoluteString) (pendingAutoRecord=true)")
        cachedHasFullAccess = hasFullAccess
        pendingAutoRecord = true
        urlOpener?(url)
    }

    // MARK: - Listening State

    /// Public entry point for refreshing listening state (called from viewDidAppear).
    func refreshListeningStatePublic() {
        refreshListeningState()
    }

    private func refreshListeningState() {
        let state = TranscriptionIPC.readListeningState()
        let isFreshListening = TranscriptionIPC.isListeningStateFresh(state)
        if !isFreshListening {
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

                // Auto-start recording if the user tapped the mic button to open the app
                if pendingAutoRecord {
                    pendingAutoRecord = false
                    log.log("🎙 Auto-starting recording after app became available")
                    startRecording(hasFullAccess: cachedHasFullAccess)
                }
            }
        }
        log.log("refreshListeningState — isListening=\(state?.isListening ?? false), fresh=\(isFreshListening), status=\(status)")
    }

    // MARK: - Check for Existing Session

    private func checkForExistingSession() {
        // Check for pending text that wasn't inserted before a reload
        if let text = readPendingText() {
            log.log("♻️ Found pending text from previous session (\(text.count) chars)")
            pendingTranscription = text
        }

        // Recover a completed response only when it belongs to the current IPC
        // session. Live responses must first reconcile against the persisted
        // delivery checkpoint to avoid pasting the cumulative text twice.
        if let response = TranscriptionIPC.readResponse() {
            let statusRequestId = TranscriptionIPC.readStatus()?.requestId
            if statusRequestId == nil || statusRequestId == response.requestId {
                log.log("♻️ Recovering orphaned transcription response for \(response.requestId.prefix(8))")
                pendingRequestId = response.requestId
                restoreLiveDeliveryCheckpoint(for: response.requestId)
                finishWithResponse(response)
                return
            }
            log.log("♻️ Ignoring stale response for \(response.requestId.prefix(8))")
        }

        guard let ipcStatus = TranscriptionIPC.readStatus() else { return }

        let hasFreshListener = TranscriptionIPC.isListeningStateFresh(TranscriptionIPC.readListeningState())

        switch ipcStatus.phase {
        case .recording:
            guard hasFreshListener else {
                log.log("♻️ Clearing stale recording session — listening heartbeat missing")
                TranscriptionIPC.clearStatus()
                status = .appNotListening
                return
            }
            log.log("♻️ Reconnecting to existing segment: \(ipcStatus.requestId)")
            pendingRequestId = ipcStatus.requestId
            restoreLiveDeliveryCheckpoint(for: ipcStatus.requestId)
            processLiveSnapshot(for: ipcStatus.requestId)
            recordingStartedAt = ipcStatus.recordingStartedAt
            recordingAcknowledged = true
            status = .recording
            startPolling()
            startDurationTimer()

        case .transcribing:
            // Check if the transcription is stale (> 2 minutes old)
            let stoppedAt = ipcStatus.recordingStoppedAt
                ?? ipcStatus.recordingStartedAt
                ?? Date().timeIntervalSince1970
            if Date().timeIntervalSince1970 - stoppedAt > 120 {
                log.log("♻️ Clearing stale transcription session (>2 min old)")
                TranscriptionIPC.clearStatus()
            } else if !hasFreshListener {
                log.log("♻️ Clearing stale transcription session — listening heartbeat missing")
                TranscriptionIPC.clearStatus()
                status = .appNotListening
            } else {
                log.log("♻️ Reconnecting to existing transcription: \(ipcStatus.requestId)")
                pendingRequestId = ipcStatus.requestId
                restoreLiveDeliveryCheckpoint(for: ipcStatus.requestId)
                processLiveSnapshot(for: ipcStatus.requestId)
                transcribingStartedAt = stoppedAt
                segmentStopTime = Date(timeIntervalSince1970: stoppedAt)
                recordingAcknowledged = true
                status = .transcribing
                startPolling()
            }

        case .done:
            log.log("♻️ Clearing completed session status")
            TranscriptionIPC.clearStatus()

        case .error:
            log.log("♻️ Clearing error session status: \(ipcStatus.message ?? "unknown")")
            TranscriptionIPC.clearStatus()

        case .listening:
            status = hasFreshListener ? .idle : .appNotListening
            if !hasFreshListener {
                TranscriptionIPC.clearStatus()
            }
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

    // MARK: - Suspension Recovery

    // MARK: - Suspension Recovery

    /// Called from viewDidAppear to recover from extension suspension.
    ///
    /// When the keyboard extension is suspended (e.g. user briefly switches to
    /// another app while transcribing), the poll timer stops and Darwin
    /// notifications may not be delivered. On resume, we need to:
    ///  1. Immediately check the shared container for a completed response.
    ///  2. Restart the poll timer so we catch it if it hasn't arrived yet.
    func resumeAfterSuspension() {
        guard pendingRequestId != nil else { return }
        log.log("resumeAfterSuspension — pending request found, status=\(status)")

        // Restart poll timer if it was killed by suspension
        if pollTimer == nil {
            startPolling()
        }

        // Immediately check — the response may already be in the shared container.
        // Use DispatchQueue.main.async + assumeIsolated for the same reliability
        // reason as the poll timer and Darwin notification callbacks.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.checkForUpdates() }
        }
    }

    // MARK: - Polling for Status & Response

    private func startPolling() {
        pollTimer?.invalidate()
        // Use DispatchQueue.main.async + MainActor.assumeIsolated so the callback always
        // runs on the main thread regardless of which thread the timer fires on.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated { self.checkForUpdates() }
            }
        }
    }

    /// Throttle counter so we don't spam the log on every poll.
    private var pollCount: Int = 0

    private func restoreLiveDeliveryCheckpoint(for requestId: String) {
        guard let checkpoint = TranscriptionIPC.readLiveDeliveryCheckpoint(),
              checkpoint.requestId == requestId else {
            deliveredLiveText = ""
            deliveredLiveRevision = 0
            return
        }
        deliveredLiveText = checkpoint.deliveredText
        deliveredLiveRevision = checkpoint.revision
    }

    @MainActor
    private func processLiveSnapshot(for requestId: String) {
        guard let snapshot = TranscriptionIPC.readLiveSnapshot(),
              snapshot.requestId == requestId else { return }

        volatileTranscription = snapshot.volatileText
        guard snapshot.revision > deliveredLiveRevision else { return }
        guard snapshot.finalizedText.hasPrefix(deliveredLiveText) else {
            log.log("⚠️ Ignoring non-monotonic live transcript revision \(snapshot.revision)")
            return
        }

        let delta = String(snapshot.finalizedText.dropFirst(deliveredLiveText.count))
        let checkpoint = LiveTranscriptionDeliveryCheckpoint(
            requestId: requestId,
            revision: snapshot.revision,
            deliveredText: snapshot.finalizedText
        )

        // Persist first: if iOS terminates the keyboard between these two calls,
        // recovery favors avoiding duplicated dictated text.
        guard TranscriptionIPC.writeLiveDeliveryCheckpoint(checkpoint) else {
            log.log("⚠️ Could not persist live delivery checkpoint; delaying insertion")
            return
        }
        deliveredLiveText = snapshot.finalizedText
        deliveredLiveRevision = snapshot.revision

        guard !delta.isEmpty else { return }
        if let textInserter {
            log.log("📝 Inserting live Apple Speech delta (\(delta.count) chars)")
            textInserter(delta)
        } else {
            let pending = (pendingTranscription ?? "") + delta
            pendingTranscription = pending
            writePendingText(pending)
        }
    }

    @MainActor
    private func checkForUpdates() {
        guard let requestId = pendingRequestId else { return }

        pollCount += 1
        let now = Date().timeIntervalSince1970
        processLiveSnapshot(for: requestId)

        // A terminal response wins over timeout handling, including at the exact
        // timeout boundary.
        if let response = TranscriptionIPC.readResponse(), response.requestId == requestId {
            log.log("📥 Response received for \(requestId.prefix(8))")
            pollCount = 0
            finishWithResponse(response)
            return
        }

        // Read audio levels during recording for waveform animation.
        if status == .recording, let level = TranscriptionIPC.readAudioLevel() {
            audioLevels.removeFirst()
            audioLevels.append(level)
        }

        let ipcStatus = TranscriptionIPC.readStatus()
        let matchingStatus = ipcStatus?.requestId == requestId ? ipcStatus : nil

        if let matchingStatus {
            switch matchingStatus.phase {
            case .recording:
                let wasAcknowledged = recordingAcknowledged
                recordingAcknowledged = true
                if !wasAcknowledged {
                    recordingStartedAt = matchingStatus.recordingStartedAt ?? recordingStartedAt
                    log.log("🎙 App confirmed segment recording")
                }
                // Do not move a locally stopped request back from transcribing
                // just because the app's recording status is still in flight.
                if stopRequestedBeforeAcknowledgement {
                    stopRequestedBeforeAcknowledgement = false
                    stopRecording()
                    return
                }

            case .transcribing:
                recordingAcknowledged = true
                if status != .transcribing {
                    let stoppedAt = matchingStatus.recordingStoppedAt ?? now
                    status = .transcribing
                    transcribingStartedAt = stoppedAt
                    segmentStopTime = Date(timeIntervalSince1970: stoppedAt)
                    stopDurationTimer()
                    log.log("⏳ App is transcribing")
                }

            case .error:
                let message = matchingStatus.message
                    ?? String(localized: "Recording failed — try again")
                log.log("📥 App reported recording error: \(message)")
                finishWithResponse(TranscriptionResponse(
                    requestId: requestId,
                    error: message
                ))
                return

            case .done, .listening:
                break
            }
        }

        // Darwin notifications can be delayed in the background. Re-post while
        // the durable command file remains unclaimed; the app also polls it.
        if let command = TranscriptionIPC.readCommand(), command.requestId == requestId,
           now - (lastCommandNotificationAt ?? 0) >= commandNotificationRetryInterval {
            TranscriptionIPC.postCommandNotification()
            lastCommandNotificationAt = now
        }

        // Do not display an optimistic recording indefinitely. Most starts are
        // acknowledged in under 250 ms; three seconds leaves ample background
        // scheduling margin while avoiding a fake recording with no waveform.
        if status == .recording, !recordingAcknowledged,
           let startedAt = recordingStartedAt,
           now - startedAt > startAcknowledgementTimeout {
            log.log("⏰ App did not acknowledge startSegment")
            clearPendingCommand(for: requestId)
            cleanupPending()
            TranscriptionIPC.clearLiveTranscriptionState()
            status = .error(String(localized: "Vox.md did not start recording — reopen Listening Mode and try again"))
            resetErrorAfterDelay()
            return
        }

        // Check for transcription timeout only after terminal artifacts.
        if status == .transcribing,
           let startedAt = transcribingStartedAt,
           now - startedAt > transcriptionTimeout {
            log.log("⏰ Transcription timed out after \(Int(transcriptionTimeout))s")
            clearPendingCommand(for: requestId)
            cleanupPending()
            TranscriptionIPC.clearResponse()
            TranscriptionIPC.clearStatus()
            TranscriptionIPC.clearLiveTranscriptionState()
            status = .error(String(localized: "Transcription timed out — try again"))
            resetErrorAfterDelay()
            return
        }

        if let response = TranscriptionIPC.readResponse(),
           response.requestId != requestId,
           pollCount % 30 == 0 {
            log.log("⚠️ Ignoring response for a different request — expected=\(requestId.prefix(8)) got=\(response.requestId.prefix(8))")
        } else if TranscriptionIPC.readResponse() == nil {
            if status == .transcribing, pollCount % 30 == 0 {
                let elapsed = transcribingStartedAt.map { now - $0 } ?? 0
                log.log("⏳ Waiting for response… poll=\(pollCount) elapsed=\(Int(elapsed))s pendingId=\(requestId.prefix(8))")
            }

            // The app writes history before asynchronous post-processing. If the
            // response artifact is lost, recover a transcript newer than Stop.
            if status == .transcribing,
               let stopTime = segmentStopTime,
               let startedAt = transcribingStartedAt,
               now - startedAt > 5,
               pollCount % 10 == 0,
               let text = latestTranscriptSince(stopTime) {
                log.log("🔄 Transcript-store fallback triggered — using latest entry (\(text.count) chars)")
                pollCount = 0
                finishWithResponse(TranscriptionResponse(
                    requestId: requestId,
                    text: text,
                    usesLiveTranscription: deliveredLiveText.isEmpty ? nil : true
                ))
            }
        }
    }

    private func clearPendingCommand(for requestId: String) {
        guard TranscriptionIPC.readCommand()?.requestId == requestId else { return }
        TranscriptionIPC.clearCommand()
    }

    /// Read transcripts.json from the shared container and return the text of the
    /// most recent entry if it was created after `since`. Returns nil if the store
    /// is empty, unreadable, or no transcript is newer than `since`.
    private func latestTranscriptSince(_ since: Date) -> String? {
        guard let dir = AppConstants.sharedContainerURL else { return nil }
        let url = dir.appendingPathComponent("transcripts.json")
        guard let data = try? Data(contentsOf: url),
              let transcripts = try? JSONDecoder().decode([Transcript].self, from: data),
              let latest = transcripts.first  // newest is always at index 0
        else { return nil }
        // Only use it if it was created after the user tapped Stop
        guard latest.date > since else { return nil }
        return latest.text
    }

    /// Process a completed transcription response (happy path or fallback).
    @MainActor
    private func finishWithResponse(_ response: TranscriptionResponse) {
        if response.usesLiveTranscription == true {
            processLiveSnapshot(for: response.requestId)
        }

        let existingPendingText = pendingTranscription ?? ""
        let textToInsert: String?
        var reconciliationFailed = false

        if let text = response.text, !text.isEmpty {
            log.log("✅ Transcription ready (\(text.count) chars)")
            if response.usesLiveTranscription == true {
                switch TranscriptionInsertionPlanner.plan(
                    deliveredText: deliveredLiveText,
                    finalText: text
                ) {
                case .insert(let suffix):
                    textToInsert = suffix
                case .alreadyComplete:
                    textToInsert = nil
                case .unsafeMismatch:
                    textToInsert = nil
                    reconciliationFailed = true
                }
            } else {
                textToInsert = text
            }
        } else {
            textToInsert = nil
        }

        cleanupPending()
        TranscriptionIPC.clearResponse()
        TranscriptionIPC.clearStatus()
        TranscriptionIPC.clearLiveTranscriptionState()

        if reconciliationFailed {
            let message = String(localized: "Transcript saved, but the remaining text could not be safely inserted")
            log.log("⚠️ \(message)")
            status = .error(message)
            resetErrorAfterDelay()
            return
        }

        guard response.text?.isEmpty == false else {
            let msg = response.error ?? String(localized: "No speech detected")
            log.log("⚠️ \(msg)")
            status = .error(msg)
            resetErrorAfterDelay()
            return
        }

        status = .idle
        let pending = existingPendingText + (textToInsert ?? "")
        guard !pending.isEmpty else {
            pendingTranscription = nil
            clearPendingText()
            return
        }

        pendingTranscription = pending
        if let textInserter {
            log.log("📝 Inserting remaining transcription (\(pending.count) chars)")
            textInserter(pending)
            pendingTranscription = nil
            clearPendingText()
        } else {
            log.log("⚠️ No textInserter — persisting transcription for recovery")
            writePendingText(pending)
        }
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        stopDurationTimer()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    guard let startedAt = self.recordingStartedAt else { return }
                    self.recordingDuration = Date().timeIntervalSince1970 - startedAt
                }
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
        transcribingStartedAt = nil
        recordingAcknowledged = false
        stopRequestedBeforeAcknowledgement = false
        lastCommandNotificationAt = nil
        segmentStopTime = nil
        recordingDuration = 0
        audioLevels = Array(repeating: 0, count: 7)
        volatileTranscription = nil
        deliveredLiveText = ""
        deliveredLiveRevision = 0
        pollCount = 0
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
                // Use DispatchQueue.main.async + MainActor.assumeIsolated instead of
                // Task { @MainActor in ... } — Tasks in keyboard extensions can be
                // silently delayed or dropped under memory pressure. This path is
                // synchronous on the main thread, which is always what we want.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { state.checkForUpdates() }
                }
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
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { state.refreshListeningState() }
                }
            },
            TranscriptionIPC.listeningStateNotificationName,
            nil,
            .deliverImmediately
        )
    }

    nonisolated private func unregisterObservers() {
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
