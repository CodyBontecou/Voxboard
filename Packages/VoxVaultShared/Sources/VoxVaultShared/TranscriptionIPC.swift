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

    public init(requestId: String, text: String? = nil, error: String? = nil) {
        self.requestId = requestId
        self.text = text
        self.error = error
    }
}

/// Status file written by the main app so the keyboard can show live progress.
public struct RecordingStatus: Codable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case recording
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

    public init(requestId: String, phase: Phase, message: String? = nil, recordingStartedAt: TimeInterval? = nil) {
        self.requestId = requestId
        self.phase = phase
        self.message = message
        self.recordingStartedAt = recordingStartedAt
    }
}

/// Command file written by the keyboard extension to tell the app to stop recording.
public struct RecordingCommand: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case stop
    }

    public let requestId: String
    public let action: Action

    public init(requestId: String, action: Action) {
        self.requestId = requestId
        self.action = action
    }
}

// MARK: - IPC Helpers

/// File-based IPC between the keyboard extension and the main app.
///
/// Flow (recording in the main app, keyboard stays in focus):
/// 1. Keyboard opens main app via URL scheme: voxvault://record?model=X&lang=Y&requestId=Z
/// 2. Main app starts recording, writes status.json (phase=recording)
/// 3. User switches back to their app — keyboard shows "Recording…" with a Stop button
/// 4. Main app continues recording in background (UIBackgroundModes: audio)
/// 5. User taps Stop in keyboard → writes command.json (action=stop), posts Darwin notification
/// 6. Main app stops recording, transcribes, writes response.json
/// 7. Keyboard reads response, inserts text
public enum TranscriptionIPC {

    // MARK: - Darwin notification names

    /// Keyboard → App: "I have a new transcription request"
    public static let requestNotificationName =
        "group.bontecou.VoxVault.transcribeRequest" as CFString

    /// App → Keyboard: "The response is ready"
    public static let responseNotificationName =
        "group.bontecou.VoxVault.transcribeResponse" as CFString

    /// Keyboard → App: "Stop recording now"
    public static let stopCommandNotificationName =
        "group.bontecou.VoxVault.stopRecording" as CFString

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

    public static func ensureDirectory() {
        guard let dir = ipcDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Write / Read

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

    public enum IPCError: Error {
        case noContainer
    }
}
