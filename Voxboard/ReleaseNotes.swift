import SwiftUI
import UIKit
import Notelet
import VoxboardShared

// MARK: - In-app release notes

enum VoxboardReleaseNotes {
    private struct VersionNotes {
        let version: String
        let items: [NoteletVersionNoteItem]
    }

    private static var watchFeatureVideoURL: URL {
        Bundle.main.url(forResource: "voxboard-watch-notelet-square-mobile", withExtension: "mp4")
            ?? Bundle.main.bundleURL.appendingPathComponent("voxboard-watch-notelet-square-mobile.mp4")
    }

    private static let versionNotes: [VersionNotes] = [
        .init(
            version: "2.6",
            items: [
                .list(
                    title: "What’s new in Vox.md",
                    rows: [
                        .init(
                            symbolSystemName: "pause.circle.fill",
                            title: "Pause and resume recordings",
                            description: "Take a moment to gather your thoughts — iPhone and Mac recordings can now be paused and resumed as one note, with paused audio and time excluded, just like on Apple Watch."
                        )
                    ]
                )
            ]
        ),
        .init(
            version: "2.2",
            items: [
                .list(
                    title: "What’s new in Vox.md",
                    rows: [
                        .init(
                            symbolSystemName: "waveform.and.mic",
                            title: "Meeting capture with separate stems",
                            description: "On Mac, record meetings with system audio and your microphone kept as distinct stems, so what you hear and what you say stay cleanly separated."
                        ),
                        .init(
                            symbolSystemName: "globe",
                            title: "Choose the app language",
                            description: "Pick Vox.md’s language in Settings on iPhone and iPad — no need to change your whole device language to use the app your way."
                        ),
                        .init(
                            symbolSystemName: "mappin.and.ellipse",
                            title: "The {location} template token",
                            description: "Entry templates can now place capture location precisely where you want it in your Markdown, alongside existing time tokens."
                        ),
                        .init(
                            symbolSystemName: "internaldrive.fill",
                            title: "Models without the copies",
                            description: "On Mac, transcription models already on disk are used where they are — Vox.md no longer duplicates them, saving significant space."
                        ),
                        .init(
                            symbolSystemName: "timer",
                            title: "Capture that always finishes",
                            description: "Text processing and voice enrichment now run under strict deadlines, so captures complete instead of stalling, with steadier speaker labels and sharper German throughout."
                        )
                    ]
                )
            ]
        ),
        .init(
            version: "2.1",
            items: [
                .list(
                    title: "What’s new in Vox.md",
                    rows: [
                        .init(
                            symbolSystemName: "tray.full.fill",
                            title: "Your recordings, preserved",
                            description: "Recordings now enter a durable queue before transcription and delivery. Interrupted, failed, or undelivered audio stays available to retry, process, share, or delete, with completed text ready to copy."
                        ),
                        .init(
                            symbolSystemName: "location.fill",
                            title: "Add location when you choose",
                            description: "Each Capture Preset can optionally add exact or city-level location metadata to your Markdown. Vox.md never tracks your location in the background."
                        ),
                        .init(
                            symbolSystemName: "percent",
                            title: "Progress you can trust",
                            description: "Supported transcriptions now show truthful percentages, while model downloads report real phases and byte or file progress, with storage checks and safer installation."
                        ),
                        .init(
                            symbolSystemName: "globe",
                            title: "Use more of Vox.md in your language",
                            description: "Core screens, settings, statuses, errors, paywalls, accessibility labels, and built-in Preset and model descriptions now have broader coverage across 23 locales."
                        ),
                        .init(
                            symbolSystemName: "checkmark.circle.fill",
                            title: "Sharper capture details",
                            description: "Capture templates use when substantive content began, widgets keep the Preset you chose, and Watch tasks arrive without duplicate transcript wrappers."
                        )
                    ]
                )
            ]
        ),
        .init(
            version: "2.0.6",
            items: [
                .list(
                    title: "What’s new in Vox.md",
                    rows: [
                        .init(
                            symbolSystemName: "person.2.fill",
                            title: "Follow every speaker",
                            description: "Capture Presets can now add anonymous, best-effort speaker labels to meeting recordings entirely on your device."
                        ),
                        .init(
                            symbolSystemName: "record.circle",
                            title: "Safer recording controls",
                            description: "Live Activity actions now target the recording you intended, stale activities clean themselves up, and long recordings stop before earlier audio can be overwritten."
                        ),
                        .init(
                            symbolSystemName: "sun.max.fill",
                            title: "Widgets match your appearance",
                            description: "Quick Capture and Quick Record widgets now adapt to light and dark mode so their text and controls stay readable."
                        )
                    ]
                )
            ]
        ),
        .init(
            version: "2.0.5",
            items: [
                .list(
                    title: "What’s new in Vox.md",
                    rows: [
                        .init(
                            symbolSystemName: "keyboard",
                            title: "Keyboard dictation stays in the keyboard",
                            description: "Voice input from the Vox.md keyboard now transcribes into your text field without also activating or sending an in-app Capture."
                        ),
                        .init(
                            symbolSystemName: "waveform.badge.minus",
                            title: "No duplicate microphone state",
                            description: "Keyboard-owned recordings no longer light up the Quick Capture microphone or export a second raw-audio capture."
                        ),
                        .init(
                            symbolSystemName: "person.2.fill",
                            title: "Clearer lifetime purchase options",
                            description: "The unlock screen now explains individual and Family Sharing access more clearly, including upgrade eligibility and trial status."
                        )
                    ]
                )
            ]
        ),
        .init(
            version: "2.0.4",
            items: [
                .list(
                    title: "What’s new in Vox.md",
                    rows: [
                        .init(
                            symbolSystemName: "timer",
                            title: "Voice Auto-Stop everywhere",
                            description: "Use the optional on-device Voice Pause Detection model with the keyboard, Quick Capture, widgets, Live Activities, and Apple Watch. Choose exactly where auto-stop runs in Settings."
                        ),
                        .init(
                            symbolSystemName: "waveform.badge.plus",
                            title: "See recordings as they happen",
                            description: "Active Quick Capture recordings now show elapsed time and a live waveform. Send Immediately recordings can also show live Apple Speech text without adding it to your draft."
                        ),
                        .init(
                            symbolSystemName: "arrow.triangle.2.circlepath",
                            title: "More reliable live transcripts",
                            description: "Cancelled or previous recording sessions can no longer replace or clear the text from a newer recording."
                        ),
                        .init(
                            symbolSystemName: "folder.badge.gearshape",
                            title: "Choose existing notes reliably",
                            description: "Vox.md now handles more Files and File Provider path variations when you select an existing Markdown note or template, while keeping destination boundaries protected."
                        )
                    ]
                )
            ]
        ),
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

    static let notes = versionNotes.map {
        NoteletVersionNotes(version: $0.version, items: $0.items)
    }

    static var presentedVersion: NoteletPresentedVersion? {
        if ProcessInfo.processInfo.arguments.contains("--disable-release-notes") {
            return nil
        }

        return .current
    }

    static var shouldPresentCurrentVersion: Bool {
        let currentAppVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let userDefaults = AppConstants.sharedDefaults ?? .standard
        return shouldPresentCurrentVersion(
            currentAppVersion: currentAppVersion,
            latestSeenAppVersion: NoteletStorage.getLatestSeenAppVersion(userDefaults: userDefaults),
            releaseNotesEnabled: presentedVersion != nil
        )
    }

    static func shouldPresentCurrentVersion(
        currentAppVersion: String,
        latestSeenAppVersion: String?,
        releaseNotesEnabled: Bool
    ) -> Bool {
        let hasNotesForCurrentVersion = versionNotes
            .first(where: { $0.version == currentAppVersion })?
            .items.isEmpty == false

        return releaseNotesEnabled
            && hasNotesForCurrentVersion
            && latestSeenAppVersion != currentAppVersion
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

private struct DefersCaptureInputFocusForReleaseNotesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var defersCaptureInputFocusForReleaseNotes: Bool {
        get { self[DefersCaptureInputFocusForReleaseNotesKey.self] }
        set { self[DefersCaptureInputFocusForReleaseNotesKey.self] = newValue }
    }
}

extension View {
    func voxboardReleaseNotesSheet(onDismiss: @escaping () -> Void = { }) -> some View {
        noteletSheet(
            notes: VoxboardReleaseNotes.notes,
            version: VoxboardReleaseNotes.presentedVersion,
            onDismiss: onDismiss,
            configuration: VoxboardReleaseNotes.configuration,
            userDefaults: AppConstants.sharedDefaults ?? .standard
        )
    }
}
