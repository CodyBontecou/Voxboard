import Foundation
import os.log
import UIKit
import UserNotifications
import VoxboardShared
import WatchConnectivity

private let watchLog = Logger(subsystem: "bontecou.Voxboard", category: "WatchRecording")

/// Receives Apple Watch start/stop commands and routes them into the same
/// one-shot recorder used by the Lock Screen widget and Live Activity.
final class WatchRecordingController: NSObject {
    static let shared = WatchRecordingController()

    private weak var recorder: PersistentRecorder?
    private weak var usageTracker: UsageTracker?
    private weak var watchPipeline: WatchRecordingPipeline?
    private var hasActivatedSession = false
    private var needsStatePublishAfterActivation = false
    private let transportFailureDefaultsKey = "watchRecordingTransportFailures.v1"
    private let transportFailureCursorDefaultsKey = "watchRecordingTransportFailureCursor.v1"
    private let stateRevisionDefaultsKey = "watchRecordingStateRevision.v1"

    private override init() {
        super.init()
    }

    func configure(
        recorder: PersistentRecorder,
        usageTracker: UsageTracker,
        watchPipeline: WatchRecordingPipeline? = nil
    ) {
        self.recorder = recorder
        self.usageTracker = usageTracker
        if let watchPipeline {
            self.watchPipeline = watchPipeline
        }
        activateSessionIfNeeded()
        publishState()
    }

    func publishState() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            needsStatePublishAfterActivation = true
            return
        }
        needsStatePublishAfterActivation = false
        let payload = makeStatePayload()
        do {
            try session.updateApplicationContext(payload)
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil) { error in
                    watchLog.debug("Immediate Watch status send failed: \(String(describing: error))")
                }
            }
        } catch {
            needsStatePublishAfterActivation = true
            watchLog.error("Failed to update watch application context: \(String(describing: error))")
        }
    }

    private func activateSessionIfNeeded() {
        guard WCSession.isSupported(), !hasActivatedSession else { return }
        hasActivatedSession = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    @discardableResult
    private func handleWatchPayload(_ payload: [String: Any]) -> [String: Any] {
        let command = (payload[WatchRecordingPayloadKey.command] as? String) ?? WatchRecordingCommand.status.rawValue
        watchLog.notice("Received watch command: \(command, privacy: .public)")

        switch WatchRecordingCommand(rawValue: command) ?? .status {
        case .start:
            startRecordingFromWatch()
        case .stop:
            stopRecordingFromWatch()
        case .toggle:
            toggleRecordingFromWatch()
        case .acknowledge:
            if let recordingID = payload[WatchRecordingPayloadKey.recordingID] as? String {
                let revision = payload[WatchRecordingPayloadKey.revision] as? Int ?? 0
                WatchRecordingInbox.shared.acknowledgeTerminalState(
                    id: recordingID,
                    revision: revision
                )
                watchPipeline?.refresh()
            }
        case .status:
            break
        }

        let state = makeStatePayload()
        publishState()
        return state
    }

    private func startRecordingFromWatch() {
        guard AppConstants.lockScreenQuickRecordEnabled else {
            recorder?.lastError = "Quick Record is disabled in Vox.md Settings"
            return
        }
        guard let recorder else {
            watchLog.error("Watch start requested before recorder was configured")
            return
        }
        guard !recorder.isSegmentActive, !recorder.isTranscribing else { return }

        // A WatchConnectivity wake can run the iPhone app while it is still in
        // the background. iOS only lets background audio continue if it was
        // already started in the foreground; it does not allow starting the
        // iPhone microphone from an arbitrary background Watch command. If the
        // persistent listener is already active, starting a segment is safe.
        guard recorder.isListening || UIApplication.shared.applicationState == .active else {
            recorder.lastError = "iOS blocks background mic start. Open Vox.md or leave Keyboard mic on."
            watchLog.warning("Watch start rejected because iPhone app is not active and recorder is not already listening")
            return
        }

        _ = recorder.startOneShotInAppSegment()
    }

    private func stopRecordingFromWatch() {
        guard let recorder else { return }
        if recorder.isSegmentActive {
            recorder.stopInAppSegment()
        }
    }

    private func toggleRecordingFromWatch() {
        guard let recorder else { return }
        if recorder.isSegmentActive {
            stopRecordingFromWatch()
        } else if !recorder.isTranscribing {
            startRecordingFromWatch()
        }
    }

    private func makeStatePayload() -> [String: Any] {
        let jobs = WatchRecordingInbox.shared.load()
        let visibleJobs = jobs.filter { $0.phase != .discarded }
        let activeJobs = jobs.filter { !$0.phase.isTerminal }
        let activeJob = activeJobs.first(where: { $0.phase == .delivering })
            ?? activeJobs.first(where: { $0.phase == .transcribing })
            ?? activeJobs.first(where: { $0.phase == .queued })
            ?? activeJobs.first(where: { $0.phase == .failed })
        let selectedPresetID = CapturePresetProfileStore.selectedProfileID(
            defaults: AppConstants.sharedDefaults
        )
        let selectedPreset = CapturePresetStore.flow(id: selectedPresetID)
            ?? CapturePresetStore.selectedFlow()

        let message: String?
        if !AppConstants.lockScreenQuickRecordEnabled {
            message = "Quick Record is disabled in Vox.md Settings."
        } else if usageTracker?.isAtLimit == true || recorder?.needsUnlock == true {
            message = "Free limit reached — unlock Vox.md on iPhone."
        } else if let activeJob {
            message = activeJob.statusMessage
        } else {
            message = recorder?.lastError
        }

        let phase: WatchRecordingPhase
        if recorder?.isSegmentActive == true {
            phase = .recording
        } else if activeJob?.phase == .transcribing || recorder?.isTranscribing == true {
            phase = .transcribing
        } else if activeJob?.phase == .delivering {
            phase = .delivering
        } else if activeJob?.phase == .queued {
            phase = .pending
        } else if activeJob?.phase == .failed {
            phase = .error
        } else if recorder?.isListening == true {
            phase = .listening
        } else if message?.isEmpty == false {
            phase = .error
        } else if recorder == nil {
            phase = .unavailable
        } else {
            phase = .idle
        }

        var payload = WatchRecordingSnapshot(
            phase: phase,
            isQuickRecordEnabled: AppConstants.lockScreenQuickRecordEnabled,
            recordingStartedAt: phase == .recording ? currentRecordingStartedAt() : nil,
            message: message
        ).dictionary
        payload[WatchRecordingPayloadKey.stateRevision] = nextStateRevision()
        payload[WatchRecordingPayloadKey.queuedCount] = visibleJobs.filter { !$0.phase.isTerminal }.count
        payload[WatchRecordingPayloadKey.selectedPresetID] = selectedPreset.id
        payload[WatchRecordingPayloadKey.selectedPresetName] = selectedPreset.displayName
        if let snapshot = try? JSONEncoder().encode(selectedPreset) {
            payload[WatchRecordingPayloadKey.selectedPresetSnapshot] = snapshot
        }
        let inProgressStatuses = jobs
            .filter { $0.phase == .transcribing || $0.phase == .delivering }
            .prefix(30)
            .map { WatchRemoteRecordingStatus(item: $0).dictionary }
        let queuedStatuses = jobs
            .filter { $0.phase == .queued }
            .suffix(40)
            .map { WatchRemoteRecordingStatus(item: $0).dictionary }
        let failedStatuses = jobs
            .filter { $0.phase == .failed }
            .suffix(20)
            .map { WatchRemoteRecordingStatus(item: $0).dictionary }
        let terminalStatuses = jobs
            .filter { $0.phase.isTerminal && $0.acknowledgedAt == nil }
            .prefix(40)
            .map { WatchRemoteRecordingStatus(item: $0).dictionary }
        let transportStatuses = nextTransportFailureBatch(limit: 40).map { recordingID, message in
            [
                WatchRecordingPayloadKey.recordingID: recordingID,
                WatchRecordingPayloadKey.phase: "transportFailed",
                WatchRecordingPayloadKey.revision: Int(Date().timeIntervalSince1970),
                WatchRecordingPayloadKey.updatedAt: Date().timeIntervalSince1970,
                WatchRecordingPayloadKey.message: message,
            ] as [String: Any]
        }
        payload[WatchRecordingPayloadKey.recordingStatuses] = inProgressStatuses
            + queuedStatuses
            + transportStatuses
            + failedStatuses
            + terminalStatuses
        return payload
    }

    private func currentRecordingStartedAt() -> TimeInterval? {
        TranscriptionIPC.readStatus()?.recordingStartedAt
    }

    private func nextStateRevision() -> Int {
        let current = UserDefaults.standard.integer(forKey: stateRevisionDefaultsKey)
        let next = current == Int.max ? 1 : current + 1
        UserDefaults.standard.set(next, forKey: stateRevisionDefaultsKey)
        return next
    }

    private func transportFailures() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: transportFailureDefaultsKey) as? [String: String] ?? [:]
    }

    private func nextTransportFailureBatch(limit: Int) -> [(String, String)] {
        let failures = transportFailures()
        let keys = failures.keys.sorted()
        guard keys.count > limit else {
            return keys.compactMap { key in failures[key].map { (key, $0) } }
        }
        let start = UserDefaults.standard.integer(forKey: transportFailureCursorDefaultsKey) % keys.count
        let count = min(limit, keys.count)
        let batch = (0..<count).compactMap { offset -> (String, String)? in
            let key = keys[(start + offset) % keys.count]
            return failures[key].map { (key, $0) }
        }
        UserDefaults.standard.set(
            (start + count) % keys.count,
            forKey: transportFailureCursorDefaultsKey
        )
        return batch
    }

    private func setTransportFailure(recordingID: String, message: String) {
        var failures = transportFailures()
        failures[recordingID] = message
        UserDefaults.standard.set(failures, forKey: transportFailureDefaultsKey)
    }

    private func clearTransportFailure(recordingID: String) {
        var failures = transportFailures()
        guard failures.removeValue(forKey: recordingID) != nil else { return }
        UserDefaults.standard.set(failures, forKey: transportFailureDefaultsKey)
    }

    @MainActor
    private func notifyWatchRecordingReadyIfNeeded() {
        guard UIApplication.shared.applicationState != .active else { return }

        let count = WatchRecordingInbox.shared.load().filter { !$0.phase.isTerminal }.count
        guard count > 0 else { return }

        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                    || settings.authorizationStatus == .ephemeral else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = count == 1 ? "Watch recording ready" : "Watch recordings ready"
            content.body = count == 1
                ? "Open Vox.md to transcribe your Apple Watch recording."
                : "Open Vox.md to transcribe \(count) Apple Watch recordings."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "watch-recording-ready",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}

extension WatchRecordingController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                watchLog.error("Watch session activation failed: \(String(describing: error))")
            }
            if activationState == .activated
                || WatchRecordingController.shared.needsStatePublishAfterActivation {
                WatchRecordingController.shared.publishState()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            let reply = WatchRecordingController.shared.handleWatchPayload(message)
            replyHandler(reply)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            WatchRecordingController.shared.handleWatchPayload(userInfo)
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // WCSession's received file URL is temporary. Apple requires moving it
        // synchronously before this delegate method returns; deferring the work
        // to MainActor lets the system delete the file first, which surfaced as
        // "Could not save Watch recording" on iPhone.
        let logger = Logger(subsystem: "bontecou.Voxboard", category: "WatchRecording")
        let metadata = file.metadata ?? [:]
        let recordingID = metadata[WatchRecordingFileMetadataKey.recordingID] as? String
        do {
            let kind = metadata[WatchRecordingFileMetadataKey.kind] as? String
            guard kind == WatchRecordingFileMetadataKey.watchAudioRecordingKind else {
                logger.notice("Ignoring unknown watch file transfer")
                return
            }

            let item = try WatchRecordingInbox.shared.enqueue(
                fileURL: file.fileURL,
                metadata: metadata
            )
            logger.notice("Queued watch recording: \(item.id, privacy: .public)")
            Task { @MainActor in
                WatchRecordingController.shared.clearTransportFailure(recordingID: item.id)
                WatchRecordingController.shared.watchPipeline?.recordingDidArrive()
                WatchRecordingController.shared.publishState()
                WatchRecordingController.shared.notifyWatchRecordingReadyIfNeeded()
            }
        } catch {
            logger.error("Failed to queue watch recording: \(String(describing: error))")
            Task { @MainActor in
                let message = "iPhone could not save this transfer. Tap Sync on Watch to retry."
                if let recordingID {
                    WatchRecordingController.shared.setTransportFailure(
                        recordingID: recordingID,
                        message: message
                    )
                }
                WatchRecordingController.shared.recorder?.lastError = "Could not save Watch recording: \(error.localizedDescription)"
                WatchRecordingController.shared.publishState()
            }
        }
    }
}

nonisolated enum WatchRecordingPayloadKey {
    static let command = "command"
    static let phase = "phase"
    static let isQuickRecordEnabled = "isQuickRecordEnabled"
    static let recordingStartedAt = "recordingStartedAt"
    static let message = "message"
    static let queuedCount = "queuedCount"
    static let selectedPresetID = "selectedPresetID"
    static let selectedPresetName = "selectedPresetName"
    static let selectedPresetSnapshot = "selectedPresetSnapshot"
    static let recordingStatuses = "recordingStatuses"
    static let recordingID = "recordingID"
    static let revision = "revision"
    static let updatedAt = "updatedAt"
    static let sentAt = "sentAt"
    static let stateRevision = "stateRevision"
}

nonisolated enum WatchRecordingCommand: String {
    case start
    case stop
    case toggle
    case status
    case acknowledge
}

nonisolated enum WatchRecordingPhase: String {
    case unavailable
    case idle
    case listening
    case recording
    case syncing
    case transcribing
    case delivering
    case pending
    case error
}

nonisolated struct WatchRemoteRecordingStatus {
    let recordingID: String
    let phaseRawValue: String
    let revision: Int
    let updatedAt: Date
    let message: String?

    init(item: WatchRecordingInboxItem) {
        recordingID = item.id
        phaseRawValue = !item.hasAudio && !item.phase.isTerminal
            ? "transportFailed"
            : item.phase.rawValue
        revision = item.revision
        updatedAt = item.updatedAt
        message = item.statusMessage
    }

    var dictionary: [String: Any] {
        var value: [String: Any] = [
            WatchRecordingPayloadKey.recordingID: recordingID,
            WatchRecordingPayloadKey.phase: phaseRawValue,
            WatchRecordingPayloadKey.revision: revision,
            WatchRecordingPayloadKey.updatedAt: updatedAt.timeIntervalSince1970,
        ]
        if let message, !message.isEmpty {
            value[WatchRecordingPayloadKey.message] = message
        }
        return value
    }
}

nonisolated struct WatchRecordingSnapshot {
    let phase: WatchRecordingPhase
    let isQuickRecordEnabled: Bool
    let recordingStartedAt: TimeInterval?
    let message: String?

    init(
        phase: WatchRecordingPhase,
        isQuickRecordEnabled: Bool,
        recordingStartedAt: TimeInterval? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        self.isQuickRecordEnabled = isQuickRecordEnabled
        self.recordingStartedAt = recordingStartedAt
        self.message = message
    }

    var dictionary: [String: Any] {
        var payload: [String: Any] = [
            WatchRecordingPayloadKey.phase: phase.rawValue,
            WatchRecordingPayloadKey.isQuickRecordEnabled: isQuickRecordEnabled,
            WatchRecordingPayloadKey.sentAt: Date().timeIntervalSince1970,
        ]
        if let recordingStartedAt {
            payload[WatchRecordingPayloadKey.recordingStartedAt] = recordingStartedAt
        }
        if let message, !message.isEmpty {
            payload[WatchRecordingPayloadKey.message] = message
        }
        return payload
    }
}
