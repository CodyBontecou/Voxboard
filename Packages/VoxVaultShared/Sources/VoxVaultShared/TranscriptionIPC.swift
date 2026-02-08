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

// MARK: - IPC Helpers

/// File-based IPC between the keyboard extension and the main app.
///
/// Flow:
/// 1. Keyboard records audio → saves WAV to App Group
/// 2. Keyboard writes `request.json`, posts Darwin notification
/// 3. Main app receives notification, transcribes, writes `response.json`
/// 4. Main app posts Darwin notification back
/// 5. Keyboard reads response, inserts text
public enum TranscriptionIPC {

    // MARK: - Darwin notification names

    /// Keyboard → App: "I have a new transcription request"
    public static let requestNotificationName =
        "group.bontecou.VoxVault.transcribeRequest" as CFString

    /// App → Keyboard: "The response is ready"
    public static let responseNotificationName =
        "group.bontecou.VoxVault.transcribeResponse" as CFString

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

    public static func ensureDirectory() {
        guard let dir = ipcDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Write / Read

    public static func writeRequest(_ request: TranscriptionRequest) throws {
        ensureDirectory()
        // Remove stale response so the keyboard doesn't pick up old data
        if let url = responseURL { try? FileManager.default.removeItem(at: url) }

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

    public static func clearRequest() {
        guard let url = requestURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public static func clearResponse() {
        guard let url = responseURL else { return }
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

    public enum IPCError: Error {
        case noContainer
    }
}
