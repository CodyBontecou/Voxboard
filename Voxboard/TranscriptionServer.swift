import Foundation
import UIKit
import VoxboardShared

/// Runs in the main app process. Listens for transcription requests from the
/// keyboard extension via Darwin notifications, processes them with whisper.cpp
/// (full memory budget — no extension limits), and writes responses back.
final class TranscriptionServer {

    private var isObserving = false
    private var isProcessing = false
    private let transcriptionService: OnDeviceTranscriptionService

    init(transcriptionService: OnDeviceTranscriptionService) {
        self.transcriptionService = transcriptionService
    }

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
        guard let audioURL = AppConstants.recordingsDirectoryURL?
                .appendingPathComponent(request.audioFileName),
              FileManager.default.fileExists(atPath: audioURL.path) else {
            log("❌ Audio file not found: \(request.audioFileName)")
            writeResponse(.init(requestId: request.id, error: String(localized: "Audio not found")))
            return
        }

        do {
            let result = try await transcriptionService.transcribeResult(
                audioURL: audioURL,
                modelID: request.modelId,
                fallbackModelID: AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedFallbackModelKey),
                language: request.language
            )
            log("Result from \(result.backendName): \(result.text.count) chars")
            writeResponse(.init(requestId: request.id, text: result.text))
        } catch {
            log("❌ Transcription failed: \(error.localizedDescription)")
            writeResponse(.init(requestId: request.id, error: error.localizedDescription))
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
