import SwiftUI
import VoxVaultShared

@main
struct VoxVaultApp: App {
    @State private var modelManager = ModelManager()
    @State private var transcriptStore = TranscriptStore()
    @State private var persistentRecorder: PersistentRecorder

    init() {
        let store = TranscriptStore()
        _transcriptStore = State(initialValue: store)
        _persistentRecorder = State(initialValue: PersistentRecorder(transcriptStore: store))
    }
    @Environment(\.scenePhase) private var scenePhase

    /// Handles transcription requests from the keyboard extension (legacy IPC flow).
    private let transcriptionServer = TranscriptionServer()

    var body: some Scene {
        WindowGroup {
            HomeView(persistentRecorder: persistentRecorder)
                .environment(modelManager)
                .environment(transcriptStore)
                .onAppear {
                    modelManager.copyBundledModelIfNeeded()
                    transcriptionServer.start()

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
            log.log("[App] Listen request — starting persistent recorder")
            if !persistentRecorder.isListening {
                persistentRecorder.startListening()
            }

        case "record":
            // Legacy: keyboard opened app for one-off recording
            // Redirect to persistent listening mode instead
            log.log("[App] Legacy record request — starting persistent recorder instead")
            if !persistentRecorder.isListening {
                persistentRecorder.startListening()
            }

        default:
            log.log("[App] ❌ Unknown host: \(url.host ?? "nil")")
        }
    }
}
