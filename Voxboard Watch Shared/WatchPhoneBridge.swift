import Combine
import Foundation
import WatchConnectivity

/// Property-list keys used by the Watch app/widget and the iPhone host app.
enum WatchRecordingPayloadKey {
    static let command = "command"
    static let phase = "phase"
    static let isQuickRecordEnabled = "isQuickRecordEnabled"
    static let recordingStartedAt = "recordingStartedAt"
    static let message = "message"
    static let queuedCount = "queuedCount"
    static let sentAt = "sentAt"
}

enum WatchRecordingCommand: String {
    case start
    case stop
    case toggle
    case status
}

enum WatchRecordingFileMetadataKey {
    static let kind = "kind"
    static let watchAudioRecordingKind = "watchAudioRecording"
    static let recordingID = "recordingID"
    static let createdAt = "createdAt"
    static let duration = "duration"
    static let originalFilename = "originalFilename"
}

enum WatchRecordingDeepLink {
    static let scheme = "voxboardwatch"
    static let startHost = "start-recording"
    static let stopHost = "stop-recording"
    static let toggleHost = "toggle-recording"
    static let startURL = URL(string: "\(scheme)://\(startHost)")!
    static let stopURL = URL(string: "\(scheme)://\(stopHost)")!
    static let toggleURL = URL(string: "\(scheme)://\(toggleHost)")!
}

enum WatchRecordingTransferNotificationKey {
    static let recordingID = "recordingID"
    static let success = "success"
    static let errorMessage = "errorMessage"
}

extension Notification.Name {
    static let watchRecordingTransferDidFinish = Notification.Name("WatchRecordingTransferDidFinish")
}

enum WatchRecordingPhase: String {
    case unavailable
    case idle
    case listening
    case recording
    case syncing
    case transcribing
    case pending
    case error
}

struct WatchRecordingSnapshot: Equatable {
    let phase: WatchRecordingPhase
    let isQuickRecordEnabled: Bool
    let recordingStartedAt: TimeInterval?
    let message: String?
    let queuedCount: Int

    static let unavailable = WatchRecordingSnapshot(
        phase: .unavailable,
        isQuickRecordEnabled: true,
        recordingStartedAt: nil,
        message: "Open Voxboard on iPhone once.",
        queuedCount: 0
    )

    static let pending = WatchRecordingSnapshot(
        phase: .pending,
        isQuickRecordEnabled: true,
        recordingStartedAt: nil,
        message: "Sent to iPhone",
        queuedCount: 0
    )

    init(
        phase: WatchRecordingPhase,
        isQuickRecordEnabled: Bool,
        recordingStartedAt: TimeInterval? = nil,
        message: String? = nil,
        queuedCount: Int = 0
    ) {
        self.phase = phase
        self.isQuickRecordEnabled = isQuickRecordEnabled
        self.recordingStartedAt = recordingStartedAt
        self.message = message
        self.queuedCount = max(0, queuedCount)
    }

    init(dictionary: [String: Any]) {
        let rawPhase = dictionary[WatchRecordingPayloadKey.phase] as? String
        let phase = rawPhase.flatMap(WatchRecordingPhase.init(rawValue:)) ?? .unavailable
        let isQuickRecordEnabled = dictionary[WatchRecordingPayloadKey.isQuickRecordEnabled] as? Bool ?? true
        let recordingStartedAt = dictionary[WatchRecordingPayloadKey.recordingStartedAt] as? TimeInterval
        let message = dictionary[WatchRecordingPayloadKey.message] as? String
        let queuedCount = dictionary[WatchRecordingPayloadKey.queuedCount] as? Int ?? 0
        self.init(
            phase: phase,
            isQuickRecordEnabled: isQuickRecordEnabled,
            recordingStartedAt: recordingStartedAt,
            message: message,
            queuedCount: queuedCount
        )
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
        if queuedCount > 0 {
            payload[WatchRecordingPayloadKey.queuedCount] = queuedCount
        }
        return payload
    }

    var title: String {
        switch phase {
        case .recording: return "Recording"
        case .syncing: return "Syncing"
        case .transcribing: return "Processing"
        case .listening: return "Ready"
        case .pending: return "Sent"
        case .error: return "Needs attention"
        case .idle, .unavailable: return queuedCount > 0 ? "Saved" : "Voxboard"
        }
    }

    var subtitle: String {
        if !isQuickRecordEnabled { return "Quick Record off" }
        if let message, !message.isEmpty { return message }
        if queuedCount > 0 {
            return queuedCount == 1 ? "1 saved on Watch" : "\(queuedCount) saved on Watch"
        }
        switch phase {
        case .recording: return "Tap to stop"
        case .syncing: return "Syncing to iPhone"
        case .transcribing: return "Transcribing on iPhone"
        case .listening: return "Tap to record"
        case .pending: return "Waiting for iPhone"
        case .error: return "Check iPhone"
        case .idle: return "Tap to record"
        case .unavailable: return "Open iPhone app once"
        }
    }

    var actionTitle: String {
        phase == .recording ? "Stop" : "Record"
    }

    var actionSymbol: String {
        switch phase {
        case .recording:
            return "stop.fill"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .transcribing:
            return "hourglass"
        case .error, .unavailable:
            return "exclamationmark.triangle.fill"
        default:
            return "mic.fill"
        }
    }

    var shouldShowTimer: Bool {
        phase == .recording && recordingStartedAt != nil
    }
}

enum WatchLocalSnapshotStore {
    private static let suiteName = "group.bontecou.Voxboard"
    private static let snapshotKey = "watchLocalRecordingSnapshot"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func save(_ snapshot: WatchRecordingSnapshot) {
        defaults.set(snapshot.dictionary, forKey: snapshotKey)
        defaults.synchronize()
    }

    static func load() -> WatchRecordingSnapshot? {
        guard let dictionary = defaults.dictionary(forKey: snapshotKey) else { return nil }
        return WatchRecordingSnapshot(dictionary: dictionary)
    }
}

final class WatchPhoneBridge: NSObject, ObservableObject {
    static let shared = WatchPhoneBridge()

    @Published private(set) var snapshot: WatchRecordingSnapshot

    private var hasActivatedSession = false

    override init() {
        snapshot = Self.cachedSnapshot()
        super.init()
    }

    func activate() {
        guard WCSession.isSupported(), !hasActivatedSession else { return }
        hasActivatedSession = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
        apply(session.receivedApplicationContext)
    }

    @discardableResult
    func requestStatus() async -> WatchRecordingSnapshot {
        await send(.status)
    }

    @discardableResult
    func transferWatchRecording(
        fileURL: URL,
        id: String,
        createdAt: Date,
        duration: TimeInterval
    ) -> Bool {
        guard WCSession.isSupported() else {
            setSnapshot(WatchRecordingSnapshot(
                phase: .error,
                isQuickRecordEnabled: true,
                message: "WatchConnectivity unavailable"
            ))
            return false
        }

        activate()
        let session = WCSession.default
        guard session.activationState == .activated else {
            setSnapshot(WatchRecordingSnapshot(
                phase: .error,
                isQuickRecordEnabled: true,
                message: "Watch sync is still connecting"
            ))
            return false
        }
        if !session.isCompanionAppInstalled {
            setSnapshot(WatchRecordingSnapshot(
                phase: .error,
                isQuickRecordEnabled: true,
                message: "Install Voxboard on iPhone"
            ))
            return false
        }

        if session.outstandingFileTransfers.contains(where: { transfer in
            let metadata = transfer.file.metadata ?? [:]
            return metadata[WatchRecordingFileMetadataKey.recordingID] as? String == id
        }) {
            setSnapshot(WatchRecordingSnapshot(
                phase: .pending,
                isQuickRecordEnabled: true,
                message: "Watch recording already syncing"
            ))
            return true
        }

        let metadata: [String: Any] = [
            WatchRecordingFileMetadataKey.kind: WatchRecordingFileMetadataKey.watchAudioRecordingKind,
            WatchRecordingFileMetadataKey.recordingID: id,
            WatchRecordingFileMetadataKey.createdAt: createdAt.timeIntervalSince1970,
            WatchRecordingFileMetadataKey.duration: duration,
            WatchRecordingFileMetadataKey.originalFilename: fileURL.lastPathComponent,
            WatchRecordingPayloadKey.sentAt: Date().timeIntervalSince1970,
        ]

        session.transferFile(fileURL, metadata: metadata)
        setSnapshot(WatchRecordingSnapshot(
            phase: .pending,
            isQuickRecordEnabled: true,
            message: "Watch recording queued for iPhone"
        ))
        return true
    }

    @discardableResult
    func send(_ command: WatchRecordingCommand) async -> WatchRecordingSnapshot {
        guard WCSession.isSupported() else {
            let unavailable = WatchRecordingSnapshot(
                phase: .unavailable,
                isQuickRecordEnabled: true,
                message: "WatchConnectivity unavailable"
            )
            setSnapshot(unavailable)
            return unavailable
        }

        activate()
        let session = WCSession.default
        if session.activationState == .activated, !session.isCompanionAppInstalled {
            let unavailable = WatchRecordingSnapshot(
                phase: .unavailable,
                isQuickRecordEnabled: true,
                message: "Install Voxboard on iPhone"
            )
            setSnapshot(unavailable)
            return unavailable
        }

        let payload: [String: Any] = [
            WatchRecordingPayloadKey.command: command.rawValue,
            WatchRecordingPayloadKey.sentAt: Date().timeIntervalSince1970,
        ]

        if session.activationState == .activated, session.isReachable {
            return await withCheckedContinuation { continuation in
                session.sendMessage(payload) { [weak self] reply in
                    let snapshot = WatchRecordingSnapshot(dictionary: reply)
                    self?.setSnapshot(snapshot)
                    continuation.resume(returning: snapshot)
                } errorHandler: { [weak self] _ in
                    let snapshot = self?.fallbackForUnreachablePhone(payload, command: command) ?? .pending
                    continuation.resume(returning: snapshot)
                }
            }
        }

        return fallbackForUnreachablePhone(payload, command: command)
    }

    static func cachedSnapshot() -> WatchRecordingSnapshot {
        guard WCSession.isSupported() else { return .unavailable }
        let context = WCSession.default.receivedApplicationContext
        guard !context.isEmpty else { return .unavailable }
        return WatchRecordingSnapshot(dictionary: context)
    }

    private func fallbackForUnreachablePhone(_ payload: [String: Any], command: WatchRecordingCommand) -> WatchRecordingSnapshot {
        if shouldAvoidQueuedBackgroundStart(command) {
            let blocked = WatchRecordingSnapshot(
                phase: .error,
                isQuickRecordEnabled: snapshot.isQuickRecordEnabled,
                message: "Open Voxboard or leave Keyboard mic on."
            )
            setSnapshot(blocked)
            return blocked
        }

        if command != .status {
            WCSession.default.transferUserInfo(payload)
        }
        let pending = command == .status ? Self.cachedSnapshot() : WatchRecordingSnapshot.pending
        setSnapshot(pending)
        return pending
    }

    private func shouldAvoidQueuedBackgroundStart(_ command: WatchRecordingCommand) -> Bool {
        switch command {
        case .status, .stop:
            return false
        case .start:
            return snapshot.phase != .listening && snapshot.phase != .recording
        case .toggle:
            return snapshot.phase != .listening && snapshot.phase != .recording
        }
    }

    private func apply(_ payload: [String: Any]) {
        guard !payload.isEmpty else { return }
        setSnapshot(WatchRecordingSnapshot(dictionary: payload))
    }

    private func setSnapshot(_ snapshot: WatchRecordingSnapshot) {
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = snapshot
        }
    }
}

extension WatchPhoneBridge: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        apply(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        apply(message)
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let metadata = fileTransfer.file.metadata ?? [:]
        var userInfo: [String: Any] = [
            WatchRecordingTransferNotificationKey.success: error == nil,
        ]
        if let recordingID = metadata[WatchRecordingFileMetadataKey.recordingID] as? String {
            userInfo[WatchRecordingTransferNotificationKey.recordingID] = recordingID
        }
        if let error {
            userInfo[WatchRecordingTransferNotificationKey.errorMessage] = error.localizedDescription
            NotificationCenter.default.post(
                name: .watchRecordingTransferDidFinish,
                object: self,
                userInfo: userInfo
            )
            setSnapshot(WatchRecordingSnapshot(
                phase: .error,
                isQuickRecordEnabled: true,
                message: "iPhone sync failed: \(error.localizedDescription)"
            ))
            return
        }

        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        NotificationCenter.default.post(
            name: .watchRecordingTransferDidFinish,
            object: self,
            userInfo: userInfo
        )
        setSnapshot(WatchRecordingSnapshot(
            phase: .pending,
            isQuickRecordEnabled: true,
            message: "Synced to iPhone queue"
        ))
    }
}
