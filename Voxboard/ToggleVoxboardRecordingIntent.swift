import AppIntents
import Foundation
import VoxboardShared

// MARK: - Toggle Recording Intent

/// Toggles a Vox.md recording in place — without switching apps.
///
/// Built for hardware triggers (Apple Pencil squeeze, Action Button) and any
/// Shortcut: the first run starts a one-shot recording segment while the user
/// stays in their current app (waking Vox.md in the background when needed);
/// the next run stops it.
///
/// iOS 26+ only: conforming to `AudioRecordingIntent` is what allows the app
/// to activate the microphone from a background launch. Without that blessing
/// `AVAudioEngine.start()` fails when the system wakes the app for the intent,
/// leaving a stale "Microphone error" and no recording. On older systems the
/// legacy open-and-record shortcut remains the supported path; the action is
/// availability-gated out of the Shortcuts library below iOS 26.
///
/// When in-place recording still cannot start — free-tier limit reached, mic
/// permission missing, or the engine failing — the intent chains to the
/// open-and-record intent so the user still gets their recording.
@available(iOS 26.0, *)
struct ToggleVoxboardRecordingIntent: AudioRecordingIntent, LiveActivityStartingIntent {
    static let title: LocalizedStringResource = "Toggle Recording"
    static let description = IntentDescription("Starts or stops a Vox.md recording without leaving the current app. Run it again to stop.")
    static var openAppWhenRun: Bool = false

    /// iOS 26 requires an AudioRecordingIntent to present a Live Activity
    /// whenever its session is active. `LiveActivityStartingIntent` authorizes
    /// starting that activity from the background — without it the request is
    /// rejected with `ActivityAuthorizationError.visibility`.
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Preset", description: "The Capture Preset to use when this intent starts a recording.")
    var vox: VoxEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle recording with \(\.$vox)")
    }

    init() {}

    init(vox: VoxEntity?) {
        self.vox = vox
    }

    @MainActor
    func perform() async throws -> some IntentResult {

        guard AppConstants.lockScreenQuickRecordEnabled else {
            return .result()
        }

        // App Intents perform inside the app process, so the scene's recorder
        // is reachable directly. If it is missing, fall back to the
        // open-and-record flow instead of failing silently.
        guard let recorder = PersistentRecorder.active else {
            return .result(opensIntent: OpenVoxboardRecordIntent(vox: vox))
        }

        // A segment is already recording — the same trigger that started it
        // now stops it, and the segment transcribes and delivers as usual.
        if recorder.isSegmentActive {
            recorder.stopInAppSegment()
            // Re-present the card if the user dismissed it while recording;
            // the system requires an active Live Activity whenever the audio
            // session is active. No-op when a card already exists.
            LiveActivityController.shared.startIfNeeded(reason: .shortcutRecording)
            return .result()
        }

        // Start a one-shot segment in place. When the app was not already
        // listening this arms the microphone only for this segment and tears
        // it back down after delivery. The audio session activates inside —
        // background Live Activity starts are authorized by this intent's
        // conformance to `LiveActivityStartingIntent`, so the card is requested
        // immediately after the session is live.
        let started = recorder.startOneShotInAppSegment(
            flowId: Self.resolvedFlowId(for: vox),
            origin: .quickRecord
        )

        if started {
            if LiveActivityController.shared.startIfNeeded(reason: .shortcutRecording) {
                // The segment start pushed its state through the controller, so
                // the card flips straight into "Recording" with a working Stop
                // button.
                return .result()
            }
            // iOS 26 fatally asserts when an audio recording intent ends with
            // an active session but no Live Activity. The card could not be
            // presented — tear the session down completely before returning
            // and fall back to opening the app.
            recorder.stopListening()
            LiveActivityController.shared.endShortcutRecordingActivityIfNeeded()
            return .result(opensIntent: OpenVoxboardRecordIntent(vox: vox))
        }


        // In-place start failed. Release any shortcut-presented card and fall
        // back to the legacy behavior: open the app and record there.
        LiveActivityController.shared.endShortcutRecordingActivityIfNeeded()
        return .result(opensIntent: OpenVoxboardRecordIntent(vox: vox))
    }

    private static func resolvedFlowId(for vox: VoxEntity?) -> String? {
        guard let id = vox?.id,
              let flow = CapturePresetStore.flow(id: id),
              flow.isEnabled else {
            return nil
        }
        return flow.id
    }
}
