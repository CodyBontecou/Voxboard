import Combine
import Foundation
import WatchConnectivity

/// Property-list keys used by the Watch app/widget and the iPhone host app.
enum WatchRecordingPayloadKey {
    static let command = "command"
    static let phase = "phase"
    static let isQuickRecordEnabled = "isQuickRecordEnabled"
    static let recordingStartedAt = "recordingStartedAt"
    static let recordingDuration = "recordingDuration"
    static let message = "message"
    static let queuedCount = "queuedCount"
    static let selectedPresetID = "selectedPresetID"
    static let selectedPresetName = "selectedPresetName"
    static let selectedPresetSnapshot = "selectedPresetSnapshot"
    static let presetSummaries = "presetSummaries"
    static let presetSummariesTruncated = "presetSummariesTruncated"
    static let presetSelectionAvailable = "presetSelectionAvailable"
    static let presetSymbolName = "presetSymbolName"
    static let requestedPresetID = "requestedPresetID"
    static let presetSelectionRequestID = "presetSelectionRequestID"
    static let presetSelectionEpoch = "presetSelectionEpoch"
    static let presetSelectionSequence = "presetSelectionSequence"
    static let presetSelectionResult = "presetSelectionResult"
    static let presetSelectionError = "presetSelectionError"
    static let recordingStatuses = "recordingStatuses"
    static let recordingID = "recordingID"
    static let revision = "revision"
    static let updatedAt = "updatedAt"
    static let sentAt = "sentAt"
    static let stateEpoch = "stateEpoch"
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

struct WatchCapturePresetSummary: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let symbolName: String

    init?(dictionary: [String: Any]) {
        guard let id = dictionary[WatchRecordingPayloadKey.selectedPresetID] as? String,
              !id.isEmpty,
              let displayName = dictionary[WatchRecordingPayloadKey.selectedPresetName] as? String,
              !displayName.isEmpty else { return nil }
        self.id = id
        self.displayName = displayName
        self.symbolName = (dictionary[WatchRecordingPayloadKey.presetSymbolName] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "waveform"
    }

    var dictionary: [String: Any] {
        [
            WatchRecordingPayloadKey.selectedPresetID: id,
            WatchRecordingPayloadKey.selectedPresetName: displayName,
            WatchRecordingPayloadKey.presetSymbolName: symbolName,
        ]
    }
}

enum WatchPresetSelectionOutcome: String, Equatable, Sendable {
    case accepted
    case rejected
    case stale
}

struct WatchPresetSelectionAcknowledgement: Equatable, Sendable {
    let requestID: String
    let presetID: String
    let epoch: Int64
    let sequence: Int64
    let outcome: WatchPresetSelectionOutcome
    let errorMessage: String?

    init?(dictionary: [String: Any]) {
        guard let requestID = dictionary[WatchRecordingPayloadKey.presetSelectionRequestID] as? String,
              let presetID = dictionary[WatchRecordingPayloadKey.requestedPresetID] as? String,
              let epoch = Self.int64Value(dictionary[WatchRecordingPayloadKey.presetSelectionEpoch]),
              let sequence = Self.int64Value(dictionary[WatchRecordingPayloadKey.presetSelectionSequence]),
              let rawOutcome = dictionary[WatchRecordingPayloadKey.presetSelectionResult] as? String,
              let outcome = WatchPresetSelectionOutcome(rawValue: rawOutcome) else { return nil }
        self.requestID = requestID
        self.presetID = presetID
        self.epoch = epoch
        self.sequence = sequence
        self.outcome = outcome
        self.errorMessage = dictionary[WatchRecordingPayloadKey.presetSelectionError] as? String
    }

    var dictionary: [String: Any] {
        var payload: [String: Any] = [
            WatchRecordingPayloadKey.presetSelectionRequestID: requestID,
            WatchRecordingPayloadKey.requestedPresetID: presetID,
            WatchRecordingPayloadKey.presetSelectionEpoch: epoch,
            WatchRecordingPayloadKey.presetSelectionSequence: sequence,
            WatchRecordingPayloadKey.presetSelectionResult: outcome.rawValue,
        ]
        if let errorMessage, !errorMessage.isEmpty {
            payload[WatchRecordingPayloadKey.presetSelectionError] = errorMessage
        }
        return payload
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}

enum WatchPresetSelectionState: Equatable {
    case idle
    case pending(presetID: String)
    case failed(presetID: String, message: String)

    var pendingPresetID: String? {
        guard case .pending(let presetID) = self else { return nil }
        return presetID
    }

    var errorMessage: String? {
        guard case .failed(_, let message) = self else { return nil }
        return message
    }
}

private struct PendingWatchPresetSelection: Codable, Equatable {
    let requestID: String
    let presetID: String
    let epoch: Int64
    let sequence: Int64
    let sentAt: TimeInterval

    var payload: [String: Any] {
        [
            WatchRecordingPayloadKey.command: WatchRecordingCommand.selectPreset.rawValue,
            WatchRecordingPayloadKey.requestedPresetID: presetID,
            WatchRecordingPayloadKey.presetSelectionRequestID: requestID,
            WatchRecordingPayloadKey.presetSelectionEpoch: epoch,
            WatchRecordingPayloadKey.presetSelectionSequence: sequence,
            WatchRecordingPayloadKey.sentAt: sentAt,
        ]
    }
}

private struct ConfirmedWatchCapturePreset: Codable, Equatable {
    let id: String
    let displayName: String
    let snapshot: Data
}

private enum WatchConfirmedPresetStore {
    private static let confirmedKey = "watchPresetSelection.confirmed.v1"

    static func load() -> ConfirmedWatchCapturePreset? {
        guard let data = UserDefaults.standard.data(forKey: confirmedKey) else { return nil }
        return try? JSONDecoder().decode(ConfirmedWatchCapturePreset.self, from: data)
    }

    static func save(_ preset: ConfirmedWatchCapturePreset?) {
        if let preset, let data = try? JSONEncoder().encode(preset) {
            UserDefaults.standard.set(data, forKey: confirmedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: confirmedKey)
        }
    }
}

private enum WatchPresetSelectionStore {
    private static let pendingKey = "watchPresetSelection.pending.v1"
    private static let epochKey = "watchPresetSelection.epoch.v1"
    private static let sequenceKey = "watchPresetSelection.sequence.v1"

    static func loadPending() -> PendingWatchPresetSelection? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return nil }
        return try? JSONDecoder().decode(PendingWatchPresetSelection.self, from: data)
    }

    static func savePending(_ pending: PendingWatchPresetSelection?) {
        if let pending, let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: pendingKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pendingKey)
        }
    }

    static func makePending(presetID: String) -> PendingWatchPresetSelection {
        let defaults = UserDefaults.standard
        // Physical Watch devices use arm64_32, where Swift Int is 32-bit.
        // Keep millisecond epochs and protocol counters explicitly 64-bit.
        let timestampEpoch = max(1, Int64(Date().timeIntervalSince1970 * 1_000))
        var epoch = int64(forKey: epochKey, defaults: defaults)
        if epoch <= 0 {
            epoch = timestampEpoch
            defaults.set(epoch, forKey: epochKey)
        }
        let current = int64(forKey: sequenceKey, defaults: defaults)
        let sequence: Int64
        if current == Int64.max {
            epoch = epoch < Int64.max ? max(epoch + 1, timestampEpoch) : timestampEpoch
            defaults.set(epoch, forKey: epochKey)
            sequence = 1
        } else {
            sequence = max(1, current + 1)
        }
        defaults.set(sequence, forKey: sequenceKey)
        return PendingWatchPresetSelection(
            requestID: UUID().uuidString,
            presetID: presetID,
            epoch: epoch,
            sequence: sequence,
            sentAt: Date().timeIntervalSince1970
        )
    }

    private static func int64(forKey key: String, defaults: UserDefaults) -> Int64 {
        (defaults.object(forKey: key) as? NSNumber)?.int64Value ?? 0
    }
}

enum WatchRecordingCommand: String {
    case start
    case stop
    case toggle
    case status
    case acknowledge
    case selectPreset
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
    case paused
    case syncing
    case transcribing
    case delivering
    case pending
    case error
}

struct WatchRecordingSnapshot: Equatable {
    let phase: WatchRecordingPhase
    let sentAt: TimeInterval?
    let stateEpoch: Int?
    let stateRevision: Int?
    let isQuickRecordEnabled: Bool
    let recordingStartedAt: TimeInterval?
    let recordingDuration: TimeInterval?
    let message: String?
    let queuedCount: Int
    let selectedPresetID: String?
    let selectedPresetName: String?
    let selectedPresetSnapshot: Data?
    let availablePresets: [WatchCapturePresetSummary]
    let presetSummariesAreTruncated: Bool
    let hasPresetSummariesPayload: Bool
    let presetSelectionIsAvailable: Bool
    let hasPresetSelectionAvailabilityPayload: Bool
    let presetSelectionAcknowledgement: WatchPresetSelectionAcknowledgement?
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
        stateEpoch: Int? = nil,
        stateRevision: Int? = nil,
        isQuickRecordEnabled: Bool,
        recordingStartedAt: TimeInterval? = nil,
        recordingDuration: TimeInterval? = nil,
        message: String? = nil,
        queuedCount: Int = 0,
        selectedPresetID: String? = nil,
        selectedPresetName: String? = nil,
        selectedPresetSnapshot: Data? = nil,
        availablePresets: [WatchCapturePresetSummary] = [],
        presetSummariesAreTruncated: Bool = false,
        hasPresetSummariesPayload: Bool = false,
        presetSelectionIsAvailable: Bool = true,
        hasPresetSelectionAvailabilityPayload: Bool = false,
        presetSelectionAcknowledgement: WatchPresetSelectionAcknowledgement? = nil,
        recordingStatuses: [WatchRemoteRecordingStatus] = []
    ) {
        self.phase = phase
        self.sentAt = sentAt
        self.stateEpoch = stateEpoch
        self.stateRevision = stateRevision
        self.isQuickRecordEnabled = isQuickRecordEnabled
        self.recordingStartedAt = recordingStartedAt
        self.recordingDuration = recordingDuration.map { max(0, $0) }
        self.message = message
        self.queuedCount = max(0, queuedCount)
        self.selectedPresetID = selectedPresetID
        self.selectedPresetName = selectedPresetName
        self.selectedPresetSnapshot = selectedPresetSnapshot
        self.availablePresets = availablePresets
        self.presetSummariesAreTruncated = presetSummariesAreTruncated
        self.hasPresetSummariesPayload = hasPresetSummariesPayload
        self.presetSelectionIsAvailable = presetSelectionIsAvailable
        self.hasPresetSelectionAvailabilityPayload = hasPresetSelectionAvailabilityPayload
        self.presetSelectionAcknowledgement = presetSelectionAcknowledgement
        self.recordingStatuses = recordingStatuses
    }

    init(dictionary: [String: Any]) {
        let rawPhase = dictionary[WatchRecordingPayloadKey.phase] as? String
        let phase = rawPhase.flatMap(WatchRecordingPhase.init(rawValue:)) ?? .unavailable
        let sentAt = dictionary[WatchRecordingPayloadKey.sentAt] as? TimeInterval
        let stateEpoch = dictionary[WatchRecordingPayloadKey.stateEpoch] as? Int
        let stateRevision = dictionary[WatchRecordingPayloadKey.stateRevision] as? Int
        let isQuickRecordEnabled = dictionary[WatchRecordingPayloadKey.isQuickRecordEnabled] as? Bool ?? true
        let recordingStartedAt = dictionary[WatchRecordingPayloadKey.recordingStartedAt] as? TimeInterval
        let recordingDuration = dictionary[WatchRecordingPayloadKey.recordingDuration] as? TimeInterval
        let message = dictionary[WatchRecordingPayloadKey.message] as? String
        let queuedCount = dictionary[WatchRecordingPayloadKey.queuedCount] as? Int ?? 0
        let selectedPresetID = dictionary[WatchRecordingPayloadKey.selectedPresetID] as? String
        let selectedPresetName = dictionary[WatchRecordingPayloadKey.selectedPresetName] as? String
        let selectedPresetSnapshot = dictionary[WatchRecordingPayloadKey.selectedPresetSnapshot] as? Data
        let hasPresetSummariesPayload = dictionary.keys.contains(WatchRecordingPayloadKey.presetSummaries)
        let availablePresets = (dictionary[WatchRecordingPayloadKey.presetSummaries] as? [[String: Any]] ?? [])
            .compactMap(WatchCapturePresetSummary.init(dictionary:))
        let presetSummariesAreTruncated = dictionary[WatchRecordingPayloadKey.presetSummariesTruncated] as? Bool ?? false
        let hasPresetSelectionAvailabilityPayload = dictionary.keys.contains(WatchRecordingPayloadKey.presetSelectionAvailable)
        let presetSelectionIsAvailable = dictionary[WatchRecordingPayloadKey.presetSelectionAvailable] as? Bool ?? true
        let presetSelectionAcknowledgement = WatchPresetSelectionAcknowledgement(dictionary: dictionary)
        let recordingStatuses = (dictionary[WatchRecordingPayloadKey.recordingStatuses] as? [[String: Any]] ?? [])
            .compactMap(WatchRemoteRecordingStatus.init(dictionary:))
        self.init(
            phase: phase,
            sentAt: sentAt,
            stateEpoch: stateEpoch,
            stateRevision: stateRevision,
            isQuickRecordEnabled: isQuickRecordEnabled,
            recordingStartedAt: recordingStartedAt,
            recordingDuration: recordingDuration,
            message: message,
            queuedCount: queuedCount,
            selectedPresetID: selectedPresetID,
            selectedPresetName: selectedPresetName,
            selectedPresetSnapshot: selectedPresetSnapshot,
            availablePresets: availablePresets,
            presetSummariesAreTruncated: presetSummariesAreTruncated,
            hasPresetSummariesPayload: hasPresetSummariesPayload,
            presetSelectionIsAvailable: presetSelectionIsAvailable,
            hasPresetSelectionAvailabilityPayload: hasPresetSelectionAvailabilityPayload,
            presetSelectionAcknowledgement: presetSelectionAcknowledgement,
            recordingStatuses: recordingStatuses
        )
    }

    var dictionary: [String: Any] {
        var payload: [String: Any] = [
            WatchRecordingPayloadKey.phase: phase.rawValue,
            WatchRecordingPayloadKey.isQuickRecordEnabled: isQuickRecordEnabled,
            WatchRecordingPayloadKey.sentAt: sentAt ?? Date().timeIntervalSince1970,
        ]
        if let stateEpoch {
            payload[WatchRecordingPayloadKey.stateEpoch] = stateEpoch
        }
        if let stateRevision {
            payload[WatchRecordingPayloadKey.stateRevision] = stateRevision
        }
        if let recordingStartedAt {
            payload[WatchRecordingPayloadKey.recordingStartedAt] = recordingStartedAt
        }
        if let recordingDuration {
            payload[WatchRecordingPayloadKey.recordingDuration] = recordingDuration
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
        if hasPresetSelectionAvailabilityPayload {
            payload[WatchRecordingPayloadKey.presetSelectionAvailable] = presetSelectionIsAvailable
        }
        if hasPresetSummariesPayload {
            payload[WatchRecordingPayloadKey.presetSummaries] = availablePresets.map(\.dictionary)
            if presetSummariesAreTruncated {
                payload[WatchRecordingPayloadKey.presetSummariesTruncated] = true
            }
        }
        if let presetSelectionAcknowledgement {
            payload.merge(presetSelectionAcknowledgement.dictionary) { _, new in new }
        }
        return payload
    }

    func replacingSelectedPreset(
        id: String?,
        name: String?,
        snapshot: Data?
    ) -> WatchRecordingSnapshot {
        WatchRecordingSnapshot(
            phase: phase,
            sentAt: sentAt,
            stateEpoch: stateEpoch,
            stateRevision: stateRevision,
            isQuickRecordEnabled: isQuickRecordEnabled,
            recordingStartedAt: recordingStartedAt,
            recordingDuration: recordingDuration,
            message: message,
            queuedCount: queuedCount,
            selectedPresetID: id,
            selectedPresetName: name,
            selectedPresetSnapshot: snapshot,
            availablePresets: availablePresets,
            presetSummariesAreTruncated: presetSummariesAreTruncated,
            hasPresetSummariesPayload: hasPresetSummariesPayload,
            presetSelectionIsAvailable: presetSelectionIsAvailable,
            hasPresetSelectionAvailabilityPayload: hasPresetSelectionAvailabilityPayload,
            presetSelectionAcknowledgement: presetSelectionAcknowledgement,
            recordingStatuses: recordingStatuses
        )
    }

    var title: String {
        switch phase {
        case .recording: return "Recording"
        case .paused: return "Paused"
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
        case .paused: return "Paused · tap to stop"
        case .syncing: return "Syncing to iPhone"
        case .transcribing: return "Transcribing on iPhone"
        case .delivering: return "Saving on iPhone"
        case .listening: return "Tap to record"
        case .pending: return "Waiting for iPhone"
        case .error: return "Check iPhone"
        case .idle: return "Tap to record"
        case .unavailable: return "Open iPhone app once"
        }
    }

    var actionTitle: String {
        switch phase {
        case .recording, .paused:
            return "Stop"
        default:
            return "Record"
        }
    }

    var actionSymbol: String {
        switch phase {
        case .recording, .paused:
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

    var pausedDuration: TimeInterval? {
        phase == .paused ? recordingDuration : nil
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
    @Published private(set) var presetSelectionState: WatchPresetSelectionState

    private var hasActivatedSession = false

    override init() {
        let cached = Self.cachedSnapshot()
        let pending = WatchPresetSelectionStore.loadPending()
        if pending != nil, let confirmed = WatchConfirmedPresetStore.load() {
            snapshot = cached.replacingSelectedPreset(
                id: confirmed.id,
                name: confirmed.displayName,
                snapshot: confirmed.snapshot
            )
        } else {
            snapshot = cached
        }
        presetSelectionState = pending.map {
            .pending(presetID: $0.presetID)
        } ?? .idle
        super.init()
        setSnapshot(cached, preservingRemoteContext: false)
    }

    func activate() {
        guard WCSession.isSupported(), !hasActivatedSession else { return }
        hasActivatedSession = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
        apply(session.receivedApplicationContext)
        if session.activationState == .activated {
            resendPendingPresetSelectionIfNeeded(using: session)
        }
    }

    @discardableResult
    func requestStatus() async -> WatchRecordingSnapshot {
        await send(.status)
    }

    func selectPreset(id: String) {
        guard snapshot.availablePresets.contains(where: { $0.id == id }) else {
            presetSelectionState = .failed(
                presetID: id,
                message: "This Capture Preset is no longer available. Refresh from iPhone."
            )
            return
        }
        guard snapshot.selectedPresetID != id else {
            WatchPresetSelectionStore.savePending(nil)
            presetSelectionState = .idle
            return
        }
        guard WCSession.isSupported() else {
            presetSelectionState = .failed(
                presetID: id,
                message: "WatchConnectivity is unavailable."
            )
            return
        }

        let pending = WatchPresetSelectionStore.makePending(presetID: id)
        WatchPresetSelectionStore.savePending(pending)
        presetSelectionState = .pending(presetID: id)

        activate()
        sendPendingPresetSelection(pending, using: WCSession.default)
    }

    private func resendPendingPresetSelectionIfNeeded(using session: WCSession) {
        guard let pending = WatchPresetSelectionStore.loadPending() else { return }
        sendPendingPresetSelection(pending, using: session)
    }

    private func sendPendingPresetSelection(
        _ pending: PendingWatchPresetSelection,
        using session: WCSession
    ) {
        if session.activationState == .activated, !companionAppIsInstalled(session) {
            WatchPresetSelectionStore.savePending(nil)
            DispatchQueue.main.async { [weak self] in
                self?.presetSelectionState = .failed(
                    presetID: pending.presetID,
                    message: "Install Vox.md on iPhone to change presets."
                )
            }
            return
        }

        let payload = pending.payload
        if session.activationState == .activated, session.isReachable {
            session.sendMessage(payload) { [weak self] reply in
                self?.apply(reply)
            } errorHandler: { _ in
                // Selection is idempotent. Reuse the exact persisted payload on
                // the durable channel when sendMessage's outcome is unknown.
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    func clearPresetSelectionError() {
        guard case .failed = presetSelectionState else { return }
        presetSelectionState = .idle
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

    /// `transferFile` is durable but opportunistic. Once watchOS reports the
    /// transfer complete, an immediate status message gives iOS a wake-up event
    /// so its application delegate can activate WCSession and drain the file.
    /// Correctness never depends on this hint; the retained Watch queue remains
    /// the fallback when the phone is unreachable or iOS delays execution.
    private func wakeCompanionForQueuedRecording(using session: WCSession) {
        guard session.activationState == .activated, session.isReachable else { return }
        let payload: [String: Any] = [
            WatchRecordingPayloadKey.command: WatchRecordingCommand.status.rawValue,
            WatchRecordingPayloadKey.sentAt: Date().timeIntervalSince1970,
        ]
        session.sendMessage(payload) { [weak self] reply in
            self?.apply(reply)
        } errorHandler: { _ in
            // The file transfer itself is already durable. A failed wake-up hint
            // must not create a second transfer or discard the Watch copy.
        }
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
                    self?.apply(reply)
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
        setSnapshot(
            pending,
            preservingRemoteContext: command != .status
        )
        return pending
    }

    private func shouldAvoidQueuedBackgroundStart(_ command: WatchRecordingCommand) -> Bool {
        switch command {
        case .status, .stop, .acknowledge, .selectPreset:
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
        _ incoming: WatchRecordingSnapshot,
        preservingRemoteContext: Bool = true
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !preservingRemoteContext,
               !self.remoteSnapshotIsCurrent(incoming) {
                // A request-specific rejection may race behind a newer general
                // state payload. It is still safe to resolve the exact pending
                // token because rejected/stale acknowledgements never adopt
                // preset metadata from this older snapshot.
                if let pending = WatchPresetSelectionStore.loadPending(),
                   self.acknowledgement(incoming.presetSelectionAcknowledgement, matches: pending),
                   let acknowledgement = incoming.presetSelectionAcknowledgement,
                   acknowledgement.outcome != .accepted {
                    WatchPresetSelectionStore.savePending(nil)
                    self.presetSelectionState = .failed(
                        presetID: pending.presetID,
                        message: acknowledgement.errorMessage
                            ?? "The Capture Preset could not be selected."
                    )
                }
                return
            }

            let current = self.snapshot
            var selectedPresetID = current.selectedPresetID
            var selectedPresetName = current.selectedPresetName
            var selectedPresetSnapshot = current.selectedPresetSnapshot
            var nextSelectionState = self.presetSelectionState

            if !preservingRemoteContext {
                let pending = WatchPresetSelectionStore.loadPending()
                let acknowledgementMatchesPending = pending.map { pending in
                    self.acknowledgement(
                        incoming.presetSelectionAcknowledgement,
                        matches: pending
                    )
                } ?? false

                if incoming.hasPresetSelectionAvailabilityPayload,
                   !incoming.presetSelectionIsAvailable {
                    selectedPresetID = nil
                    selectedPresetName = nil
                    selectedPresetSnapshot = nil
                    WatchConfirmedPresetStore.save(nil)
                    if let pending {
                        WatchPresetSelectionStore.savePending(nil)
                        nextSelectionState = .failed(
                            presetID: pending.presetID,
                            message: "Enable a Capture Preset in Vox.md on iPhone first."
                        )
                    }
                } else if let pending, acknowledgementMatchesPending {
                    switch incoming.presetSelectionAcknowledgement?.outcome {
                    case .accepted:
                        if incoming.selectedPresetID == pending.presetID,
                           let name = incoming.selectedPresetName,
                           let presetSnapshot = incoming.selectedPresetSnapshot {
                            selectedPresetID = pending.presetID
                            selectedPresetName = name
                            selectedPresetSnapshot = presetSnapshot
                            WatchConfirmedPresetStore.save(ConfirmedWatchCapturePreset(
                                id: pending.presetID,
                                displayName: name,
                                snapshot: presetSnapshot
                            ))
                            WatchPresetSelectionStore.savePending(nil)
                            nextSelectionState = .idle
                        } else {
                            WatchPresetSelectionStore.savePending(nil)
                            nextSelectionState = .failed(
                                presetID: pending.presetID,
                                message: "iPhone confirmed the preset but did not send its safe snapshot."
                            )
                        }
                    case .rejected, .stale:
                        if let id = incoming.selectedPresetID,
                           let name = incoming.selectedPresetName,
                           let presetSnapshot = incoming.selectedPresetSnapshot {
                            selectedPresetID = id
                            selectedPresetName = name
                            selectedPresetSnapshot = presetSnapshot
                            WatchConfirmedPresetStore.save(ConfirmedWatchCapturePreset(
                                id: id,
                                displayName: name,
                                snapshot: presetSnapshot
                            ))
                        }
                        WatchPresetSelectionStore.savePending(nil)
                        nextSelectionState = .failed(
                            presetID: pending.presetID,
                            message: incoming.presetSelectionAcknowledgement?.errorMessage
                                ?? "The Capture Preset could not be selected."
                        )
                    case .none:
                        break
                    }
                } else if pending == nil,
                          let id = incoming.selectedPresetID,
                          let name = incoming.selectedPresetName,
                          let presetSnapshot = incoming.selectedPresetSnapshot {
                    selectedPresetID = id
                    selectedPresetName = name
                    selectedPresetSnapshot = presetSnapshot
                    WatchConfirmedPresetStore.save(ConfirmedWatchCapturePreset(
                        id: id,
                        displayName: name,
                        snapshot: presetSnapshot
                    ))
                }
                // If a request is pending without its exact acknowledgement,
                // intentionally retain the separately persisted confirmed preset.
            }

            let shouldReplacePresets = !preservingRemoteContext
                && incoming.hasPresetSummariesPayload
            let shouldReplaceAvailability = !preservingRemoteContext
                && incoming.hasPresetSelectionAvailabilityPayload
            self.snapshot = WatchRecordingSnapshot(
                phase: incoming.phase,
                sentAt: preservingRemoteContext ? current.sentAt : incoming.sentAt,
                stateEpoch: preservingRemoteContext ? current.stateEpoch : incoming.stateEpoch,
                stateRevision: preservingRemoteContext ? current.stateRevision : incoming.stateRevision,
                isQuickRecordEnabled: incoming.isQuickRecordEnabled,
                recordingStartedAt: incoming.recordingStartedAt,
                recordingDuration: incoming.recordingDuration,
                message: incoming.message,
                queuedCount: preservingRemoteContext
                    ? max(incoming.queuedCount, current.queuedCount)
                    : incoming.queuedCount,
                selectedPresetID: selectedPresetID,
                selectedPresetName: selectedPresetName,
                selectedPresetSnapshot: selectedPresetSnapshot,
                availablePresets: shouldReplacePresets
                    ? incoming.availablePresets
                    : current.availablePresets,
                presetSummariesAreTruncated: shouldReplacePresets
                    ? incoming.presetSummariesAreTruncated
                    : current.presetSummariesAreTruncated,
                hasPresetSummariesPayload: shouldReplacePresets
                    || current.hasPresetSummariesPayload,
                presetSelectionIsAvailable: shouldReplaceAvailability
                    ? incoming.presetSelectionIsAvailable
                    : current.presetSelectionIsAvailable,
                hasPresetSelectionAvailabilityPayload: shouldReplaceAvailability
                    || current.hasPresetSelectionAvailabilityPayload,
                presetSelectionAcknowledgement: preservingRemoteContext
                    ? current.presetSelectionAcknowledgement
                    : incoming.presetSelectionAcknowledgement
                        ?? current.presetSelectionAcknowledgement,
                recordingStatuses: preservingRemoteContext && incoming.recordingStatuses.isEmpty
                    ? current.recordingStatuses
                    : incoming.recordingStatuses
            )
            self.presetSelectionState = nextSelectionState
        }
    }

    private func acknowledgement(
        _ acknowledgement: WatchPresetSelectionAcknowledgement?,
        matches pending: PendingWatchPresetSelection
    ) -> Bool {
        guard let acknowledgement else { return false }
        return pending.requestID == acknowledgement.requestID
            && pending.presetID == acknowledgement.presetID
            && pending.epoch == acknowledgement.epoch
            && pending.sequence == acknowledgement.sequence
    }

    private func remoteSnapshotIsCurrent(_ incoming: WatchRecordingSnapshot) -> Bool {
        if let incomingEpoch = incoming.stateEpoch,
           let currentEpoch = snapshot.stateEpoch {
            guard incomingEpoch == currentEpoch else { return incomingEpoch > currentEpoch }
            if let incomingRevision = incoming.stateRevision,
               let currentRevision = snapshot.stateRevision {
                return incomingRevision >= currentRevision
            }
        } else if snapshot.stateEpoch != nil {
            // Once epoch-aware state is observed, legacy/partial state cannot
            // replace it. Local transient snapshots use preservingRemoteContext.
            return false
        }

        if let incomingRevision = incoming.stateRevision,
           let currentRevision = snapshot.stateRevision {
            return incomingRevision >= currentRevision
        }
        if let incomingDate = incoming.sentAt,
           let currentDate = snapshot.sentAt {
            return incomingDate >= currentDate
        }
        return true
    }
}

extension WatchPhoneBridge: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        apply(session.receivedApplicationContext)
        resendPendingPresetSelectionIfNeeded(using: session)
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
        wakeCompanionForQueuedRecording(using: session)
        setSnapshot(WatchRecordingSnapshot(
            phase: .pending,
            isQuickRecordEnabled: true,
            message: "Synced to iPhone queue"
        ))
    }
}
