import BackgroundTasks
import VoxboardShared

/// Drains the shared capture inbox from a `BGProcessingTask` so queued
/// captures retry while the app is backgrounded (#11), not only when the
/// user foregrounds the app. Talks to `CaptureInboxDeliveryService` directly:
/// background delivery needs no UI state; counts and decisions refresh on
/// the next foreground drain.
@MainActor
enum CaptureInboxBackgroundDrain {
    static let taskIdentifier = "com.bontecou.Voxboard.captureInboxDrain"

    /// Must run before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let drain = Task { @MainActor in
                let success = await runDrain()
                processingTask.setTaskCompleted(success: success)
            }
            processingTask.expirationHandler = {
                drain.cancel()
            }
        }
    }

    /// Requests a drain pass no sooner than 15 minutes from now. Re-submitted
    /// each time the app enters the background; duplicate pending requests
    /// replace the previous schedule.
    static func schedule(after seconds: TimeInterval = 15 * 60) {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator and some states reject submission; the next
            // foreground drain still covers delivery.
            KeyboardDebugLog.shared.log("capture inbox drain schedule failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    static func runDrain() async -> Bool {
        guard let captureRootURL = AppConstants.captureDirectoryURL else {
            return false
        }
        let result = await CaptureInboxDeliveryService.drain(captureRootURL: captureRootURL)
        return result.setupError == nil
    }
}
