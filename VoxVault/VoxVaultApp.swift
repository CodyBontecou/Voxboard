import SwiftUI
import VoxVaultShared

@main
struct VoxVaultApp: App {
    @State private var modelManager = ModelManager()
    @State private var transcriptStore = TranscriptStore()
    @Environment(\.scenePhase) private var scenePhase

    /// Handles transcription requests from the keyboard extension.
    /// Must be retained for the entire app lifetime so the Darwin
    /// notification observer stays registered.
    private let transcriptionServer = TranscriptionServer()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(modelManager)
                .environment(transcriptStore)
                .onAppear {
                    modelManager.copyBundledModelIfNeeded()
                    transcriptionServer.start()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Pick up any requests that arrived while the app was suspended/terminated
                transcriptionServer.checkForPendingRequest()
            }
        }
    }
}
