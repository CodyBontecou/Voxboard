import AppIntents

@available(iOS 17.0, *)
struct VoxboardShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenVoxboardRecordIntent(),
            phrases: [
                "Record with \(.applicationName)",
                "Record \(\.$vox) with \(.applicationName)",
                "Start \(\.$vox) in \(.applicationName)"
            ],
            shortTitle: "Record with Preset",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: OpenQuickCaptureIntent(),
            phrases: [
                "Quick capture with \(.applicationName)",
                "Open capture in \(.applicationName)"
            ],
            shortTitle: "Quick Capture",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenCaptureVoiceIntent(),
            phrases: [
                "Record a capture with \(.applicationName)",
                "Voice capture in \(.applicationName)"
            ],
            shortTitle: "Capture Voice",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: OpenCaptureScreenshotIntent(),
            phrases: [
                "Capture a screenshot with \(.applicationName)",
                "Add a screenshot in \(.applicationName)"
            ],
            shortTitle: "Capture Screenshot",
            systemImageName: "rectangle.inset.filled.and.person.filled"
        )
        AppShortcut(
            intent: OpenCaptureScanIntent(),
            phrases: [
                "Scan a document with \(.applicationName)",
                "Capture a scan with \(.applicationName)"
            ],
            shortTitle: "Capture Scan",
            systemImageName: "doc.viewfinder"
        )
        AppShortcut(
            intent: CaptureTextIntent(),
            phrases: [
                "Capture text with \(.applicationName)",
                "Send text to \(.applicationName)"
            ],
            shortTitle: "Capture Text",
            systemImageName: "text.badge.plus"
        )
        AppShortcut(
            intent: CaptureURLIntent(),
            phrases: [
                "Capture a link with \(.applicationName)",
                "Save a link to \(.applicationName)"
            ],
            shortTitle: "Capture Link",
            systemImageName: "link.badge.plus"
        )
        AppShortcut(
            intent: CaptureFileIntent(),
            phrases: [
                "Capture a file with \(.applicationName)",
                "Save a file to \(.applicationName)"
            ],
            shortTitle: "Capture File",
            systemImageName: "doc.badge.plus"
        )
    }
}
