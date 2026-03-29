import SwiftUI
import VoxboardShared

@main
struct VoxboardApp: App {
    @State private var modelManager = ModelManager()
    @State private var transcriptStore = TranscriptStore()
    @State private var persistentRecorder: PersistentRecorder
    @State private var usageTracker = UsageTracker()
    @State private var storeManager: StoreManager

    /// Set to true when the app is opened via the keyboard's "Open" button.
    /// HomeView reads this to show the loading overlay.
    @State private var pendingKeyboardLaunch = false

    /// Set to true when the app is opened via the lock screen widget.
    /// HomeView reads this to start listening and immediately begin recording.
    @State private var pendingWidgetRecord = false

    init() {
        let store = TranscriptStore()
        let usage = UsageTracker()
        let storeMan = StoreManager(usageTracker: usage)
        _transcriptStore = State(initialValue: store)
        _usageTracker = State(initialValue: usage)
        _storeManager = State(initialValue: storeMan)
        _persistentRecorder = State(initialValue: PersistentRecorder(transcriptStore: store, usageTracker: usage))
    }
    @Environment(\.scenePhase) private var scenePhase

    /// Handles transcription requests from the keyboard extension (legacy IPC flow).
    private let transcriptionServer = TranscriptionServer()

    var body: some Scene {
        WindowGroup {
            HomeView(
                persistentRecorder: persistentRecorder,
                pendingKeyboardLaunch: $pendingKeyboardLaunch,
                pendingWidgetRecord: $pendingWidgetRecord
            )
                .environment(modelManager)
                .environment(transcriptStore)
                .environment(usageTracker)
                .environment(storeManager)
                .onAppear {
                    modelManager.copyBundledModelIfNeeded()
                    transcriptionServer.start()
                    storeManager.start()

                    // Auto-start listening if user previously enabled it
                    if AppConstants.sharedDefaults?.bool(forKey: "autoListenEnabled") == true {
                        persistentRecorder.startListening()
                    }
                }
                .onOpenURL { url in
                    handleURL(url)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                transcriptionServer.checkForPendingRequest()
                usageTracker.reload()

                // Check if the Control Widget signaled a pending record
                if AppConstants.sharedDefaults?.bool(forKey: "pendingWidgetRecord") == true {
                    AppConstants.sharedDefaults?.set(false, forKey: "pendingWidgetRecord")
                    pendingWidgetRecord = true
                }

                // Re-check listening state — if the user enabled auto-listen
                // but the engine stopped (e.g. audio interruption), restart it.
                if AppConstants.sharedDefaults?.bool(forKey: "autoListenEnabled") == true,
                   !persistentRecorder.isListening {
                    persistentRecorder.startListening()
                }
            }
        }
    }

    // MARK: - URL Handling

    private func handleURL(_ url: URL) {
        let log = KeyboardDebugLog.shared
        log.log("[App] onOpenURL: \(url.absoluteString)")

        guard url.scheme == AppConstants.urlScheme else {
            log.log("[App] ❌ Wrong scheme: \(url.scheme ?? "nil")")
            return
        }

        switch url.host {
        case "listen":
            // Keyboard prompted user to open the app to start listening
            log.log("[App] Listen request — triggering keyboard launch flow")
            pendingKeyboardLaunch = true

        case "record":
            // Legacy: keyboard opened app for one-off recording
            // Redirect to persistent listening mode instead
            log.log("[App] Legacy record request — triggering keyboard launch flow")
            pendingKeyboardLaunch = true

        case "widget-record":
            // Widget tapped — start listening and immediately begin in-app recording
            log.log("[App] Widget record request — starting listening + recording")
            pendingWidgetRecord = true

        default:
            log.log("[App] ❌ Unknown host: \(url.host ?? "nil")")
        }
    }
}
