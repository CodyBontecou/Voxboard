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
    private var hasActivatedSession = false

    private override init() {
        super.init()
    }

    func configure(recorder: PersistentRecorder, usageTracker: UsageTracker) {
        self.recorder = recorder
        self.usageTracker = usageTracker
        activateSessionIfNeeded()
        publishState()
    }

    func publishState() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        do {
            try WCSession.default.updateApplicationContext(makeStatePayload())
        } catch {
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
        case .status:
            break
        }

        let state = makeStatePayload()
        publishState()
        return state
    }

    private func startRecordingFromWatch() {
        guard AppConstants.lockScreenQuickRecordEnabled else {
            recorder?.lastError = "Quick Record is disabled in Voxboard Settings"
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
            recorder.lastError = "iOS blocks background mic start. Open Voxboard or leave Keyboard mic on."
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
        guard let recorder else {
            return WatchRecordingSnapshot(
                phase: .unavailable,
                isQuickRecordEnabled: AppConstants.lockScreenQuickRecordEnabled,
                message: "Open Voxboard on iPhone once to pair recording controls."
            ).dictionary
        }

        let message: String?
        if !AppConstants.lockScreenQuickRecordEnabled {
            message = "Quick Record is disabled in Voxboard Settings."
        } else if usageTracker?.isAtLimit == true || recorder.needsUnlock {
            message = "Free limit reached — unlock Voxboard on iPhone."
        } else {
            message = recorder.lastError
        }

        let phase: WatchRecordingPhase
        if recorder.isSegmentActive {
            phase = .recording
        } else if recorder.isTranscribing {
            phase = .transcribing
        } else if recorder.isListening {
            phase = .listening
        } else if message?.isEmpty == false {
            phase = .error
        } else {
            phase = .idle
        }

        return WatchRecordingSnapshot(
            phase: phase,
            isQuickRecordEnabled: AppConstants.lockScreenQuickRecordEnabled,
            recordingStartedAt: phase == .recording ? currentRecordingStartedAt() : nil,
            message: message
        ).dictionary
    }

    private func currentRecordingStartedAt() -> TimeInterval? {
        TranscriptionIPC.readStatus()?.recordingStartedAt
    }

    @MainActor
    private func notifyWatchRecordingReadyIfNeeded() {
        guard UIApplication.shared.applicationState != .active else { return }

        let count = WatchRecordingInbox.shared.load().count
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
                ? "Open Voxboard to transcribe your Apple Watch recording."
                : "Open Voxboard to transcribe \(count) Apple Watch recordings."
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
            WatchRecordingController.shared.publishState()
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
        do {
            let metadata = file.metadata ?? [:]
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
                WatchRecordingController.shared.publishState()
                WatchRecordingController.shared.notifyWatchRecordingReadyIfNeeded()
            }
        } catch {
            logger.error("Failed to queue watch recording: \(String(describing: error))")
            Task { @MainActor in
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
    static let sentAt = "sentAt"
}

nonisolated enum WatchRecordingCommand: String {
    case start
    case stop
    case toggle
    case status
}

nonisolated enum WatchRecordingPhase: String {
    case unavailable
    case idle
    case listening
    case recording
    case transcribing
    case pending
    case error
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
