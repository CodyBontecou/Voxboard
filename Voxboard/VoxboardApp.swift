import AppIntents
import SwiftUI
import VoxboardShared

@main
struct VoxboardApp: App {
    #if DEBUG
    private static let runtimeQueueValidationArgument = "--runtime-queue-validation"
    #endif

    @UIApplicationDelegateAdaptor(VoxboardAppDelegate.self) private var appDelegate

    @State private var modelManager = ModelManager()
    @State private var transcriptStore = TranscriptStore()
    @State private var persistentRecorder: PersistentRecorder
    @State private var watchRecordingPipeline: WatchRecordingPipeline
    @State private var usageTracker = UsageTracker()
    @State private var storeManager: StoreManager
    @State private var quickCaptureViewModel: QuickCaptureViewModel
    @State private var rootDestination: RootDestination = .capture
    @State private var defersCaptureInputFocusForReleaseNotes = VoxboardReleaseNotes.shouldPresentCurrentVersion

    /// Set to true when the app is opened via the keyboard's "Open" button.
    /// Capture's inline recording controls consume this launch request.
    @State private var pendingKeyboardLaunch = false

    /// Set to true when the app is opened via the lock screen widget.
    /// Capture's inline recording controls consume this one-shot request.
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

        let shouldStartPendingWidgetRecord = AppConstants.sharedDefaults?.bool(forKey: AppConstants.pendingWidgetRecordKey) == true
            && AppConstants.lockScreenQuickRecordEnabled
        _pendingWidgetRecord = State(initialValue: shouldStartPendingWidgetRecord)
        if shouldStartPendingWidgetRecord {
            AppConstants.sharedDefaults?.set(false, forKey: AppConstants.pendingWidgetRecordKey)
        }

        // Construct the on-device LLM enricher if the user's device supports
        // Apple Intelligence. Individual Capture Preset settings decide whether a given
        // transcript uses enrichment. On older/ineligible devices, `isAvailable`
        // returns false and the recorder is built without an enricher — affected
        // Preset modes fall back to deterministic formatting or raw transcripts.
        let enricher: TranscriptEnricher?
        if #available(iOS 26, *), FoundationModelsBackend.isAvailable {
            enricher = TranscriptEnricher(backend: FoundationModelsBackend())
        } else {
            enricher = nil
        }

        let speakerDiarizationService = SpeakerDiarizationService()
        let captureRequestProcessor = CapturePresetRequestProcessor(
            textProcessor: enricher.map(EnrichedCapturePresetTextProcessor.init(enricher:))
        )
        let captureViewModel = QuickCaptureViewModel(requestProcessor: captureRequestProcessor)
        _quickCaptureViewModel = State(initialValue: captureViewModel)

        #if DEBUG
        if let destination = RootDestination.localizationScreenshotDestination {
            _rootDestination = State(initialValue: destination)
        }
        if RootDestination.localizationScreenshotStory != nil {
            _defersCaptureInputFocusForReleaseNotes = State(initialValue: true)
        }
        #endif

        let recorder = PersistentRecorder(
            transcriptStore: store,
            usageTracker: usage,
            transcriptionService: AppTranscriptionServices.shared,
            speakerDiarizationService: speakerDiarizationService,
            captureDraftEventHandler: { [weak captureViewModel] event in
                guard let captureViewModel else { return false }
                switch event {
                case .origin(let source, let locationOutcome, let profileSnapshot):
                    return await captureViewModel.journalRecordedOrigin(
                        source: source,
                        outcome: locationOutcome,
                        profileSnapshot: profileSnapshot
                    )
                case .clearOrigin(let profileID):
                    return await captureViewModel.clearRecordedOrigin(profileID: profileID)
                case .audio(let url, let draftRequestID, let deliveryID):
                    guard draftRequestID == nil || captureViewModel.draft.requestID == draftRequestID else {
                        return false
                    }
                    return await captureViewModel.stageRecordedAudio(
                        at: url,
                        deliveryID: deliveryID
                    ) != nil
                case .liveTranscript(let sessionID, let finalizedText, let volatileText):
                    await captureViewModel.updateLiveRecordedTranscript(
                        sessionID: sessionID,
                        finalizedText: finalizedText,
                        volatileText: volatileText
                    )
                    return true
                case .cancelLiveTranscript(let sessionID):
                    await captureViewModel.cancelLiveRecordedTranscript(sessionID: sessionID)
                    return true
                case .transcript(let text, let draftRequestID, let liveSessionID, let deliveryID):
                    guard draftRequestID == nil || captureViewModel.draft.requestID == draftRequestID else {
                        return false
                    }
                    return await captureViewModel.appendRecordedTranscript(
                        text,
                        sessionID: liveSessionID,
                        deliveryID: deliveryID
                    )
                }
            },
            transcriptEnricher: enricher
        )
        _persistentRecorder = State(initialValue: recorder)

        #if DEBUG
        recorder.configureLocalizationScreenshot(
            story: RootDestination.localizationScreenshotStory
        )
        #endif

        let watchPipeline = WatchRecordingPipeline(
            transcriptStore: store,
            usageTracker: usage,
            transcriptionService: AppTranscriptionServices.shared,
            speakerDiarizationService: speakerDiarizationService,
            transcriptEnricher: enricher
        )
        watchPipeline.configure(recorder: recorder)
        _watchRecordingPipeline = State(initialValue: watchPipeline)
        WatchRecordingController.shared.configure(
            recorder: recorder,
            usageTracker: usage,
            watchPipeline: watchPipeline
        )
    }

    @Environment(\.scenePhase) private var scenePhase

    /// Handles transcription requests from the keyboard extension (legacy IPC flow).
    private let transcriptionServer = TranscriptionServer(
        transcriptionService: AppTranscriptionServices.shared
    )

    @ViewBuilder
    private var rootContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(Self.runtimeQueueValidationArgument) {
            NavigationStack {
                RecordingQueueView(
                    queue: persistentRecorder.recordingQueue,
                    recoveryPresets: CapturePresetStore.loadFlows()
                )
            }
        } else {
            standardRootContent
        }
        #else
        standardRootContent
        #endif
    }

    private var standardRootContent: some View {
        RootView(
            persistentRecorder: persistentRecorder,
            quickCaptureViewModel: quickCaptureViewModel,
            rootDestination: $rootDestination,
            pendingKeyboardLaunch: $pendingKeyboardLaunch,
            pendingWidgetRecord: $pendingWidgetRecord
        )
    }

    var body: some Scene {
        WindowGroup {
            rootContent
            .environment(modelManager)
            .environment(transcriptStore)
            .environment(usageTracker)
            .environment(storeManager)
            .environment(watchRecordingPipeline)
            .environment(
                \.defersCaptureInputFocusForReleaseNotes,
                defersCaptureInputFocusForReleaseNotes
            )
            .voxboardReleaseNotesSheet {
                defersCaptureInputFocusForReleaseNotes = false
            }
            .onAppear {
                updateIdleTimer()
                WatchRecordingController.shared.configure(
                    recorder: persistentRecorder,
                    usageTracker: usageTracker,
                    watchPipeline: watchRecordingPipeline
                )
                watchRecordingPipeline.resume()
                persistentRecorder.resumeRecordingQueue()
                consumePendingWidgetRecordIfNeeded()
                consumePendingQuickCaptureOpenIfNeeded()

                transcriptionServer.start()
                storeManager.start()
                Task {
                    await storeManager.syncCurrentEntitlements()
                    usageTracker.reload()
                    await quickCaptureViewModel.processPendingInbox()
                }
                trackInitialOnboardingStartIfNeeded()
                ReviewPromptManager.shared.recordAppUsageDay()
                ReviewPromptManager.shared.requestPendingPromptIfPossible()

                // Auto-start listening if user previously enabled it
                if AppConstants.sharedDefaults?.bool(forKey: AppConstants.autoListenEnabledKey) == true {
                    persistentRecorder.startListening()
                }
            }
            .onOpenURL { url in
                handleURL(url)
            }
            .onChange(of: usageTracker.hasUnlocked) { _, hasUnlocked in
                guard hasUnlocked else { return }
                watchRecordingPipeline.resume()
                persistentRecorder.resumeRecordingQueue()
                Task { await quickCaptureViewModel.processPendingInbox() }
            }
            .onChange(of: modelManager.hasActiveDownloads) { _, _ in
                updateIdleTimer()
            }
            .task(id: "\(modelManager.selectedModelId)|\(modelManager.selectedLanguage)") {
                let service = AppTranscriptionServices.shared
                let fallbackID = modelManager.preferredFallbackModelID
                if modelManager.isAutomaticSelection {
                    AppConstants.sharedDefaults?.set(false, forKey: AppConstants.automaticBackendReadyKey)
                }
                do {
                    try await service.prepare(
                        modelID: modelManager.selectedModelId,
                        fallbackModelID: fallbackID,
                        language: modelManager.selectedLanguage
                    )
                    AppConstants.sharedDefaults?.set(true, forKey: AppConstants.automaticBackendReadyKey)
                } catch {
                    let ready = await service.canTranscribe(
                        modelID: modelManager.selectedModelId,
                        fallbackModelID: fallbackID,
                        language: modelManager.selectedLanguage
                    )
                    AppConstants.sharedDefaults?.set(ready, forKey: AppConstants.automaticBackendReadyKey)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            updateIdleTimer(for: phase)
            if phase == .active {
                transcriptionServer.checkForPendingRequest()
                usageTracker.reload()

                consumePendingWidgetRecordIfNeeded()
                consumePendingQuickCaptureOpenIfNeeded()
                Task {
                    await storeManager.syncCurrentEntitlements()
                    usageTracker.reload()
                    watchRecordingPipeline.resume()
                    persistentRecorder.resumeRecordingQueue()
                    await quickCaptureViewModel.processPendingInbox()
                    watchRecordingPipeline.resume()
                }
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

    // MARK: - Model Downloads

    @MainActor
    private func updateIdleTimer(for phase: ScenePhase? = nil) {
        let isDownloadingModel = modelManager.hasActiveDownloads
        UIApplication.shared.isIdleTimerDisabled = (phase ?? scenePhase) == .active && isDownloadingModel
    }

    // MARK: - Pending Quick Record

    private func consumePendingWidgetRecordIfNeeded() {
        guard AppConstants.sharedDefaults?.bool(forKey: AppConstants.pendingWidgetRecordKey) == true else { return }
        AppConstants.sharedDefaults?.set(false, forKey: AppConstants.pendingWidgetRecordKey)
        if AppConstants.lockScreenQuickRecordEnabled {
            rootDestination = .capture
            pendingWidgetRecord = true
        }
    }

    private func consumePendingQuickCaptureOpenIfNeeded() {
        guard AppConstants.sharedDefaults?.bool(forKey: AppConstants.pendingQuickCaptureOpenKey) == true else { return }
        AppConstants.sharedDefaults?.set(false, forKey: AppConstants.pendingQuickCaptureOpenKey)
        if let rawSource = AppConstants.sharedDefaults?.string(forKey: AppConstants.pendingQuickCaptureSourceKey),
           let source = CaptureSource(rawValue: rawSource) {
            AppConstants.sharedDefaults?.removeObject(forKey: AppConstants.pendingQuickCaptureSourceKey)
            quickCaptureViewModel.requestCaptureSource(source)
        }
        if let voxID = AppConstants.sharedDefaults?.string(forKey: AppConstants.pendingQuickCaptureVoxIdKey) {
            AppConstants.sharedDefaults?.removeObject(forKey: AppConstants.pendingQuickCaptureVoxIdKey)
            quickCaptureViewModel.requestVox(voxID)
        }
        if let rawInput = AppConstants.sharedDefaults?.string(forKey: AppConstants.pendingQuickCaptureInputKey),
           let input = CaptureRequestedInput(rawValue: rawInput) {
            AppConstants.sharedDefaults?.removeObject(forKey: AppConstants.pendingQuickCaptureInputKey)
            quickCaptureViewModel.requestedInput = input
        }
        openCaptureComposer()
    }

    // MARK: - Capture Navigation

    private func openCaptureComposer() {
        rootDestination = .capture
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
        // Never persist query values: capture deep links may contain private
        // note text or URLs. Host-level diagnostics are sufficient.
        log.log("[App] onOpenURL host=\(url.host ?? "nil")")

        guard url.scheme == AppConstants.urlScheme else {
            log.log("[App] ❌ Wrong scheme: \(url.scheme ?? "nil")")
            return
        }

        switch url.host {
        case "capture", "capture-request":
            do {
                let action = try CaptureDeepLinkParser().parse(url)
                log.log("[App] Quick capture request — opening capture composer")
                openCaptureComposer()
                Task { await quickCaptureViewModel.handleDeepLink(action) }
            } catch {
                log.log("[App] ❌ Invalid capture link: \(error)")
                openCaptureComposer()
                quickCaptureViewModel.errorMessage = error.localizedDescription
            }

        case "listen":
            // Keep the legacy URL contract, but route it inside Capture.
            log.log("[App] Listen request — opening inline Capture recording controls")
            rootDestination = .capture
            pendingKeyboardLaunch = true

        case "record":
            // Legacy keyboard URLs now use Capture's inline persistent-listening controls.
            log.log("[App] Legacy record request — opening inline Capture recording controls")
            rootDestination = .capture
            pendingKeyboardLaunch = true

        case "widget-record":
            // Widget tapped — immediately begin a one-shot in-app recording
            guard AppConstants.lockScreenQuickRecordEnabled else {
                log.log("[App] Widget record request ignored — Lock Screen Record Button disabled")
                return
            }
            WidgetRecordingFlowSelection.persistRequestedFlowID(from: url)
            log.log("[App] Widget record request — opening inline Capture recording controls")
            rootDestination = .capture
            pendingWidgetRecord = true

        default:
            log.log("[App] ❌ Unknown host: \(url.host ?? "nil")")
        }
    }
}
