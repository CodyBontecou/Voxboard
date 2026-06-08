import AppIntents
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
    /// HomeView reads this to immediately begin a one-shot recording.
    @State private var pendingWidgetRecord = false

    init() {
        if #available(iOS 18.0, *) {
            VoxboardShortcutsProvider.updateAppShortcutParameters()
        }

        let store = TranscriptStore()
        let usage = UsageTracker()
        let storeMan = StoreManager(usageTracker: usage)
        _transcriptStore = State(initialValue: store)
        _usageTracker = State(initialValue: usage)
        _storeManager = State(initialValue: storeMan)

        // Construct the on-device LLM enricher if the user's device supports
        // Apple Intelligence. Individual Vox settings decide whether a given
        // transcript uses enrichment. On older/ineligible devices, `isAvailable`
        // returns false and the recorder is built without an enricher — affected
        // Vox modes fall back to deterministic formatting or raw transcripts.
        let enricher: TranscriptEnricher?
        if #available(iOS 26, *), FoundationModelsBackend.isAvailable {
            enricher = TranscriptEnricher(backend: FoundationModelsBackend())
        } else {
            enricher = nil
        }

        _persistentRecorder = State(initialValue: PersistentRecorder(
            transcriptStore: store,
            usageTracker: usage,
            transcriptEnricher: enricher
        ))
    }
    @Environment(\.scenePhase) private var scenePhase

    /// Handles transcription requests from the keyboard extension (legacy IPC flow).
    private let transcriptionServer = TranscriptionServer()

    var body: some Scene {
        WindowGroup {
            RootView(
                persistentRecorder: persistentRecorder,
                pendingKeyboardLaunch: $pendingKeyboardLaunch,
                pendingWidgetRecord: $pendingWidgetRecord
            )
            .environment(modelManager)
            .environment(transcriptStore)
            .environment(usageTracker)
            .environment(storeManager)
            .voxboardReleaseNotesSheet()
            .onAppear {
                modelManager.copyBundledModelIfNeeded()
                transcriptionServer.start()
                storeManager.start()
                trackInitialOnboardingStartIfNeeded()
                ReviewPromptManager.shared.recordAppUsageDay()
                ReviewPromptManager.shared.requestPendingPromptIfPossible()

                // Auto-start listening if user previously enabled it
                if AppConstants.sharedDefaults?.bool(forKey: AppConstants.autoListenEnabledKey) == true {
                    persistentRecorder.startListening()
                }

                consumePendingWidgetRecordIfNeeded()
            }
            .onOpenURL { url in
                handleURL(url)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                transcriptionServer.checkForPendingRequest()
                usageTracker.reload()

                consumePendingWidgetRecordIfNeeded()
                ReviewPromptManager.shared.recordAppUsageDay()
                ReviewPromptManager.shared.requestPendingPromptIfPossible()

                // Re-check listening state — if the user enabled auto-listen
                // but the engine stopped (e.g. audio interruption), restart it.
                if AppConstants.sharedDefaults?.bool(forKey: AppConstants.autoListenEnabledKey) == true,
                   !persistentRecorder.isListening {
                    persistentRecorder.startListening()
                }
            }
        }
    }

    // MARK: - Pending Quick Record

    private func consumePendingWidgetRecordIfNeeded() {
        guard AppConstants.sharedDefaults?.bool(forKey: AppConstants.pendingWidgetRecordKey) == true else { return }
        AppConstants.sharedDefaults?.set(false, forKey: AppConstants.pendingWidgetRecordKey)
        if AppConstants.lockScreenQuickRecordEnabled {
            pendingWidgetRecord = true
        }
    }

    // MARK: - Onboarding Analytics

    private func trackInitialOnboardingStartIfNeeded() {
        let defaults = AppConstants.sharedDefaults ?? .standard
        let key = "onboarding.analytics.started.v1"
        guard !defaults.bool(forKey: key) else { return }

        defaults.set(true, forKey: key)
        OnboardingAnalyticsClient.shared.trackOnboardingStarted(
            quotaState: usageTracker.onboardingAnalyticsQuotaState
        )
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
            // Widget tapped — immediately begin a one-shot in-app recording
            guard AppConstants.lockScreenQuickRecordEnabled else {
                log.log("[App] Widget record request ignored — Lock Screen Record Button disabled")
                return
            }
            if let flowId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "flowId" })?
                .value {
                AppConstants.sharedDefaults?.set(flowId, forKey: AppConstants.pendingWidgetRecordFlowIdKey)
            }
            log.log("[App] Widget record request — starting one-shot recording")
            pendingWidgetRecord = true

        default:
            log.log("[App] ❌ Unknown host: \(url.host ?? "nil")")
        }
    }
}
