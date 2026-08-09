import Foundation
import os.log
import VoxboardShared

#if canImport(ActivityKit)
import ActivityKit
#endif

private let osLog = Logger(subsystem: "bontecou.Voxboard", category: "LiveActivity")

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
    #endif

    private init() {}

    func startIfNeeded() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        guard AppConstants.liveActivityMonitorEnabled else {
            end()
            osLog.notice("Live Activity monitor disabled in Voxboard settings — skipping start")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            end()
            osLog.notice("Live Activities disabled — skipping start")
            return
        }

        // ActivityKit ends asynchronously. Wait before requesting the replacement
        // so a launch with several orphaned cards cannot exceed the activity limit.
        if !endingActivityIDs.isEmpty {
            if !shouldStartAfterPendingEnd {
                shouldStartAfterPendingEnd = true
                enqueueActivityMutation { [weak self] in
                    guard let self, self.shouldStartAfterPendingEnd else { return }
                    self.shouldStartAfterPendingEnd = false
                    self.startIfNeeded()
                }
            }
            return
        }
        shouldStartAfterPendingEnd = false

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
            return
        }

        let state = desiredState
        do {
            if #available(iOS 16.2, *) {
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
            osLog.notice("Started Live Activity")
        } catch {
            osLog.error("Failed to start Live Activity: \(String(describing: error))")
        }
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
        guard AppConstants.liveActivityMonitorEnabled else {
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
        endActivities(activities)
        if !activities.isEmpty {
            osLog.notice("Ending \(activities.count) Live Activity instance(s)")
        }
        #endif
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
