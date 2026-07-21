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

enum WatchRemoteRecordingPhase: String, Codable, Equatable, Sendable {
    case queued
    case transcribing
    case delivering
    case delivered
    case failed
    case transportFailed
    case discarded
}

struct WatchRemoteRecordingStatus: Equatable, Sendable {
    let recordingID: String
    let phase: WatchRemoteRecordingPhase
    let revision: Int
    let updatedAt: Date
    let message: String?

    init?(dictionary: [String: Any]) {
        guard let recordingID = dictionary[WatchRecordingPayloadKey.recordingID] as? String,
              let rawPhase = dictionary[WatchRecordingPayloadKey.phase] as? String,
              let phase = WatchRemoteRecordingPhase(rawValue: rawPhase) else { return nil }
        self.recordingID = recordingID
        self.phase = phase
        self.revision = dictionary[WatchRecordingPayloadKey.revision] as? Int ?? 0
        let timestamp = dictionary[WatchRecordingPayloadKey.updatedAt] as? TimeInterval
        self.updatedAt = timestamp.map(Date.init(timeIntervalSince1970:)) ?? Date()
        self.message = dictionary[WatchRecordingPayloadKey.message] as? String
    }
}

enum WatchRecordingCommand: String {
    case start
    case stop
    case toggle
    case status
    case acknowledge
}

enum WatchRecordingFileMetadataKey {
    static let kind = "kind"
    static let watchAudioRecordingKind = "watchAudioRecording"
    static let recordingID = "recordingID"
    static let createdAt = "createdAt"
    static let duration = "duration"
    static let originalFilename = "originalFilename"
    static let presetID = "presetID"
    static let presetName = "presetName"
    static let presetSnapshot = "presetSnapshot"
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
    case delivering
    case pending
    case error
}

struct WatchRecordingSnapshot: Equatable {
    let phase: WatchRecordingPhase
    let sentAt: TimeInterval?
    let stateRevision: Int?
    let isQuickRecordEnabled: Bool
    let recordingStartedAt: TimeInterval?
    let message: String?
    let queuedCount: Int
    let selectedPresetID: String?
    let selectedPresetName: String?
    let selectedPresetSnapshot: Data?
    let recordingStatuses: [WatchRemoteRecordingStatus]

    static let unavailable = WatchRecordingSnapshot(
        phase: .unavailable,
        isQuickRecordEnabled: true,
        recordingStartedAt: nil,
        message: "Open Vox.md on iPhone once.",
        queuedCount: 0,
        selectedPresetID: nil,
        selectedPresetName: nil,
        selectedPresetSnapshot: nil,
        recordingStatuses: []
    )

    static let pending = WatchRecordingSnapshot(
        phase: .pending,
        isQuickRecordEnabled: true,
        recordingStartedAt: nil,
        message: "Sent to iPhone",
        queuedCount: 0,
        selectedPresetID: nil,
        selectedPresetName: nil,
        selectedPresetSnapshot: nil,
        recordingStatuses: []
    )

    init(
        phase: WatchRecordingPhase,
        sentAt: TimeInterval? = nil,
        stateRevision: Int? = nil,
        isQuickRecordEnabled: Bool,
        recordingStartedAt: TimeInterval? = nil,
        message: String? = nil,
        queuedCount: Int = 0,
        selectedPresetID: String? = nil,
        selectedPresetName: String? = nil,
        selectedPresetSnapshot: Data? = nil,
        recordingStatuses: [WatchRemoteRecordingStatus] = []
    ) {
        self.phase = phase
        self.sentAt = sentAt
        self.stateRevision = stateRevision
        self.isQuickRecordEnabled = isQuickRecordEnabled
        self.recordingStartedAt = recordingStartedAt
        self.message = message
        self.queuedCount = max(0, queuedCount)
        self.selectedPresetID = selectedPresetID
        self.selectedPresetName = selectedPresetName
        self.selectedPresetSnapshot = selectedPresetSnapshot
        self.recordingStatuses = recordingStatuses
    }

    init(dictionary: [String: Any]) {
        let rawPhase = dictionary[WatchRecordingPayloadKey.phase] as? String
        let phase = rawPhase.flatMap(WatchRecordingPhase.init(rawValue:)) ?? .unavailable
        let sentAt = dictionary[WatchRecordingPayloadKey.sentAt] as? TimeInterval
        let stateRevision = dictionary[WatchRecordingPayloadKey.stateRevision] as? Int
        let isQuickRecordEnabled = dictionary[WatchRecordingPayloadKey.isQuickRecordEnabled] as? Bool ?? true
        let recordingStartedAt = dictionary[WatchRecordingPayloadKey.recordingStartedAt] as? TimeInterval
        let message = dictionary[WatchRecordingPayloadKey.message] as? String
        let queuedCount = dictionary[WatchRecordingPayloadKey.queuedCount] as? Int ?? 0
        let selectedPresetID = dictionary[WatchRecordingPayloadKey.selectedPresetID] as? String
        let selectedPresetName = dictionary[WatchRecordingPayloadKey.selectedPresetName] as? String
        let selectedPresetSnapshot = dictionary[WatchRecordingPayloadKey.selectedPresetSnapshot] as? Data
        let recordingStatuses = (dictionary[WatchRecordingPayloadKey.recordingStatuses] as? [[String: Any]] ?? [])
            .compactMap(WatchRemoteRecordingStatus.init(dictionary:))
        self.init(
            phase: phase,
            sentAt: sentAt,
            stateRevision: stateRevision,
            isQuickRecordEnabled: isQuickRecordEnabled,
            recordingStartedAt: recordingStartedAt,
            message: message,
            queuedCount: queuedCount,
            selectedPresetID: selectedPresetID,
            selectedPresetName: selectedPresetName,
            selectedPresetSnapshot: selectedPresetSnapshot,
            recordingStatuses: recordingStatuses
        )
    }

    var dictionary: [String: Any] {
        var payload: [String: Any] = [
            WatchRecordingPayloadKey.phase: phase.rawValue,
            WatchRecordingPayloadKey.isQuickRecordEnabled: isQuickRecordEnabled,
            WatchRecordingPayloadKey.sentAt: sentAt ?? Date().timeIntervalSince1970,
        ]
        if let stateRevision {
            payload[WatchRecordingPayloadKey.stateRevision] = stateRevision
        }
        if let recordingStartedAt {
            payload[WatchRecordingPayloadKey.recordingStartedAt] = recordingStartedAt
        }
        if let message, !message.isEmpty {
            payload[WatchRecordingPayloadKey.message] = message
        }
        if queuedCount > 0 {
            payload[WatchRecordingPayloadKey.queuedCount] = queuedCount
        }
        if let selectedPresetID {
            payload[WatchRecordingPayloadKey.selectedPresetID] = selectedPresetID
        }
        if let selectedPresetName {
            payload[WatchRecordingPayloadKey.selectedPresetName] = selectedPresetName
        }
        if let selectedPresetSnapshot {
            payload[WatchRecordingPayloadKey.selectedPresetSnapshot] = selectedPresetSnapshot
        }
        return payload
    }

    var title: String {
        switch phase {
        case .recording: return "Recording"
        case .syncing: return "Syncing"
        case .transcribing: return "Transcribing"
        case .delivering: return "Saving"
        case .listening: return "Ready"
        case .pending: return "Sent"
        case .error: return "Needs attention"
        case .idle, .unavailable: return queuedCount > 0 ? "Saved" : "Vox.md"
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
        case .delivering: return "Saving to Capture"
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
            return "waveform.badge.magnifyingglass"
        case .delivering:
            return "arrow.up.doc"
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

    func acknowledge(recordingID: String, revision: Int) {
        guard WCSession.isSupported() else { return }
        activate()
        let payload: [String: Any] = [
            WatchRecordingPayloadKey.command: WatchRecordingCommand.acknowledge.rawValue,
            WatchRecordingPayloadKey.recordingID: recordingID,
            WatchRecordingPayloadKey.revision: revision,
            WatchRecordingPayloadKey.sentAt: Date().timeIntervalSince1970,
        ]
        let session = WCSession.default
        if session.activationState == .activated, session.isReachable {
            session.sendMessage(payload) { _ in
                // The iPhone reply confirms it processed the acknowledgement.
            } errorHandler: { _ in
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    @discardableResult
    func transferWatchRecording(
        fileURL: URL,
        id: String,
        createdAt: Date,
        duration: TimeInterval,
        presetID: String?,
        presetName: String?,
        presetSnapshot: Data?
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
        if !companionAppIsInstalled(session) {
            setSnapshot(WatchRecordingSnapshot(
                phase: .error,
                isQuickRecordEnabled: true,
                message: "Install Vox.md on iPhone"
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

        var metadata: [String: Any] = [
            WatchRecordingFileMetadataKey.kind: WatchRecordingFileMetadataKey.watchAudioRecordingKind,
            WatchRecordingFileMetadataKey.recordingID: id,
            WatchRecordingFileMetadataKey.createdAt: createdAt.timeIntervalSince1970,
            WatchRecordingFileMetadataKey.duration: duration,
            WatchRecordingFileMetadataKey.originalFilename: fileURL.lastPathComponent,
            WatchRecordingPayloadKey.sentAt: Date().timeIntervalSince1970,
        ]
        if let presetID { metadata[WatchRecordingFileMetadataKey.presetID] = presetID }
        if let presetName { metadata[WatchRecordingFileMetadataKey.presetName] = presetName }
        if let presetSnapshot { metadata[WatchRecordingFileMetadataKey.presetSnapshot] = presetSnapshot }

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
        if session.activationState == .activated, !companionAppIsInstalled(session) {
            let unavailable = WatchRecordingSnapshot(
                phase: .unavailable,
                isQuickRecordEnabled: true,
                message: "Install Vox.md on iPhone"
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
                    self?.setSnapshot(snapshot, preservingRemoteContext: false)
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
                message: "Open Vox.md or leave Keyboard mic on."
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
        case .status, .stop, .acknowledge:
            return false
        case .start:
            return snapshot.phase != .listening && snapshot.phase != .recording
        case .toggle:
            return snapshot.phase != .listening && snapshot.phase != .recording
        }
    }

    private func companionAppIsInstalled(_ session: WCSession) -> Bool {
        #if os(watchOS)
        session.isCompanionAppInstalled
        #else
        true
        #endif
    }

    private func apply(_ payload: [String: Any]) {
        guard !payload.isEmpty else { return }
        setSnapshot(
            WatchRecordingSnapshot(dictionary: payload),
            preservingRemoteContext: false
        )
    }

    private func setSnapshot(
        _ snapshot: WatchRecordingSnapshot,
        preservingRemoteContext: Bool = true
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard preservingRemoteContext else {
                if let incomingRevision = snapshot.stateRevision,
                   let currentRevision = self.snapshot.stateRevision {
                    guard incomingRevision >= currentRevision else { return }
                } else if let incomingDate = snapshot.sentAt,
                          let currentDate = self.snapshot.sentAt,
                          incomingDate < currentDate {
                    return
                }
                self.snapshot = snapshot
                return
            }
            self.snapshot = WatchRecordingSnapshot(
                phase: snapshot.phase,
                sentAt: self.snapshot.sentAt,
                stateRevision: self.snapshot.stateRevision,
                isQuickRecordEnabled: snapshot.isQuickRecordEnabled,
                recordingStartedAt: snapshot.recordingStartedAt,
                message: snapshot.message,
                queuedCount: max(snapshot.queuedCount, self.snapshot.queuedCount),
                selectedPresetID: snapshot.selectedPresetID ?? self.snapshot.selectedPresetID,
                selectedPresetName: snapshot.selectedPresetName ?? self.snapshot.selectedPresetName,
                selectedPresetSnapshot: snapshot.selectedPresetSnapshot ?? self.snapshot.selectedPresetSnapshot,
                recordingStatuses: snapshot.recordingStatuses.isEmpty
                    ? self.snapshot.recordingStatuses
                    : snapshot.recordingStatuses
            )
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

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

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

        // Transport completion is not end-to-end delivery. WatchLocalRecorder
        // retains the source until iPhone reports Capture delivery or discard.
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
