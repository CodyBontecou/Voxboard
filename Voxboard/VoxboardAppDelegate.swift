import UIKit

/// Activates WatchConnectivity at the earliest iOS launch hook.
///
/// A queued Watch file can launch the process without presenting a SwiftUI
/// scene. Registering the session here lets iOS dispatch that file while the
/// app remains in the background instead of waiting for `WindowGroup` to appear.
final class VoxboardAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        WatchRecordingController.shared.activateForBackgroundDelivery()
        return true
    }
}
