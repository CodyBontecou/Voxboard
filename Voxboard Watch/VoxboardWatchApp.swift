import SwiftUI

@main
struct VoxboardWatchApp: App {
    @StateObject private var bridge = WatchPhoneBridge.shared
    @StateObject private var localRecorder = WatchLocalRecorder()

    var body: some Scene {
        WindowGroup {
            WatchRecorderView()
                .environmentObject(bridge)
                .environmentObject(localRecorder)
                .onOpenURL { url in
                    Task { await localRecorder.handleDeepLink(url, using: bridge) }
                }
        }
    }
}
