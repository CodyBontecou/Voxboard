import Foundation
import UIKit
import VoxVaultShared

/// Runs in the main app process. Listens for transcription requests from the
/// keyboard extension via Darwin notifications, processes them with whisper.cpp
/// (full memory budget — no extension limits), and writes responses back.
final class TranscriptionServer {

    private var isObserving = false
    private var isProcessing = false

    init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isObserving else { return }
        isObserving = true
        TranscriptionIPC.ensureDirectory()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let server = Unmanaged<TranscriptionServer>
                    .fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { server.onRequestReceived() }
            },
            TranscriptionIPC.requestNotificationName,
            nil,
            .deliverImmediately
        )

        // Also check for any pending request that arrived while the app wasn't running
        onRequestReceived()
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center, observer,
            CFNotificationName(TranscriptionIPC.requestNotificationName),
            nil
        )
    }

    /// Call when the app returns to foreground to pick up any missed requests.
    func checkForPendingRequest() {
        onRequestReceived()
    }

    // MARK: - Processing

    private func onRequestReceived() {
        guard !isProcessing else { return }

        guard let request = TranscriptionIPC.readRequest() else { return }

        // Ignore stale requests (> 60 seconds old)
        let age = Date().timeIntervalSince1970 - request.createdAt
        guard age < 60 else {
            log("Ignoring stale request (age: \(Int(age))s)")
            TranscriptionIPC.clearRequest()
            return
        }

        isProcessing = true

        // Request background execution time so we can finish even if the user
        // switches away from the app.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        log("Picked up request \(request.id) — model: \(request.modelId), lang: \(request.language)")

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processRequest(request)

            await MainActor.run {
                self?.isProcessing = false
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                }
            }
        }
    }

    private func processRequest(_ request: TranscriptionRequest) async {
        // Resolve model
        guard let model = WhisperModelInfo.availableModels.first(where: { $0.id == request.modelId }),
              let modelPath = model.localURL?.path,
              FileManager.default.fileExists(atPath: modelPath) else {
            log("❌ Model not found: \(request.modelId)")
            writeResponse(.init(requestId: request.id, error: "Model not found"))
            return
        }

        // Resolve audio file
        guard let audioURL = AppConstants.recordingsDirectoryURL?
                .appendingPathComponent(request.audioFileName),
              FileManager.default.fileExists(atPath: audioURL.path) else {
            log("❌ Audio file not found: \(request.audioFileName)")
            writeResponse(.init(requestId: request.id, error: "Audio not found"))
            return
        }

        // Load model — full app memory budget, GPU enabled
        log("Loading model: \(model.name)…")
        guard let ctx = WhisperContext(modelPath: modelPath) else {
            log("❌ Model load failed")
            writeResponse(.init(requestId: request.id, error: "Model load failed"))
            return
        }

        log("Transcribing…")
        let text = ctx.transcribe(audioURL: audioURL, language: request.language)
        log("Result: \(text?.count ?? 0) chars")

        if let text, !text.isEmpty {
            writeResponse(.init(requestId: request.id, text: text))
        } else {
            writeResponse(.init(requestId: request.id, error: "No speech detected"))
        }
    }

    private func writeResponse(_ response: TranscriptionResponse) {
        do {
            try TranscriptionIPC.writeResponse(response)
            TranscriptionIPC.clearRequest()
            TranscriptionIPC.postResponseNotification()
            log("✅ Response written")
        } catch {
            log("❌ Failed to write response: \(error)")
        }
    }

    private func log(_ msg: String) {
        KeyboardDebugLog.shared.log("[Server] \(msg)")
    }

    deinit { stop() }
}
