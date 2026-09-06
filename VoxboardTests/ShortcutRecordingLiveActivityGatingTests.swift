import VoxboardShared
import XCTest
@testable import Voxboard

final class ShortcutRecordingLiveActivityGatingTests: XCTestCase {

    private func restore(
        _ defaults: UserDefaults,
        _ original: Any?,
        forKey key: String
    ) {
        if let original {
            defaults.set(original, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// The shortcut-recording Live Activity setting must gate only its own
    /// presentation reason; the always-on monitor card stays independently
    /// controlled by its legacy setting.
    func testShortcutRecordingReasonGatesIndependentlyOfMonitor() throws {
        let defaults = try XCTUnwrap(AppConstants.sharedDefaults)
        let originalMonitor = defaults.object(forKey: AppConstants.liveActivityMonitorEnabledKey)
        let originalShortcut = defaults.object(forKey: AppConstants.shortcutRecordingLiveActivityEnabledKey)
        defer {
            restore(defaults, originalMonitor, forKey: AppConstants.liveActivityMonitorEnabledKey)
            restore(defaults, originalShortcut, forKey: AppConstants.shortcutRecordingLiveActivityEnabledKey)
        }

        defaults.set(true, forKey: AppConstants.liveActivityMonitorEnabledKey)
        defaults.set(false, forKey: AppConstants.shortcutRecordingLiveActivityEnabledKey)
        XCTAssertTrue(LiveActivityPresentationReason.monitor.isAllowed)
        XCTAssertFalse(LiveActivityPresentationReason.shortcutRecording.isAllowed)

        defaults.set(false, forKey: AppConstants.liveActivityMonitorEnabledKey)
        defaults.set(true, forKey: AppConstants.shortcutRecordingLiveActivityEnabledKey)
        XCTAssertFalse(LiveActivityPresentationReason.monitor.isAllowed)
        XCTAssertTrue(LiveActivityPresentationReason.shortcutRecording.isAllowed)
    }

    /// The shortcut-recording Live Activity is on by default so squeeze-to-
    /// record gets its status card without configuration.
    func testShortcutRecordingLiveActivityDefaultsOn() {
        XCTAssertTrue(AppConstants.shortcutRecordingLiveActivityEnabled)
    }
}
