import SwiftUI
import VoxVaultShared

@main
struct VoxVaultApp: App {
    @State private var modelManager = ModelManager()
    @State private var transcriptStore = TranscriptStore()
    @Environment(\.scenePhase) private var scenePhase

    /// Handles transcription requests from the keyboard extension (legacy IPC flow).
    private let transcriptionServer = TranscriptionServer()

    /// Active recording controller — kept alive even when app is backgrounded
    /// so the stop command listener and recorder stay active.
    @State private var activeRecordingController: RecordingFlowController?

    var body: some Scene {
        WindowGroup {
            ZStack {
                HomeView()
                    .environment(modelManager)
                    .environment(transcriptStore)
                    .onAppear {
                        modelManager.copyBundledModelIfNeeded()
                        transcriptionServer.start()
                    }
            }
            .fullScreenCover(item: $activeRecordingController) { controller in
                RecordingFlowView(
                    controller: controller,
                    onDismiss: {
                        activeRecordingController = nil
                    }
                )
            }
            .onOpenURL { url in
                handleURL(url)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                transcriptionServer.checkForPendingRequest()
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
        case "record":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []

            let modelId = queryItems.first(where: { $0.name == "model" })?.value
                ?? AppConstants.defaultModelName
            let language = queryItems.first(where: { $0.name == "lang" })?.value
                ?? "auto"
            let requestId = queryItems.first(where: { $0.name == "requestId" })?.value
                ?? UUID().uuidString

            log.log("[App] Record request — model=\(modelId), lang=\(language), requestId=\(requestId)")

            // Clear any stale IPC data
            TranscriptionIPC.clearResponse()
            TranscriptionIPC.clearStatus()
            TranscriptionIPC.clearCommand()

            activeRecordingController = RecordingFlowController(
                modelId: modelId,
                language: language,
                requestId: requestId
            )

        default:
            log.log("[App] ❌ Unknown host: \(url.host ?? "nil")")
        }
    }
}

// MARK: - Identifiable conformance for fullScreenCover

extension RecordingFlowController: Identifiable {
    var id: String { requestId }
}
