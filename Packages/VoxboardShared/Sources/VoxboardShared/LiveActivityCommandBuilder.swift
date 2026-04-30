import Foundation

/// Builds and enqueues IPC commands originating from the Live Activity.
///
/// The Live Activity's Start/Stop buttons trigger App Intents that run in
/// the main app's process. Those intents call into this builder, which
/// writes a `RecordingCommand` file and fires the Darwin notification the
/// `PersistentRecorder` already observes — reusing the exact path used by
/// the keyboard extension.
public enum LiveActivityCommandBuilder {

    public static func buildStartCommand(
        requestId: String = UUID().uuidString,
        modelId: String? = nil,
        language: String? = nil
    ) -> RecordingCommand {
        RecordingCommand(
            requestId: requestId,
            action: .startSegment,
            modelId: modelId,
            language: language
        )
    }

    public static func buildStopCommand(requestId: String) -> RecordingCommand {
        RecordingCommand(requestId: requestId, action: .stopSegment)
    }

    /// Write the command to `commandURL` and call `notify()`.
    ///
    /// Defaults use the shared `TranscriptionIPC` locations. Tests inject
    /// a temp URL + a closure to avoid touching the real IPC directory.
    public static func enqueue(
        _ command: RecordingCommand,
        commandURL: URL? = TranscriptionIPC.commandURL,
        notify: () -> Void = { TranscriptionIPC.postCommandNotification() }
    ) {
        guard let url = commandURL,
              let data = try? JSONEncoder().encode(command) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        notify()
    }
}
