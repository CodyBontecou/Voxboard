import SwiftUI
import VoxVaultShared

@main
struct VoxVaultApp: App {
    @State private var modelManager = ModelManager()
    @State private var transcriptStore = TranscriptStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(modelManager)
                .environment(transcriptStore)
                .onAppear {
                    modelManager.copyBundledModelIfNeeded()
                }
        }
    }
}
