import AppKit
import SwiftUI
import VoxboardShared

@main
struct VoxboardMacApp: App {
    @State private var modelManager = ModelManager()
    @State private var transcriptStore: TranscriptStore
    @State private var usageTracker: UsageTracker
    @State private var storeManager: MacStoreManager
    @State private var recorder: MacRecorder

    init() {
        let store = TranscriptStore()
        let usage = UsageTracker()
        let storeManager = MacStoreManager(usageTracker: usage)
        let recorder = MacRecorder(transcriptStore: store, usageTracker: usage)

        _transcriptStore = State(initialValue: store)
        _usageTracker = State(initialValue: usage)
        _storeManager = State(initialValue: storeManager)
        _recorder = State(initialValue: recorder)
    }

    var body: some Scene {
        WindowGroup {
            MacRootView(recorder: recorder)
                .environment(modelManager)
                .environment(transcriptStore)
                .environment(usageTracker)
                .environment(storeManager)
                .onAppear {
                    modelManager.copyBundledModelIfNeeded()
                    storeManager.start()
                    transcriptStore.reload()
                    usageTracker.reload()
                }
        }
        .commands {
            CommandMenu("Voxboard") {
                Button("Reveal Data Folder") {
                    if let url = AppConstants.sharedContainerURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
    }
}
