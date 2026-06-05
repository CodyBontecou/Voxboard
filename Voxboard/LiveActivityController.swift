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
/// - `update(isSegmentActive:startedAt:)` whenever a segment starts or stops.
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
    #endif

    private init() {}

    func startIfNeeded() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        guard AppConstants.liveActivityMonitorEnabled else {
            if activity != nil { end() }
            osLog.notice("Live Activity monitor disabled in Voxboard settings — skipping start")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            osLog.notice("Live Activities disabled — skipping start")
            return
        }
        if activity != nil { return }

        let state = VoxboardLiveActivityState.idle
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

    func update(isSegmentActive: Bool, startedAt: TimeInterval?) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        guard AppConstants.liveActivityMonitorEnabled else {
            end()
            return
        }
        guard let activity else { return }
        let state = VoxboardLiveActivityState(
            isSegmentActive: isSegmentActive,
            segmentStartedAt: isSegmentActive ? startedAt : nil
        )
        Task {
            if #available(iOS 16.2, *) {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            } else {
                await activity.update(using: state)
            }
        }
        #endif
    }

    func end() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity else { return }
        Task {
            if #available(iOS 16.2, *) {
                await activity.end(
                    ActivityContent(state: .idle, staleDate: nil),
                    dismissalPolicy: .immediate
                )
            } else {
                await activity.end(using: .idle, dismissalPolicy: .immediate)
            }
        }
        self.activity = nil
        osLog.notice("Ended Live Activity")
        #endif
    }
}
