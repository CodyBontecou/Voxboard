import Foundation
import os.log
import VoxboardShared

#if canImport(ActivityKit)
import ActivityKit
#endif

private let osLog = Logger(subsystem: "bontecou.Voxboard", category: "LiveActivity")

/// Why a Live Activity is currently presented. Each reason is guarded by its
/// own Vox.md setting so the always-on monitor card and the card shown while
/// an App Intent toggle recording (Shortcuts, Apple Pencil squeeze, Action
/// Button) is running can be enabled independently.
enum LiveActivityPresentationReason {
    /// The always-on listening monitor card with Record/Stop controls.
    case monitor
    /// The card shown while a recording is toggled in place without opening
    /// the app, so the user sees elapsed time and can stop from the Lock
    /// Screen or Dynamic Island.
    case shortcutRecording

    var isAllowed: Bool {
        switch self {
        case .monitor:
            return AppConstants.liveActivityMonitorEnabled
        case .shortcutRecording:
            return AppConstants.shortcutRecordingLiveActivityEnabled
        }
    }
}

/// Owns the lock-screen / Dynamic Island Live Activity for Voxboard.
///
/// Lifecycle:
/// - `startIfNeeded()` when the always-on recorder becomes active.
/// - `update(isSegmentActive:isTranscribing:startedAt:)` whenever a segment starts, stops, or begins processing.
/// - `end()` when the recorder stops listening entirely.
///
/// All calls are no-ops on pre-iOS 16.1 devices or when Live Activities are
/// disabled in Settings.
@MainActor
final class LiveActivityController {

    static let shared = LiveActivityController()

    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    private var activity: Activity<VoxboardActivityAttributes>? {
        get { _activity as? Activity<VoxboardActivityAttributes> }
        set { _activity = newValue }
    }
    private var _activity: Any?
    private var endingActivityIDs: Set<String> = []
    private var activityMutationTask: Task<Void, Never>?
    private var desiredState = VoxboardLiveActivityState.idle
    private var shouldStartAfterPendingEnd = false
    /// Last failure reason from `startIfNeeded`, for diagnostics.
    private(set) var lastStartFailureDescription: String?
    /// Why the currently tracked activity was started. Preserved when an
    /// existing activity is reused so a monitor card is never re-gated by the
    /// shortcut-recording setting or vice versa.
    private var presentationReason: LiveActivityPresentationReason = .monitor
    #endif

    private init() {}

    /// Starts (or reuses) the presentation. Returns true when an activity is
    /// tracked after the call — either reused (e.g. the listening monitor) or
    /// newly requested. Callers that must guarantee a card — audio recording
    /// intents fatally assert when their session is active without one — use
    /// the result to decide whether background recording may begin.
    @discardableResult
    func startIfNeeded(reason newReason: LiveActivityPresentationReason = .monitor) -> Bool {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return false }

        // An existing presentation can always be reused regardless of the
        // incoming reason's setting.
        let existingActivities = Activity<VoxboardActivityAttributes>.activities
            .filter { !endingActivityIDs.contains($0.id) }
        let trackedID = activity?.id
        let primaryActivity = trackedID.flatMap { id in
            existingActivities.first(where: { $0.id == id })
        } ?? existingActivities.first

        if let primaryActivity {
            activity = primaryActivity

            let duplicates = existingActivities.filter { $0.id != primaryActivity.id }
            endActivities(duplicates)
            enqueueUpdate(primaryActivity, state: desiredState)
            osLog.notice("Reusing Live Activity; dismissed \(duplicates.count) duplicate(s)")
            return true
        }

        guard newReason.isAllowed else {
            if presentationReason == newReason {
                end()
            }
            lastStartFailureDescription = "setting disabled: \(newReason)"
            osLog.notice("Live Activity for \(String(describing: newReason), privacy: .public) disabled in Voxboard settings — skipping start")
            return false
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            end()
            lastStartFailureDescription = "live activities disabled (system or app setting)"
            osLog.notice("Live Activities disabled — skipping start")
            return false
        }

        // ActivityKit ends asynchronously. Wait before requesting the replacement
        // so a launch with several orphaned cards cannot exceed the activity limit.
        if !endingActivityIDs.isEmpty {
            if !shouldStartAfterPendingEnd {
                shouldStartAfterPendingEnd = true
                enqueueActivityMutation { [weak self] in
                    guard let self, self.shouldStartAfterPendingEnd else { return }
                    self.shouldStartAfterPendingEnd = false
                    _ = self.startIfNeeded(reason: newReason)
                }
            }
            lastStartFailureDescription = "pending end of previous activity"
            return false
        }
        shouldStartAfterPendingEnd = false

        let state = desiredState
        do {
            // Background-started presentations (shortcut recordings) must use
            // the transient style — requesting a standard activity from the
            // background fails with ActivityAuthorizationError.visibility.
            // Transient cards present in the Dynamic Island without the
            // foreground visibility requirement and auto-expire.
            let style: ActivityStyle = newReason == .shortcutRecording ? .transient : .standard
            if #available(iOS 18.0, *) {
                let content = ActivityContent(state: state, staleDate: nil)
                activity = try Activity.request(
                    attributes: VoxboardActivityAttributes(),
                    content: content,
                    pushType: nil,
                    style: style
                )
            } else if #available(iOS 16.2, *) {
                let content = ActivityContent(state: state, staleDate: nil)
                activity = try Activity.request(
                    attributes: VoxboardActivityAttributes(),
                    content: content,
                    pushType: nil
                )
            } else {
                activity = try Activity.request(
                    attributes: VoxboardActivityAttributes(),
                    contentState: state,
                    pushType: nil
                )
            }
            presentationReason = newReason
            lastStartFailureDescription = nil
            osLog.notice("Started Live Activity")
            return true
        } catch {
            lastStartFailureDescription = String(describing: error)
            osLog.error("Failed to start Live Activity: \(String(describing: error))")
            return false
        }
        #else
        return false
        #endif
    }

    func update(
        isSegmentActive: Bool,
        isTranscribing: Bool = false,
        startedAt: TimeInterval?,
        requestId: String? = nil,
        transcriptionProgress: Double? = nil
    ) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        let state = VoxboardLiveActivityState(
            isSegmentActive: isSegmentActive,
            isTranscribing: isTranscribing,
            segmentStartedAt: isSegmentActive ? startedAt : nil,
            segmentRequestId: isSegmentActive ? requestId : nil,
            transcriptionProgress: isTranscribing ? transcriptionProgress : nil
        )
        desiredState = state
        guard presentationReason.isAllowed else {
            end()
            return
        }
        guard let activity else { return }
        enqueueUpdate(activity, state: state)
        #endif
    }

    /// End every activity owned by Vox.md, not only the in-memory reference.
    /// ActivityKit can preserve activities across process termination, so ending
    /// the complete collection prevents stacked Lock Screen/Dynamic Island cards.
    func end() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }

        var activities = Activity<VoxboardActivityAttributes>.activities
        if let tracked = activity,
           !activities.contains(where: { $0.id == tracked.id }) {
            activities.append(tracked)
        }
        activity = nil
        desiredState = .idle
        shouldStartAfterPendingEnd = false
        presentationReason = .monitor
        endActivities(activities)
        if !activities.isEmpty {
            osLog.notice("Ending \(activities.count) Live Activity instance(s)")
        }
        #endif
    }

    /// End the Live Activity only when it is currently presented for a
    /// shortcut-triggered toggle recording. Monitor presentations — owned by
    /// the always-on listening setting — are left untouched.
    func endShortcutRecordingActivityIfNeeded() {
        guard presentationReason == .shortcutRecording else { return }
        end()
    }

    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    private func enqueueUpdate(
        _ activity: Activity<VoxboardActivityAttributes>,
        state: VoxboardLiveActivityState
    ) {
        enqueueActivityMutation {
            if #available(iOS 16.2, *) {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            } else {
                await activity.update(using: state)
            }
        }
    }

    @available(iOS 16.1, *)
    private func endActivities(_ activities: [Activity<VoxboardActivityAttributes>]) {
        let candidates = activities.filter { !endingActivityIDs.contains($0.id) }
        guard !candidates.isEmpty else { return }

        let ids = Set(candidates.map(\.id))
        endingActivityIDs.formUnion(ids)
        enqueueActivityMutation { [weak self] in
            for activity in candidates {
                if #available(iOS 16.2, *) {
                    await activity.end(
                        ActivityContent(state: .idle, staleDate: nil),
                        dismissalPolicy: .immediate
                    )
                } else {
                    await activity.end(using: .idle, dismissalPolicy: .immediate)
                }
            }
            self?.endingActivityIDs.subtract(ids)
        }
    }

    @available(iOS 16.1, *)
    private func enqueueActivityMutation(
        _ mutation: @escaping @MainActor () async -> Void
    ) {
        let previousTask = activityMutationTask
        activityMutationTask = Task { @MainActor in
            await previousTask?.value
            await mutation()
        }
    }
    #endif
}
