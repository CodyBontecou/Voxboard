import Foundation

// MARK: - Request / Response Models

/// Written by the keyboard extension, read by the main app.
public struct TranscriptionRequest: Codable, Sendable {
    public let id: String
    public let audioFileName: String
    public let modelId: String
    public let language: String
    public let createdAt: TimeInterval

    public init(audioFileName: String, modelId: String, language: String) {
        self.id = UUID().uuidString
        self.audioFileName = audioFileName
        self.modelId = modelId
        self.language = language
        self.createdAt = Date().timeIntervalSince1970
    }
}

/// Written by the main app, read by the keyboard extension.
public struct TranscriptionResponse: Codable, Sendable {
    public let requestId: String
    public let text: String?
    public let error: String?
    /// True when finalized Apple Speech text may already have been inserted
    /// incrementally. Optional so responses from older app versions still decode.
    public let usesLiveTranscription: Bool?

    public init(
        requestId: String,
        text: String? = nil,
        error: String? = nil,
        usesLiveTranscription: Bool? = nil
    ) {
        self.requestId = requestId
        self.text = text
        self.error = error
        self.usesLiveTranscription = usesLiveTranscription
    }
}

/// Latest cumulative Apple Speech state written by the app and polled by the
/// keyboard. A cumulative snapshot makes missed Darwin notifications harmless.
public struct LiveTranscriptionSnapshot: Codable, Equatable, Sendable {
    public let requestId: String
    public let revision: Int
    public let finalizedText: String
    public let volatileText: String?
    public let updatedAt: TimeInterval

    public init(
        requestId: String,
        revision: Int,
        finalizedText: String,
        volatileText: String? = nil,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.requestId = requestId
        self.revision = revision
        self.finalizedText = finalizedText
        self.volatileText = volatileText
        self.updatedAt = updatedAt
    }
}

/// Keyboard-owned delivery state persisted before inserting a finalized delta.
/// It favors at-most-once insertion if iOS terminates the extension mid-update.
public struct LiveTranscriptionDeliveryCheckpoint: Codable, Equatable, Sendable {
    public let requestId: String
    public let revision: Int
    public let deliveredText: String

    public init(requestId: String, revision: Int, deliveredText: String) {
        self.requestId = requestId
        self.revision = revision
        self.deliveredText = deliveredText
    }
}

/// Status file written by the main app so the keyboard can show live progress.
public struct RecordingStatus: Codable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case listening     // Always-on mode — waiting for segment commands
        case recording     // A segment is being captured
        case transcribing
        case done
        case error
    }

    public let requestId: String
    public let phase: Phase
    public let message: String?
    /// Timestamp when recording started (TimeInterval since 1970).
    /// The keyboard uses this to display an accurate recording timer.
    public let recordingStartedAt: TimeInterval?
    /// Timestamp when capture ended and batch transcription began. Optional so
    /// status files written by older app versions remain decodable.
    public let recordingStoppedAt: TimeInterval?
    /// Exact source-audio coverage in `0...1` when the active backend exposes it.
    /// Nil means active but indeterminate, not zero progress.
    public let transcriptionProgress: Double?
    /// Last time the host confirmed activity for this request. Keyboard timeout
    /// recovery uses it to distinguish a long advancing job from a stalled one.
    public let updatedAt: TimeInterval?

    public init(
        requestId: String,
        phase: Phase,
        message: String? = nil,
        recordingStartedAt: TimeInterval? = nil,
        recordingStoppedAt: TimeInterval? = nil,
        transcriptionProgress: Double? = nil,
        updatedAt: TimeInterval? = Date().timeIntervalSince1970
    ) {
        self.requestId = requestId
        self.phase = phase
        self.message = message
        self.recordingStartedAt = recordingStartedAt
        self.recordingStoppedAt = recordingStoppedAt
        self.transcriptionProgress = transcriptionProgress.flatMap {
            $0.isFinite ? min(1, max(0, $0)) : nil
        }
        self.updatedAt = updatedAt
    }
}

/// Describes a live recording segment started directly in the app or through IPC.
public struct RecordingCommand: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case stop          // Legacy: stop recording (kept for compat)
        case startSegment  // Mark the beginning of a transcription segment
        case stopSegment   // Mark the end — extract audio and transcribe
    }

    public enum Origin: String, Codable, Sendable {
        case keyboardExtension
        case inAppDraft
        case inAppImmediate
        case quickRecord
        case liveActivity
        case watch
    }

    public let requestId: String
    public let action: Action
    public let modelId: String?
    public let language: String?
    public let flowId: String?
    /// Optional for backward compatibility with commands written by older builds.
    public let origin: Origin?

    public init(
        requestId: String,
        action: Action,
        modelId: String? = nil,
        language: String? = nil,
        flowId: String? = nil,
        origin: Origin? = nil
    ) {
        self.requestId = requestId
        self.action = action
        self.modelId = modelId
        self.language = language
        self.flowId = flowId
        self.origin = origin
    }

    /// Resolve the recorder-owned request ID that a stop command may target.
    /// Requiring an exact identity prevents stale extensions or Live Activities
    /// from stopping a newer, unrelated recording.
    public func resolvedStopRequestId(activeRequestId: String?) -> String? {
        guard action == .stopSegment || action == .stop,
              let activeRequestId,
              !activeRequestId.isEmpty,
              requestId == activeRequestId else { return nil }
        return activeRequestId
    }
}

/// Persistent state written by the main app so the keyboard knows if the
/// always-on recorder is active. Survives app backgrounding.
public struct ListeningState: Codable, Sendable {
    public let isListening: Bool
    public let startedAt: TimeInterval
    /// Updated periodically while the host app is alive and the persistent
    /// recorder is running. The keyboard uses this to avoid sending commands to
    /// a stale `isListening=true` file left behind after iOS kills the app.
    public let lastHeartbeatAt: TimeInterval?

    public init(isListening: Bool, startedAt: TimeInterval = 0, lastHeartbeatAt: TimeInterval? = nil) {
        self.isListening = isListening
        self.startedAt = startedAt
        self.lastHeartbeatAt = lastHeartbeatAt
    }
}

// MARK: - IPC Helpers

/// File-based IPC between the keyboard extension and the main app.
///
/// **Always-on flow** (primary):
/// 1. Keyboard opens Voxboard via `voxboard://listen` → app starts persistent recording
/// 2. App writes listeningState.json (isListening=true)
/// 3. User switches to any app, brings up the keyboard
/// 4. Keyboard reads listeningState → shows "Ready" with Record button
/// 5. User taps Record → keyboard writes command.json (startSegment) + posts notification
/// 6. App marks segment start in circular buffer, writes status.json (recording)
/// 7. User taps Stop → keyboard writes command.json (stopSegment) + posts notification
/// 8. App extracts audio segment, transcribes, writes response.json
/// 9. Keyboard reads response, inserts text
///
/// **Legacy flow** (kept for backward compatibility):
/// 1. Keyboard opens main app via URL scheme: voxboard://record?model=X&lang=Y&requestId=Z
/// 2. Main app starts recording, writes status.json (phase=recording)
/// 3. User switches back → keyboard sends stop command → app transcribes → keyboard inserts
public enum TranscriptionIPC {

    // MARK: - Darwin notification names

    /// Keyboard → App: "I have a new transcription request" (legacy)
    public static let requestNotificationName =
        "group.bontecou.Voxboard.transcribeRequest" as CFString

    /// App → Keyboard: "The response is ready"
    public static let responseNotificationName =
        "group.bontecou.Voxboard.transcribeResponse" as CFString

    /// Keyboard → App: "Stop recording now" (legacy)
    public static let stopCommandNotificationName =
        "group.bontecou.Voxboard.stopRecording" as CFString

    /// Keyboard → App: general command notification (startSegment, stopSegment)
    public static let commandNotificationName =
        "group.bontecou.Voxboard.command" as CFString

    /// App → Keyboard: listening state changed
    public static let listeningStateNotificationName =
        "group.bontecou.Voxboard.listeningState" as CFString

    // MARK: - File URLs

    private static var ipcDirectory: URL? {
        AppConstants.sharedContainerURL?.appendingPathComponent("TranscriptionIPC")
    }

    public static var requestURL: URL? {
        ipcDirectory?.appendingPathComponent("request.json")
    }

    public static var responseURL: URL? {
        ipcDirectory?.appendingPathComponent("response.json")
    }

    public static var statusURL: URL? {
        ipcDirectory?.appendingPathComponent("status.json")
    }

    public static var commandURL: URL? {
        ipcDirectory?.appendingPathComponent("command.json")
    }

    public static var listeningStateURL: URL? {
        ipcDirectory?.appendingPathComponent("listening_state.json")
    }

    public static var audioLevelURL: URL? {
        ipcDirectory?.appendingPathComponent("audio_level.bin")
    }

    public static var liveSnapshotURL: URL? {
        ipcDirectory?.appendingPathComponent("live_transcription.json")
    }

    public static var liveDeliveryCheckpointURL: URL? {
        ipcDirectory?.appendingPathComponent("live_delivery_checkpoint.json")
    }

    /// How long the keyboard should trust a positive listening state without a
    /// heartbeat from the main app. This must be longer than the recorder's
    /// heartbeat interval so background timer jitter doesn't cause false opens.
    public static let listeningStateFreshnessInterval: TimeInterval = 45

    public static func isListeningStateFresh(
        _ state: ListeningState?,
        now: TimeInterval = Date().timeIntervalSince1970,
        freshnessInterval: TimeInterval = listeningStateFreshnessInterval
    ) -> Bool {
        guard let state, state.isListening else { return false }
        let heartbeat = state.lastHeartbeatAt ?? state.startedAt
        guard heartbeat > 0 else { return false }
        return now - heartbeat <= freshnessInterval
    }

    public static func ensureDirectory() {
        guard let dir = ipcDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Write / Read: Request

    public static func writeRequest(_ request: TranscriptionRequest) throws {
        ensureDirectory()
        if let url = responseURL { try? FileManager.default.removeItem(at: url) }
        if let url = statusURL { try? FileManager.default.removeItem(at: url) }
        if let url = commandURL { try? FileManager.default.removeItem(at: url) }

        guard let url = requestURL else { throw IPCError.noContainer }
        let data = try JSONEncoder().encode(request)
        try data.write(to: url, options: .atomic)
    }

    public static func readRequest() -> TranscriptionRequest? {
        guard let url = requestURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptionRequest.self, from: data)
    }

    // MARK: - Write / Read: Response

    public static func writeResponse(_ response: TranscriptionResponse) throws {
        ensureDirectory()
        guard let url = responseURL else { throw IPCError.noContainer }
        let data = try JSONEncoder().encode(response)
        try data.write(to: url, options: .atomic)
    }

    public static func readResponse() -> TranscriptionResponse? {
        guard let url = responseURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptionResponse.self, from: data)
    }

    // MARK: - Write / Read: Live Transcription

    public static func writeLiveSnapshot(_ snapshot: LiveTranscriptionSnapshot) {
        ensureDirectory()
        guard let url = liveSnapshotURL,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func readLiveSnapshot() -> LiveTranscriptionSnapshot? {
        guard let url = liveSnapshotURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LiveTranscriptionSnapshot.self, from: data)
    }

    @discardableResult
    public static func writeLiveDeliveryCheckpoint(
        _ checkpoint: LiveTranscriptionDeliveryCheckpoint
    ) -> Bool {
        ensureDirectory()
        guard let url = liveDeliveryCheckpointURL,
              let data = try? JSONEncoder().encode(checkpoint) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func readLiveDeliveryCheckpoint() -> LiveTranscriptionDeliveryCheckpoint? {
        guard let url = liveDeliveryCheckpointURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LiveTranscriptionDeliveryCheckpoint.self, from: data)
    }

    // MARK: - Write / Read: Status

    public static func writeStatus(_ status: RecordingStatus) {
        ensureDirectory()
        guard let url = statusURL,
              let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func readStatus() -> RecordingStatus? {
        guard let url = statusURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordingStatus.self, from: data)
    }

    // MARK: - Write / Read: Command

    public static func writeCommand(_ command: RecordingCommand) {
        ensureDirectory()
        guard let url = commandURL,
              let data = try? JSONEncoder().encode(command) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func readCommand() -> RecordingCommand? {
        guard let url = commandURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordingCommand.self, from: data)
    }

    // MARK: - Write / Read: ListeningState

    public static func writeListeningState(_ state: ListeningState) {
        ensureDirectory()
        guard let url = listeningStateURL,
              let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func readListeningState() -> ListeningState? {
        guard let url = listeningStateURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ListeningState.self, from: data)
    }

    public static func clearListeningState() {
        guard let url = listeningStateURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Write / Read: Audio Level

    /// Write the current audio RMS level (0.0–1.0) as a raw 4-byte Float for minimal overhead.
    public static func writeAudioLevel(_ level: Float) {
        guard let url = audioLevelURL else { return }
        var value = level
        let data = Data(bytes: &value, count: MemoryLayout<Float>.size)
        try? data.write(to: url, options: .atomic)
    }

    /// Read the current audio RMS level. Returns nil if the file doesn't exist.
    public static func readAudioLevel() -> Float? {
        guard let url = audioLevelURL,
              let data = try? Data(contentsOf: url),
              data.count == MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { $0.load(as: Float.self) }
    }

    public static func clearAudioLevel() {
        guard let url = audioLevelURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Clear

    public static func clearRequest() {
        guard let url = requestURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public static func clearResponse() {
        guard let url = responseURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public static func clearStatus() {
        guard let url = statusURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public static func clearCommand() {
        guard let url = commandURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public static func clearLiveSnapshot() {
        guard let url = liveSnapshotURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public static func clearLiveDeliveryCheckpoint() {
        guard let url = liveDeliveryCheckpointURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public static func clearLiveTranscriptionState() {
        clearLiveSnapshot()
        clearLiveDeliveryCheckpoint()
    }

    // MARK: - Darwin notifications

    public static func postRequestNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(requestNotificationName),
            nil, nil, true
        )
    }

    public static func postResponseNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(responseNotificationName),
            nil, nil, true
        )
    }

    public static func postStopCommandNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(stopCommandNotificationName),
            nil, nil, true
        )
    }

    public static func postCommandNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(commandNotificationName),
            nil, nil, true
        )
    }

    public static func postListeningStateNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(listeningStateNotificationName),
            nil, nil, true
        )
    }

    public enum IPCError: Error {
        case noContainer
    }
}
