import SwiftUI
import UIKit
import Notelet
import VoxboardShared

// MARK: - In-app release notes

enum VoxboardReleaseNotes {
    private static var watchFeatureVideoURL: URL {
        Bundle.main.url(forResource: "voxboard-watch-notelet-square-mobile", withExtension: "mp4")
            ?? Bundle.main.bundleURL.appendingPathComponent("voxboard-watch-notelet-square-mobile.mp4")
    }

    static let notes: [NoteletVersionNotes] = [
        .init(
            version: "2.0.3",
            items: [
                .list(
                    title: "What’s new in Vox.md",
                    rows: [
                        .init(
                            symbolSystemName: "pause.fill",
                            title: "Pause Watch recordings",
                            description: "Pause a recording on Apple Watch when you need a break, then resume in the same voice note without creating separate files."
                        ),
                        .init(
                            symbolSystemName: "timer",
                            title: "Accurate recording time",
                            description: "The Watch timer freezes while paused and continues when you resume, with the paused state also reflected in Watch widgets."
                        )
                    ]
                )
            ]
        ),
        .init(
            version: "2.0.2",
            items: [
                .list(
                    title: "What’s new in Vox.md",
                    rows: [
                        .init(
                            symbolSystemName: "chart.bar.xaxis",
                            title: "Private Activity Stats",
                            description: "Open Stats from Settings to see lifetime totals for recordings, captures, recorded time, and attachments, all stored on your device."
                        ),
                        .init(
                            symbolSystemName: "calendar",
                            title: "See your recent activity",
                            description: "Review a seven-day activity chart and a breakdown of captures from the app, keyboard, Share Sheet, widgets, Shortcuts, and Apple Watch."
                        ),
                        .init(
                            symbolSystemName: "applewatch",
                            title: "Clearer Watch upgrades",
                            description: "Apple Watch recordings now explain when free transcription time has been used and provide a direct path to unlock unlimited transcription."
                        ),
                        .init(
                            symbolSystemName: "lock.shield",
                            title: "Private by design",
                            description: "Stats update as you capture while keeping captured content, filenames, and destinations out of analytics."
                        )
                    ]
                )
            ]
        ),
        .init(
            version: "1.9.5",
            items: [
                .media(
                    kind: .video,
                    url: watchFeatureVideoURL,
                    title: "Vox.md now records from Apple Watch",
                    description: "See the new Watch flow: record from your wrist, save locally, then sync back to the iPhone queue when you reconnect."
                ),
                .list(
                    title: "What’s new in Vox.md",
                    rows: [
                        .init(
                            symbolSystemName: "applewatch",
                            title: "Record on Apple Watch",
                            description: "Start and stop voice notes directly from Vox.md on Apple Watch without reaching for your iPhone."
                        ),
                        .init(
                            symbolSystemName: "tray.full",
                            title: "Saved Watch queue",
                            description: "Watch recordings stay saved locally and appear in your iPhone queue when your devices reconnect."
                        ),
                        .init(
                            symbolSystemName: "rectangle.grid.1x2",
                            title: "Clearer Watch status",
                            description: "The Watch recorder now shows bold Ready, Recording, Syncing, Queued, and Sent states so you always know what is happening."
                        ),
                        .init(
                            symbolSystemName: "app.badge",
                            title: "Faster Watch access",
                            description: "Add the Vox.md Watch face shortcut for a quick path into recording from supported Apple Watch faces."
                        )
                    ]
                )
            ]
        ),
        .init(
            version: "1.9.4",
            items: [
                .list(
                    title: "What’s new in Vox.md",
                    rows: [
                        .init(
                            symbolSystemName: "applewatch",
                            title: "Record on Apple Watch",
                            description: "Capture voice notes from your wrist with the new Vox.md Watch app. Start recording, stop when you’re done, and keep moving without reaching for your iPhone."
                        ),
                        .init(
                            symbolSystemName: "arrow.triangle.2.circlepath",
                            title: "Watch recordings sync back",
                            description: "Recordings are saved on Apple Watch and sent to your iPhone queue when the devices reconnect, so you can process them whenever you’re ready."
                        ),
                        .init(
                            symbolSystemName: "tray.full",
                            title: "New Watch Queue on iPhone",
                            description: "Home now shows incoming Watch audio with recording time, a Process action, and a discard button before Vox.md transcribes it."
                        ),
                        .init(
                            symbolSystemName: "app.badge",
                            title: "Watch face shortcut",
                            description: "Add the Vox.md recording widget to supported Apple Watch faces for faster access to the Watch recorder."
                        ),
                        .init(
                            symbolSystemName: "iphone.radiowaves.left.and.right",
                            title: "Clearer recording status",
                            description: "Apple Watch and iPhone now share listening, recording, transcribing, Quick Record, and unlock-limit messages so you always know what needs attention."
                        )
                    ]
                )
            ]
        ),
        .init(
            version: "1.9",
            items: [
                .list(
                    title: "What’s new in Vox.md",
                    rows: [
                        .init(
                            symbolSystemName: "keyboard",
                            title: "Global recording keybind on Mac",
                            description: "The Mac app can now listen for your custom shortcut and use it to start recording from anywhere, then stop and transcribe with the same shortcut."
                        ),
                        .init(
                            symbolSystemName: "square.grid.2x2",
                            title: "Friendlier Preset icons on Mac",
                            description: "Custom Capture Presets on macOS now use a searchable icon picker, so you can choose a clear symbol without memorizing SF Symbol names."
                        ),
                        .init(
                            symbolSystemName: "lock.fill",
                            title: "Lock Screen controls you can tune",
                            description: "Settings now lets you turn the Live Activity/Dynamic Island monitor and Lock Screen Quick Record button on or off, with disabled widgets showing an off state instead of starting a recording."
                        ),
                        .init(
                            symbolSystemName: "mic.badge.plus",
                            title: "Presets for every workflow",
                            description: "Create named Capture Presets for journal entries, meeting notes, tasks, or anything custom. Pick one before recording and Vox.md applies its formatting, cleanup, frontmatter, destination, and audio rules."
                        ),
                        .init(
                            symbolSystemName: "folder.badge.gearshape",
                            title: "Route notes by Preset",
                            description: "Each Capture Preset can save notes to its own destination with its own file format, filename template, Obsidian/YAML options, and Markdown template."
                        ),
                        .init(
                            symbolSystemName: "waveform.badge.plus",
                            title: "Audio goes where you want it",
                            description: "Each Capture Preset controls whether saved audio stays beside the note, moves into an attachments/audio folder, or stays off entirely, with irrelevant folder options hidden automatically."
                        ),
                        .init(
                            symbolSystemName: "arrow.triangle.branch",
                            title: "Safer export routing",
                            description: "Existing file export settings migrate into your default Capture Preset, and smart folder routing respects explicit Preset destinations."
                        ),
                        .init(
                            symbolSystemName: "sparkles.rectangle.stack",
                            title: "Clearer post-processing",
                            description: "The Capture Preset editor explains Keep Original, Clean Prose, Todo Checklist, Meeting Notes, and Custom Instruction modes."
                        )
                    ]
                )
            ]
        )
    ]

    static var presentedVersion: NoteletPresentedVersion? {
        if ProcessInfo.processInfo.arguments.contains("--disable-release-notes") {
            return nil
        }

        return .current
    }

    private static let actionButtonTint = Color(uiColor: UIColor { traits in
        // Notelet renders the call-to-action label with `.primary`, so the
        // prominent button tint must stay dark in dark mode (white label) and
        // light in light mode (black label) to preserve readable contrast.
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 0.36, alpha: 1.0)
        }

        return UIColor(white: 0.58, alpha: 1.0)
    })

    static let configuration = NoteletConfiguration(
        nextButtonLabel: "Next",
        doneButtonLabel: "Done",
        accentColor: actionButtonTint
    )
}

extension View {
    func voxboardReleaseNotesSheet() -> some View {
        noteletSheet(
            notes: VoxboardReleaseNotes.notes,
            version: VoxboardReleaseNotes.presentedVersion,
            configuration: VoxboardReleaseNotes.configuration,
            userDefaults: AppConstants.sharedDefaults ?? .standard
        )
    }
}
