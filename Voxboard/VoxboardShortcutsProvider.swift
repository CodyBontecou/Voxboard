import AppIntents

@available(iOS 18.0, *)
struct VoxboardShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenVoxboardRecordIntent(),
            phrases: [
                "Record with \(.applicationName)",
                "Record \(\.$vox) with \(.applicationName)",
                "Start \(\.$vox) in \(.applicationName)"
            ],
            shortTitle: "Record with Vox",
            systemImageName: "mic.fill"
        )
    }
}
