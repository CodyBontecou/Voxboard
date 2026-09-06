import AVFoundation
import Foundation
import os.log
import UIKit
import VoxboardShared
import WidgetKit

private let log = KeyboardDebugLog.shared
private let osLog = Logger(subsystem: "bontecou.Voxboard", category: "PersistentRecorder")

/// Emitted when a configured transcript export succeeds or fails.
struct FileExportEvent: Equatable {
    enum Result: Equatable {
        case success(URL)
        case failure(String)
    }

    let id = UUID()
    let result: Result
}

enum RecordingCompletionMode: Equatable, Sendable {
    /// Return text to the Vox.md keyboard without running a Capture Preset.
    case keyboardTranscription
    case captureDraft(attachAudio: Bool)
    case runVox(flowID: String)

    var flowID: String? {
        guard case .runVox(let flowID) = self else { return nil }
        return flowID
    }

    var recordingJobDelivery: RecordingJobDelivery {
        switch self {
        case .keyboardTranscription:
            return .keyboard(requestID: "")
        case .captureDraft(let attachAudio):
            return .captureDraft(attachAudio: attachAudio)
        case .runVox(let flowID):
            return .preset(CapturePresetStore.flow(id: flowID) ?? CapturePresetStore.selectedFlow())
        }
    }

    init?(jobDelivery: RecordingJobDelivery) {
        switch jobDelivery {
        case .keyboard:
            self = .keyboardTranscription
        case .captureDraft(let attachAudio):
            self = .captureDraft(attachAudio: attachAudio)
        case .preset(let flow):
            self = .runVox(flowID: flow.id)
        case .clipboard, .recovery:
            return nil
        }
    }

    var defaultCommandOrigin: RecordingCommand.Origin {
        switch self {
        case .keyboardTranscription:
            return .keyboardExtension
        case .captureDraft:
            return .inAppDraft
        case .runVox:
            return .inAppImmediate
        }
    }

    func commandOrigin(
        overriding requestedOrigin: RecordingCommand.Origin?
    ) -> RecordingCommand.Origin {
        requestedOrigin ?? defaultCommandOrigin
    }

    /// IPC segments do not have an app-owned completion mode assigned before
    /// their start command arrives. Modern keyboard commands carry the selected
    /// Preset explicitly; older commands remain transcription-only.
    static func completionMode(
        forExternalCommand command: RecordingCommand,
        fallbackFlowID: String
    ) -> RecordingCompletionMode {
        switch command.origin {
        case .keyboardExtension:
            guard let flowID = command.flowId, !flowID.isEmpty else {
                return .keyboardTranscription
            }
            return .runVox(flowID: flowID)
        case nil:
            // Commands from keyboard builds predating `origin` remain insertion-only.
            return .keyboardTranscription
        case .inAppDraft, .inAppImmediate, .quickRecord, .liveActivity, .watch:
            return .runVox(flowID: command.flowId ?? fallbackFlowID)
        }
    }

    static func presetSnapshot(
        for completionMode: RecordingCompletionMode,
        lookup: (String) -> CapturePreset?,
        fallback: () -> CapturePreset
    ) -> CapturePreset? {
        guard let flowID = completionMode.flowID else { return nil }
        return lookup(flowID) ?? fallback()
    }

    static func voiceProcessingConfiguration(
        for completionMode: RecordingCompletionMode,
        selectedPreset: CapturePreset?
    ) -> RecordingVoiceProcessingConfiguration? {
        switch completionMode {
        case .keyboardTranscription:
            return nil
        case .captureDraft:
            return selectedPreset.map(RecordingVoiceProcessingConfiguration.init(preset:))
        case .runVox:
            // Preset delivery derives from its immutable delivery snapshot.
            return nil
        }
    }
}

enum CaptureDraftRecordingEvent: Sendable {
    case origin(
        source: CaptureSource,
        locationOutcome: CaptureLocationOutcome?,
        profileSnapshot: CapturePresetProfile
    )
    case clearOrigin(profileID: String)
    case audio(URL, draftRequestID: UUID?, deliveryID: UUID)
    case liveTranscript(sessionID: UUID, finalizedText: String, volatileText: String?)
    case cancelLiveTranscript(sessionID: UUID)
    case transcript(String, draftRequestID: UUID?, liveSessionID: UUID?, deliveryID: UUID)
}

typealias CaptureDraftRecordingEventHandler = @MainActor @Sendable (CaptureDraftRecordingEvent) async -> Bool

struct RecordingSegmentHandoffSnapshot: Equatable, Sendable {
    let draftRequestID: UUID?
    let liveSessionID: UUID?
    let presetSnapshot: CapturePreset?
    let voiceProcessingConfiguration: RecordingVoiceProcessingConfiguration?
}

/// Always-on audio recorder that captures microphone input into a circular buffer.
///
/// The keyboard extension controls transcription segments via IPC commands:
/// - `startSegment`: marks the beginning of a transcription segment
/// - `pauseInAppSegment` / `resumeInAppSegment`: exclude a paused interval
///   from the journal, live transcription, VAD, duration, and extraction
/// - `stopSegment`: extracts the recorded ranges (pauses excluded), transcribes them
///
/// The app only needs to be opened once to start listening. After that, the user
/// never leaves their current app — everything is controlled from the keyboard.
@Observable
final class PersistentRecorder {

    static let modelSetupAnalyticsKey = "onboarding.analytics.model_setup_completed.v1"
    static let completionAnalyticsKey = "onboarding.analytics.completed.v1"

    /// The recorder instance owned by the running app scene. App Intents such
    /// as the recording toggle (Shortcuts, Apple Pencil squeeze, Action Button)
    /// perform inside the app process and use this reference to start or stop
    /// a segment in place — without activating the scene. Weak so a replaced
    /// instance from a scene rebuild never leaks through this handle.
    static weak var active: PersistentRecorder?

    /// Deadline for the optional on-device model routing calls during export
    /// (Smart Folders, Auto-Organize). Routing must never hang delivery behind
    /// a stalled FoundationModels session; on timeout the export proceeds with
    /// the configured folder (#11).
    private static let exportRoutingTimeout: TimeInterval = 30

    static func claimOneShotAnalyticsMarker(
        _ key: String,
        defaults: UserDefaults
    ) -> Bool {
        guard !defaults.bool(forKey: key) else { return false }
        defaults.set(true, forKey: key)
        return true
    }
    #if DEBUG
    private static let runtimeQueuePauseAfterClaimArgument =
        "--runtime-queue-pause-after-claim"
    #endif

    // MARK: - Public State

    var isListening: Bool = false
    var isSegmentActive: Bool = false
    var isTranscribing: Bool = false
    var isResolvingLocation: Bool = false
    var segmentDuration: TimeInterval = 0
    /// Backend-reported progress for the active ASR request. Preparing and
    /// unsupported backends intentionally have no exact fraction.
    var transcriptionProgress: TranscriptionProgress?
    var lastError: String?

    /// Keyboard recordings share this recorder but are not app-owned Capture
    /// recordings. Keep the app mic UI independent from the keyboard mic UI.
    var isAppRecordingSegmentActive: Bool {
        isSegmentActive
            && segmentOrigin != .keyboardExtension
            && segmentCompletionMode != .keyboardTranscription
    }

    var isAppRecordingTranscribing: Bool {
        isTranscribing
            && transcribingCommandOrigin != .keyboardExtension
            && transcribingCompletionMode != .keyboardTranscription
    }

    /// Last transcription result from an in-app recording. Observable for UI display.
    var lastTranscriptionResult: String?
    var lastSpeakerDiarizationSkipReason: SpeakerDiarizationSkipReason?

    /// Progressive Apple Speech text for the active in-app recording. Immediate
    /// Preset runs use this preview without adding their text to the Capture draft.
    var liveFinalizedTranscription: String?
    var liveVolatileTranscription: String?
    var isCaptureLiveTranscriptionActive = false

    /// Updated every time a configured transcript export succeeds or fails.
    var lastFileExportEvent: FileExportEvent?

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?

    /// Circular buffer: 10 minutes at 16 kHz mono = 9,600,000 samples ≈ 38 MB
    private let circularBuffer = CircularAudioBuffer(capacity: 16_000 * 60 * 10)

    /// Target sample rate for whisper.cpp
    private let whisperSampleRate: Double = 16_000

    // MARK: - Cached Model

    /// Preparation state for the shared system/local transcription dispatcher.
    private var isPreloadingModel: Bool = false

    // MARK: - Segment Tracking

    /// Absolute sample index where the current segment starts (in the circular buffer).
    private var segmentStartIndex: Int64 = 0
    private var segmentRequestId: String?
    private var segmentModelId: String?
    private var segmentLanguage: String?
    private var segmentFlowId: String?
    private var segmentCompletionMode: RecordingCompletionMode?
    private var segmentPresetSnapshot: CapturePreset?
    private var segmentVoiceProcessingConfiguration: RecordingVoiceProcessingConfiguration?
    private var segmentOrigin: RecordingCommand.Origin?
    private var transcribingCompletionMode: RecordingCompletionMode?
    private var transcribingCommandOrigin: RecordingCommand.Origin?
    private var segmentDraftRequestID: UUID?
    /// True while the active in-app segment is paused. Paused intervals are
    /// excluded from the journal, the live transcription feed, the duration
    /// clock, and the extracted audio so one note can be gathered in pieces.
    var isSegmentPaused = false
    private var segmentPauseStartIndex: Int64?
    private var segmentPausedRanges: [(start: Int64, end: Int64)] = []
    /// Recording time accumulated before the current pause; the duration
    /// timer adds the running interval on top of this base.
    private var segmentElapsedBeforePause: TimeInterval = 0
    private let segmentJournalLock = NSLock()
    private let segmentJournalWriteQueue = DispatchQueue(
        label: "bontecou.Voxboard.active-recording-journal",
        qos: .utility
    )
    /// Journal gate for paused segments. Guarded by `segmentJournalLock` so
    /// the real-time tap never journals paused audio.
    private var journalPaused = false
    private var segmentJournalWriter: IncrementalWAVWriter?
    private var segmentStartedAt: TimeInterval = 0
    private var liveTranscriptionSetupTask: Task<LiveSegmentTranscriptionCoordinator?, Never>?
    private var endOfSpeechSetupTask: Task<VoiceAutoStopCoordinator?, Never>?
    private var liveCaptureRequestId: String?
    private var liveCaptureDraftRequestId: String?
    private var liveCaptureSessionID: UUID?
    /// Retained after segment state is cleared so competing manual/VAD stop
    /// commands for the same request can be ignored while transcription runs.
    private var processingRequestId: String?
    private var progressRequestId: String?
    private var lastPublishedTranscriptionPercent: Int?

    /// Pre-roll: capture this many seconds before the user tapped Start.
    private let preRollSeconds: TimeInterval = 2.0

    // MARK: - Audio Level Metering

    /// Throttle audio level writes to ~12 times per second max.
    private var lastLevelWriteTime: TimeInterval = 0
    private let levelWriteInterval: TimeInterval = 1.0 / 12.0

    // MARK: - Timers

    private var durationTimer: Timer?
    private var segmentSafetyStopTask: Task<Void, Never>?
    private var listeningHeartbeatTimer: Timer?
    private var commandPollTimer: Timer?
    private var listeningStartedAt: TimeInterval?

    /// The circular buffer retains ten minutes. Finalize before the segment's
    /// pre-roll can be overwritten so an accidentally abandoned recording still
    /// produces a transcript instead of running forever and failing on Stop.
    private let maximumSegmentDuration: TimeInterval = 9 * 60 + 45

    #if DEBUG
    /// Supplies a stable, microphone-free state for localized simulator screenshots.
    /// The launch argument is absent from production launches, so normal recording
    /// behavior and persisted user data are untouched.
    func configureLocalizationScreenshot(story: String?) {
        guard story == "02-live-recording" || story == "05-live-recording" else { return }
        isListening = true
        isSegmentActive = true
        isTranscribing = false
        segmentDuration = 42
        segmentCompletionMode = .captureDraft(attachAudio: false)
        liveFinalizedTranscription = String(localized: "Capture ideas as they arrive.")
        liveVolatileTranscription = String(localized: "Everything stays on this device.")
        isCaptureLiveTranscriptionActive = true
    }
    #endif

    /// Shared transcript store — injected so saved transcripts appear in the UI immediately.
    private let transcriptStore: TranscriptStore

    /// Shared Apple-first dispatcher used by recordings, imports, Quick Capture,
    /// Watch imports, and keyboard requests.
    private let transcriptionService: OnDeviceTranscriptionService

    /// Optional second pass for app-owned presets that identify speakers.
    /// Keyboard and draft transcription never invoke this service.
    private let speakerDiarizationService: SpeakerDiarizationService

    /// Offline-only loader for the explicitly downloaded Silero companion model.
    private let voiceActivityDetectionService: VoiceActivityDetectionService

    /// Delivers app-owned draft recordings into the durable Capture draft.
    /// Keyboard, Widget, Watch, and explicit Capture Preset runs bypass this callback.
    private let captureDraftEventHandler: CaptureDraftRecordingEventHandler?

    /// On-device LLM post-processor. Nil when the feature is disabled or the
    /// model hasn't been downloaded. When set, runs asynchronously after save
    /// to populate title/tags/category/cleanedText on the just-saved transcript.
    private let transcriptEnricher: TranscriptEnricher?

    /// Durable source-audio queue shared with the macOS implementation.
    private(set) var recordingQueue: RecordingJobQueue!

    /// Tracks cumulative usage for the free-tier paywall.
    private let usageTracker: UsageTracker

    /// Set to true when a transcription is blocked because the user has hit the free limit.
    /// Observed by Capture's inline recording controls to present the PaywallView.
    var needsUnlock: Bool = false

    // MARK: - One-shot recording sessions

    /// True when the current in-app/widget/shortcut recording started the audio
    /// engine only for this segment. When the segment stops, audio capture is
    /// torn down immediately so system haptics recover while transcription runs.
    private var shouldAutoStopListeningAfterCurrentRecording = false

    /// True after a one-shot recording has stopped capture but keeps the Live
    /// Activity around in a lightweight processing state until transcription ends.
    private var shouldEndLiveActivityAfterCurrentTranscription = false

    // MARK: - Init

    init(
        transcriptStore: TranscriptStore,
        usageTracker: UsageTracker,
        transcriptionService: OnDeviceTranscriptionService,
        speakerDiarizationService: SpeakerDiarizationService = SpeakerDiarizationService(),
        voiceActivityDetectionService: VoiceActivityDetectionService = VoiceActivityDetectionService(),
        captureDraftEventHandler: CaptureDraftRecordingEventHandler? = nil,
        transcriptEnricher: TranscriptEnricher? = nil
    ) {
        self.transcriptStore = transcriptStore
        self.usageTracker = usageTracker
        self.transcriptionService = transcriptionService
        self.speakerDiarizationService = speakerDiarizationService
        self.voiceActivityDetectionService = voiceActivityDetectionService
        self.captureDraftEventHandler = captureDraftEventHandler
        self.transcriptEnricher = transcriptEnricher
        Self.active = self
        ensureRecordingsDirectory()

        let queueRoot = AppConstants.recordingJobsDirectoryURL
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("VoxboardRecordingJobs", isDirectory: true)
        let jobStore = RecordingJobStore(rootDirectoryURL: queueRoot)
        self.recordingQueue = RecordingJobQueue(store: jobStore) { [weak self] job, audioURL, progress in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(
                PersistentRecorder.runtimeQueuePauseAfterClaimArgument
            ) {
                try await Task.sleep(for: .seconds(30))
                return RecordingJobExecutionResult()
            }
            #endif
            guard let self else { throw CancellationError() }
            return try await self.executeQueuedJob(job, audioURL: audioURL, onProgress: progress)
        }

        // Clear any stale listening state left over from a previous session.
        // If the app was killed/crashed while listening, the IPC file still says
        // isListening=true. Clearing it here ensures the keyboard extension won't
        // try to record against a non-existent recorder and time out after 30s.
        TranscriptionIPC.writeListeningState(ListeningState(
            isListening: false,
            lastHeartbeatAt: Date().timeIntervalSince1970
        ))
        TranscriptionIPC.clearStatus()
        TranscriptionIPC.clearCommand()
        TranscriptionIPC.clearAudioLevel()
        TranscriptionIPC.clearLiveTranscriptionState()
        TranscriptionIPC.postListeningStateNotification()
        WidgetCenter.shared.reloadTimelines(ofKind: "VoxboardRecordWidget")

        // A new recorder instance cannot own audio from the previous process.
        // Dismiss any orphaned/duplicate lock-screen activities before this
        // session optionally starts one fresh monitor.
        LiveActivityController.shared.end()
    }

    deinit {
        if Self.active === self {
            Self.active = nil
        }
        stopListening()
        unregisterCommandObserver()
    }

    // MARK: - Start / Stop Listening

    /// Start microphone capture.
    ///
    /// Persistent keyboard-listening sessions save the auto-listen preference so
    /// the recorder can restart when the app is reopened. One-shot recordings pass
    /// `persistPreference: false` so the app returns to a fully idle audio session.
    @discardableResult
    func startListening(persistPreference: Bool = true) -> Bool {
        guard !isListening else {
            log.log("[PersistentRecorder] Already listening")
            if persistPreference {
                shouldAutoStopListeningAfterCurrentRecording = false
                AppConstants.sharedDefaults?.set(true, forKey: AppConstants.autoListenEnabledKey)
            }
            return true
        }

        let session = AVAudioSession.sharedInstance()

        // Check permission
        let perm = session.recordPermission
        log.log("[PersistentRecorder] startListening — permission=\(perm == .granted ? "granted" : "other"), inputAvailable=\(session.isInputAvailable)")

        guard perm == .granted else {
            log.log("[PersistentRecorder] ❌ Mic permission not granted")
            lastError = String(localized: "Microphone permission required")
            return false
        }

        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setActive(true)
            log.log("[PersistentRecorder] Audio session active")
        } catch {
            log.log("[PersistentRecorder] ❌ Session setup failed: \(error)")
            lastError = String(localized: "Audio session error")
            return false
        }

        // Set up AVAudioEngine
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        log.log("[PersistentRecorder] Input format: \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount) ch")

        // Create converter if needed (hardware format → 16kHz mono)
        let needsConversion = hwFormat.sampleRate != whisperSampleRate || hwFormat.channelCount != 1

        var converter: AVAudioConverter?
        var targetFormat: AVAudioFormat?

        if needsConversion {
            targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: whisperSampleRate,
                channels: 1,
                interleaved: false
            )
            if let tf = targetFormat {
                converter = AVAudioConverter(from: hwFormat, to: tf)
                log.log("[PersistentRecorder] Converter created: \(hwFormat.sampleRate)Hz → \(whisperSampleRate)Hz")
            }
        }

        // Reset buffer
        circularBuffer.reset()

        // Install tap — capture audio and write to circular buffer
        let bufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }

            if let converter, let targetFormat {
                // Convert to 16kHz mono
                let ratio = self.whisperSampleRate / hwFormat.sampleRate
                let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrames) else { return }

                var consumed = false
                converter.convert(to: outputBuffer, error: nil) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }

                if let floatData = outputBuffer.floatChannelData?[0], outputBuffer.frameLength > 0 {
                    let ptr = UnsafeBufferPointer(start: floatData, count: Int(outputBuffer.frameLength))
                    self.circularBuffer.append(ptr)
                    self.appendToSegmentJournal(ptr)
                    self.writeAudioLevelIfNeeded(floatData, frameCount: Int(outputBuffer.frameLength))
                }
            } else {
                // Already 16kHz mono — direct append
                if let floatData = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                    let ptr = UnsafeBufferPointer(start: floatData, count: Int(buffer.frameLength))
                    self.circularBuffer.append(ptr)
                    self.appendToSegmentJournal(ptr)
                    self.writeAudioLevelIfNeeded(floatData, frameCount: Int(buffer.frameLength))
                }
            }
        }

        do {
            try engine.start()
            log.log("[PersistentRecorder] ✅ AVAudioEngine started — always-on listening active")
        } catch {
            log.log("[PersistentRecorder] ❌ Engine start failed: \(error)")
            inputNode.removeTap(onBus: 0)
            // A background launch that cannot start input can leave the session
            // half-activated; deactivate so a later foreground attempt starts
            // from a clean state instead of surfacing a stale Microphone error.
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            lastError = String(localized: "Microphone error")
            return false
        }

        audioEngine = engine
        isListening = true
        lastError = nil
        listeningStartedAt = Date().timeIntervalSince1970

        // Arm both command paths before advertising readiness. The keyboard can
        // react to the listening notification immediately; publishing first can
        // lose its start command in the few milliseconds before observer setup.
        registerCommandObserver()
        startCommandPolling()

        // Write listening state for the keyboard to read and keep it fresh with
        // a heartbeat while the recorder is actually alive. Without this, a
        // killed background app can leave behind `isListening=true`, causing the
        // keyboard mic to appear to record while no app is receiving commands.
        writeListeningHeartbeat(postNotification: true)
        startListeningHeartbeat()
        WidgetCenter.shared.reloadTimelines(ofKind: "VoxboardRecordWidget")
        WatchRecordingController.shared.publishState()
        LiveActivityController.shared.startIfNeeded()

        // Persist only explicit keyboard-listening sessions. One-shot recordings
        // should not re-open the microphone on the next app activation.
        AppConstants.sharedDefaults?.set(persistPreference, forKey: AppConstants.autoListenEnabledKey)

        // Pre-load the default whisper model so the first transcription is fast
        preloadModel()
        trackModelSetupCompletedIfNeeded()

        // Observe audio session interruptions so we can auto-restart the engine
        registerInterruptionObserver()

        log.log("[PersistentRecorder] ✅ Listening started, waiting for keyboard commands")
        return true
    }

    private func startListeningHeartbeat() {
        stopListeningHeartbeat(resetStartedAt: false)

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.isListening else { return }
            self.writeListeningHeartbeat(postNotification: false)
        }
        listeningHeartbeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopListeningHeartbeat(resetStartedAt: Bool = true) {
        listeningHeartbeatTimer?.invalidate()
        listeningHeartbeatTimer = nil
        if resetStartedAt {
            listeningStartedAt = nil
        }
    }

    private func writeListeningHeartbeat(postNotification: Bool) {
        let now = Date().timeIntervalSince1970
        let startedAt = listeningStartedAt ?? now
        listeningStartedAt = startedAt
        TranscriptionIPC.writeListeningState(ListeningState(
            isListening: true,
            startedAt: startedAt,
            lastHeartbeatAt: now
        ))
        if postNotification {
            TranscriptionIPC.postListeningStateNotification()
        }
    }

    /// Prepare Apple Speech (including its system-managed locale asset) or an
    /// explicitly downloaded local model before the first recording completes.
    private func preloadModel() {
        guard !isPreloadingModel else { return }
        isPreloadingModel = true

        Task { [weak self] in
            guard let self else { return }
            _ = await self.prepareTranscriptionBackend()
            self.isPreloadingModel = false
        }
    }

    /// Returns true when either Apple Speech or a user-downloaded local model is
    /// ready. Keyboard setup uses this to avoid declaring readiness too early.
    @discardableResult
    func prepareTranscriptionBackend() async -> Bool {
        let modelID = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
            ?? AppConstants.defaultTranscriptionBackendID
        let fallbackModelID = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedFallbackModelKey)
        let language = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey) ?? "auto"

        log.log("[PersistentRecorder] Preparing transcription backend: \(modelID)…")
        if modelID == TranscriptionBackendID.automatic {
            AppConstants.sharedDefaults?.set(false, forKey: AppConstants.automaticBackendReadyKey)
        }
        do {
            try await transcriptionService.prepare(
                modelID: modelID,
                fallbackModelID: fallbackModelID,
                language: language
            )
            AppConstants.sharedDefaults?.set(true, forKey: AppConstants.automaticBackendReadyKey)
            log.log("[PersistentRecorder] ✅ Transcription backend ready: \(modelID)")
            return true
        } catch {
            let canTranscribe = await transcriptionService.canTranscribe(
                modelID: modelID,
                fallbackModelID: fallbackModelID,
                language: language
            )
            AppConstants.sharedDefaults?.set(canTranscribe, forKey: AppConstants.automaticBackendReadyKey)
            log.log("[PersistentRecorder] ⚠️ Backend preparation failed: \(error.localizedDescription)")
            if !canTranscribe { lastError = error.localizedDescription }
            return canTranscribe
        }
    }

    // MARK: - Onboarding Analytics

    private func trackModelSetupCompletedIfNeeded() {
        let defaults = AppConstants.sharedDefaults ?? .standard
        guard let model = selectedModelForAnalytics(),
              model.isDownloaded,
              Self.claimOneShotAnalyticsMarker(
                  Self.modelSetupAnalyticsKey,
                  defaults: defaults
              ) else { return }

        OnboardingAnalyticsClient.shared.trackModelSetupCompleted(
            metadata: OnboardingAnalyticsModelMetadata(model: model),
            quotaState: usageTracker.onboardingAnalyticsQuotaState
        )
    }

    private func trackOnboardingCompletedIfNeeded(metadata: OnboardingAnalyticsModelMetadata) {
        let defaults = AppConstants.sharedDefaults ?? .standard
        guard Self.claimOneShotAnalyticsMarker(
            Self.completionAnalyticsKey,
            defaults: defaults
        ) else { return }

        OnboardingAnalyticsClient.shared.trackOnboardingCompleted(
            modelMetadata: metadata,
            quotaState: usageTracker.onboardingAnalyticsQuotaState
        )
    }

    private func selectedModelForAnalytics() -> WhisperModelInfo? {
        let modelId = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
            ?? AppConstants.defaultTranscriptionBackendID
        return WhisperModelInfo.availableModels.first { $0.id == modelId }
    }

    // MARK: - Audio Interruption Handling

    private func registerInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    private func removeInterruptionObserver() {
        NotificationCenter.default.removeObserver(
            self,
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            log.log("[PersistentRecorder] ⚠️ Audio interruption began")
            if isSegmentActive {
                cancelSegment(preserveAudioForRecovery: true)
            }
            if shouldAutoStopListeningAfterCurrentRecording {
                lastError = String(localized: "Recording interrupted — please try again")
                stopListening()
            }

        case .ended:
            log.log("[PersistentRecorder] Audio interruption ended — restarting listening")
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionOptions(rawValue: $0) }

            if options?.contains(.shouldResume) ?? true {
                // Full restart: stopListening() tears down the tap and engine;
                // startListening() reinstalls both. iOS sometimes silently
                // disconnects audio taps during long interruptions (phone lock,
                // calls, headphone swaps), and `engine.start()` alone doesn't
                // reconnect the data flow — leaving isListening=true with a
                // dead tap that never delivers samples. A full restart is the
                // only way to reliably self-heal.
                stopListening()
                startListening()
            }

        @unknown default:
            break
        }
    }

    /// Stop microphone capture and end the Live Activity.
    func stopListening() {
        stopListening(endLiveActivity: true)
        shouldEndLiveActivityAfterCurrentTranscription = false
    }

    /// Stop microphone capture while optionally keeping the Live Activity alive.
    ///
    /// One-shot recordings use `endLiveActivity: false` after audio has been
    /// extracted so the UI can show a processing state without keeping the audio
    /// session active (which is what suppresses system haptics).
    private func stopListening(endLiveActivity: Bool) {
        guard isListening else {
            if endLiveActivity {
                LiveActivityController.shared.end()
            }
            return
        }

        log.log("[PersistentRecorder] Stopping listening…")

        // Cancel any active segment
        if isSegmentActive {
            cancelSegment()
        }

        shouldAutoStopListeningAfterCurrentRecording = false

        // Remove interruption observer
        removeInterruptionObserver()

        // Stop engine
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        isListening = false
        stopListeningHeartbeat()
        stopCommandPolling()

        // Deactivate audio session
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        // Update IPC
        TranscriptionIPC.writeListeningState(ListeningState(
            isListening: false,
            lastHeartbeatAt: Date().timeIntervalSince1970
        ))
        TranscriptionIPC.postListeningStateNotification()
        WidgetCenter.shared.reloadTimelines(ofKind: "VoxboardRecordWidget")
        WatchRecordingController.shared.publishState()
        if endLiveActivity {
            LiveActivityController.shared.end()
        }

        unregisterCommandObserver()

        log.log("[PersistentRecorder] ✅ Listening stopped")
    }

    // MARK: - In-App Recording

    /// Start a one-shot recording from the app, widget, or Shortcut.
    ///
    /// If the persistent keyboard-listening engine is already running, this simply
    /// marks a segment and leaves listening on afterward. Otherwise it starts the
    /// microphone only for this recording and automatically returns to idle once
    /// transcription has finished. External entry points pass an origin so their
    /// independent auto-stop preference can be applied.
    @discardableResult
    func startOneShotInAppSegment(
        flowId requestedFlowId: String? = nil,
        completionMode: RecordingCompletionMode? = nil,
        origin requestedOrigin: RecordingCommand.Origin? = nil,
        draftRequestID: UUID? = nil
    ) -> Bool {
        guard !isSegmentActive else {
            log.log("[PersistentRecorder] ⚠️ one-shot start skipped — segment already active")
            return false
        }
        if usageTracker.isAtLimit {
            needsUnlock = true
            lastError = String(localized: "Free limit reached — unlock Vox.md to keep recording")
            return false
        }

        let startedTemporaryListening = !isListening
        if startedTemporaryListening {
            shouldAutoStopListeningAfterCurrentRecording = true
            guard startListening(persistPreference: false) else {
                shouldAutoStopListeningAfterCurrentRecording = false
                return false
            }
        } else {
            shouldAutoStopListeningAfterCurrentRecording = false
        }

        lastTranscriptionResult = nil
        lastError = nil
        startInAppSegment(
            flowId: requestedFlowId,
            completionMode: completionMode,
            origin: requestedOrigin,
            draftRequestID: draftRequestID
        )

        if !isSegmentActive, startedTemporaryListening {
            stopListening()
        }
        return isSegmentActive
    }

    /// Start a recording segment directly from the app UI (no IPC needed).
    func startInAppSegment(
        flowId requestedFlowId: String? = nil,
        completionMode: RecordingCompletionMode? = nil,
        origin requestedOrigin: RecordingCommand.Origin? = nil,
        draftRequestID: UUID? = nil
    ) {
        guard isListening else {
            lastError = String(localized: "Start listening first")
            log.log("[PersistentRecorder] ❌ startInAppSegment but not listening")
            return
        }
        guard !isSegmentActive else {
            log.log("[PersistentRecorder] ⚠️ startInAppSegment skipped — segment already active")
            return
        }

        lastTranscriptionResult = nil
        lastSpeakerDiarizationSkipReason = nil
        lastError = nil

        let modelId = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
            ?? AppConstants.defaultTranscriptionBackendID
        let language = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey)
            ?? "auto"
        let requestId = "inapp-\(UUID().uuidString)"
        let flowId = requestedFlowId.flatMap { requested in
            guard let flow = CapturePresetStore.flow(id: requested), flow.isEnabled else { return nil }
            return flow.id
        } ?? CapturePresetStore.selectedFlowId()

        let resolvedCompletionMode = completionMode ?? .runVox(flowID: flowId)
        let command = RecordingCommand(
            requestId: requestId,
            action: .startSegment,
            modelId: modelId,
            language: language,
            flowId: flowId,
            origin: resolvedCompletionMode.commandOrigin(overriding: requestedOrigin)
        )
        segmentCompletionMode = resolvedCompletionMode
        segmentPresetSnapshot = RecordingCompletionMode.presetSnapshot(
            for: resolvedCompletionMode,
            lookup: { CapturePresetStore.flow(id: $0) },
            fallback: { CapturePresetStore.selectedFlow() }
        )
        segmentVoiceProcessingConfiguration = RecordingCompletionMode.voiceProcessingConfiguration(
            for: resolvedCompletionMode,
            selectedPreset: CapturePresetStore.flow(id: flowId) ?? CapturePresetStore.selectedFlow()
        )
        segmentOrigin = command.origin
        segmentDraftRequestID = draftRequestID

        log.log("[PersistentRecorder] 🎙 In-app segment start: \(requestId) flow=\(flowId)")
        handleStartSegment(command)
    }

    /// Stop the current in-app recording segment and transcribe.
    func stopInAppSegment() {
        guard isSegmentActive else {
            log.log("[PersistentRecorder] ⚠️ stopInAppSegment but no active segment")
            return
        }

        let requestId = segmentRequestId ?? "inapp-\(UUID().uuidString)"
        let command = RecordingCommand(requestId: requestId, action: .stopSegment)

        log.log("[PersistentRecorder] ⏹ In-app segment stop: \(requestId)")
        handleStopSegment(command)
    }

    /// Pause the active in-app recording segment. The listening engine keeps
    /// running (pre-roll and keyboard listening stay intact), but paused audio
    /// is excluded from the durable journal, live transcription, and the final
    /// recording.
    func pauseInAppSegment() {
        guard isAppRecordingSegmentActive, !isSegmentPaused else { return }
        let pauseStart = circularBuffer.totalSamplesWritten
        segmentPauseStartIndex = pauseStart
        segmentElapsedBeforePause += Date().timeIntervalSince1970 - segmentStartedAt
        segmentJournalLock.withLock { journalPaused = true }
        isSegmentPaused = true
        segmentDuration = segmentElapsedBeforePause
        TranscriptionIPC.clearAudioLevel()
        setLiveConsumersPaused(true)
        WatchRecordingController.shared.publishState()
        log.log("[PersistentRecorder] ⏸ In-app segment paused at buffer index \(pauseStart) (recorded \(String(format: "%.1f", segmentElapsedBeforePause))s)")
    }

    /// Resume a paused in-app recording segment. Audio captured while paused
    /// is skipped so the final note has no ambient gap.
    func resumeInAppSegment() {
        guard isAppRecordingSegmentActive, isSegmentPaused else { return }
        let pauseStart = segmentPauseStartIndex
        let resumeIndex = circularBuffer.totalSamplesWritten
        if let pauseStart, resumeIndex > pauseStart {
            segmentPausedRanges.append((pauseStart, resumeIndex))
        }
        segmentPauseStartIndex = nil
        segmentStartedAt = Date().timeIntervalSince1970
        segmentJournalLock.withLock { journalPaused = false }
        isSegmentPaused = false
        setLiveConsumersPaused(false)
        WatchRecordingController.shared.publishState()
        log.log("[PersistentRecorder] ▶️ In-app segment resumed at buffer index \(resumeIndex) (\(segmentPausedRanges.count) paused range(s) excluded)")
    }

    func toggleInAppSegmentPause() {
        if isSegmentPaused {
            resumeInAppSegment()
        } else {
            pauseInAppSegment()
        }
    }

    /// Suspend or resume the live transcription and voice auto-stop feeders.
    /// On resume both coordinators skip ahead past the paused audio so ambient
    /// noise captured during the pause is neither transcribed nor mistaken
    /// for end-of-speech.
    private func setLiveConsumersPaused(_ paused: Bool) {
        let liveTask = liveTranscriptionSetupTask
        let autoStopTask = endOfSpeechSetupTask
        guard liveTask != nil || autoStopTask != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isSegmentActive else { return }
            if let coordinator = await liveTask?.value {
                if paused {
                    await coordinator.pause()
                } else {
                    await coordinator.resume()
                }
            }
            if let coordinator = await autoStopTask?.value {
                if paused {
                    await coordinator.pause()
                } else {
                    await coordinator.resume()
                }
            }
        }
    }

    /// Import an existing audio file, normalize it to Whisper WAV, and run it
    /// through the same local transcription/history/export pipeline as live recordings.
    @discardableResult
    func importAudioFile(
        from url: URL,
        flowId requestedFlowID: String? = nil,
        completionMode requestedCompletionMode: RecordingCompletionMode? = nil,
        draftRequestID: UUID? = nil
    ) -> Bool {
        guard !isSegmentActive else {
            lastError = String(localized: "Finish the current recording before importing audio")
            return false
        }
        if usageTracker.isAtLimit {
            needsUnlock = true
            lastError = String(localized: "Free limit reached — unlock Vox.md to import audio")
            return false
        }
        guard let dir = AppConstants.recordingsDirectoryURL else {
            lastError = String(localized: "Could not access recordings folder")
            return false
        }

        let flowId = requestedFlowID ?? CapturePresetStore.selectedFlowId()
        let importFlow = CapturePresetStore.flow(id: flowId) ?? CapturePresetStore.selectedFlow()
        let completionMode = requestedCompletionMode ?? .runVox(flowID: importFlow.id)
        let immediatePresetSnapshot = RecordingCompletionMode.presetSnapshot(
            for: completionMode,
            lookup: { CapturePresetStore.flow(id: $0) },
            fallback: { importFlow }
        )
        let voiceProcessingConfiguration = RecordingCompletionMode.voiceProcessingConfiguration(
            for: completionMode,
            selectedPreset: importFlow
        )
        let modelId = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
            ?? AppConstants.defaultTranscriptionBackendID
        let language = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey)
            ?? "auto"
        let fallbackModelID = AppConstants.sharedDefaults?.string(
            forKey: AppConstants.selectedFallbackModelKey
        )
        let queueConfiguration = RecordingQueuePreferences.load()
        let requestId = "import-\(UUID().uuidString)"
        let jobID = UUID()
        let initialDelivery: RecordingJobDelivery = {
            if case .runVox = completionMode, let immediatePresetSnapshot {
                return .preset(immediatePresetSnapshot)
            }
            return completionMode.recordingJobDelivery
        }()
        lastTranscriptionResult = nil
        lastSpeakerDiarizationSkipReason = nil
        lastError = nil

        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let sourceExt = url.pathExtension.isEmpty ? "audio" : url.pathExtension
            let sourceCopy = dir
                .appendingPathComponent("import_source_\(UUID().uuidString)")
                .appendingPathExtension(sourceExt)
            try? FileManager.default.removeItem(at: sourceCopy)
            try FileManager.default.copyItem(at: url, to: sourceCopy)

            let wavURL = dir
                .appendingPathComponent("import_\(UUID().uuidString)")
                .appendingPathExtension("wav")
            do {
                try RecordingJobHandoffIntentStore(recordingsDirectoryURL: dir).save(
                    RecordingJobHandoffIntent(
                        jobID: jobID,
                        audioFilename: sourceCopy.lastPathComponent,
                        requestID: requestId,
                        draftRequestID: draftRequestID,
                        captureSource: .fileImport,
                        locationOutcome: importFlow.locationPolicy.isEnabled
                            ? .unavailable(.unavailable, attemptedAt: Date())
                            : nil,
                        duration: 0,
                        source: .importedAudio,
                        delivery: initialDelivery,
                        voiceProcessingConfiguration: voiceProcessingConfiguration,
                        modelID: modelId,
                        fallbackModelID: fallbackModelID,
                        language: language,
                        configuration: queueConfiguration
                    )
                )
            } catch {
                lastError = String(localized: "Could not preserve the imported recording handoff.")
                return false
            }
            recordingQueue.setCaptureActive(true)
            let originLocationTask = beginOriginLocationResolution(
                requestID: requestId,
                completionMode: completionMode,
                commandOrigin: .inAppImmediate,
                sourceOverride: .fileImport,
                flowOverrideID: importFlow.id,
                draftProfile: {
                    if case .captureDraft = completionMode { return importFlow.captureProfile }
                    return nil
                }(),
                presetOverride: immediatePresetSnapshot
            )
            let disabledLocationDraftJournalTask: Task<Bool, Never>? = {
                guard case .captureDraft = completionMode,
                      !importFlow.locationPolicy.isEnabled else { return nil }
                return Task { @MainActor [weak self] in
                    await self?.captureDraftEventHandler?(.origin(
                        source: .fileImport,
                        locationOutcome: nil,
                        profileSnapshot: importFlow.captureProfile
                    )) ?? false
                }
            }()

            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    if let disabledLocationDraftJournalTask,
                       await disabledLocationDraftJournalTask.value == false {
                        throw NSError(
                            domain: "CaptureOriginMetadata",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: String(
                                    localized: "Shared capture storage is unavailable."
                                )
                            ]
                        )
                    }
                    let originSnapshot = await originLocationTask?.value
                    if originLocationTask != nil, originSnapshot == nil {
                        throw NSError(
                            domain: "CaptureOriginMetadata",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: String(
                                    localized: "Shared capture storage is unavailable."
                                )
                            ]
                        )
                    }
                    let workingURL = try AudioFileConverter.convertToWhisperWAV(
                        inputURL: sourceCopy,
                        outputURL: wavURL
                    )
                    let duration = AudioFileConverter.duration(of: workingURL)
                        ?? AudioFileConverter.duration(of: sourceCopy)
                        ?? 0
                    let stagedIntent = try RecordingJobHandoffIntentStore(
                        recordingsDirectoryURL: dir
                    ).load(jobID: jobID)
                    guard let stagedIntent else {
                        throw NSError(domain: "RecordingHandoff", code: 2)
                    }
                    try RecordingJobHandoffIntentStore(recordingsDirectoryURL: dir).save(
                        stagedIntent.finalized(
                            audioFilename: workingURL.lastPathComponent,
                            relatedAudioFilenames: workingURL == sourceCopy ? [] : [sourceCopy.lastPathComponent],
                            duration: duration,
                            captureSource: originSnapshot?.source ?? .fileImport,
                            locationOutcome: originSnapshot?.outcome
                        )
                    )
                    await MainActor.run {
                        self?.enqueueAppRecording(
                            audioURL: workingURL,
                            requestId: requestId,
                            modelId: modelId,
                            fallbackModelId: fallbackModelID,
                            language: language,
                            duration: duration,
                            completionMode: completionMode,
                            source: .importedAudio,
                            jobID: jobID,
                            draftRequestID: draftRequestID,
                            captureSource: originSnapshot?.source ?? .fileImport,
                            locationOutcome: originSnapshot?.outcome,
                            presetSnapshot: immediatePresetSnapshot,
                            voiceProcessingConfiguration: voiceProcessingConfiguration,
                            queueConfiguration: queueConfiguration,
                            finishCaptureHandoff: true
                        )
                    }
                } catch {
                    if case .captureDraft = completionMode {
                        _ = await self?.captureDraftEventHandler?(
                            .clearOrigin(profileID: importFlow.id)
                        )
                    }
                    await MainActor.run {
                        self?.discardOriginLocationResolution(originLocationTask, requestID: requestId)
                        self?.lastError = String(localized: "Could not import audio: \(error.localizedDescription). The imported source was preserved.")
                        self?.lastTranscriptionResult = nil
                        self?.recordingQueue.setCaptureActive(false)
                    }
                }
            }
            return true
        } catch {
            lastError = String(localized: "Could not import audio: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Segment Control

    /// Fast start segment handler — runs on the high-priority command queue.
    /// Marks the buffer position and writes IPC status immediately, then
    /// dispatches UI state updates to main thread.
    private func handleStartSegmentFast(_ command: RecordingCommand) {
        guard isListening else {
            log.log("[PersistentRecorder] ❌ startSegment but not listening")
            osLog.error("❌ startSegment but not listening!")
            return
        }

        guard !isSegmentActive else {
            log.log("[PersistentRecorder] ⚠️ startSegment but segment already active")
            osLog.warning("⚠️ startSegment but segment already active")
            return
        }

        log.log("[PersistentRecorder] 🎙 Starting segment (fast path): \(command.requestId)")
        osLog.notice("🎙 Starting segment: \(command.requestId)")

        // Paywall check (re-checked on main thread in the dispatch below, but do a quick
        // static check here too so we can bail early on the background queue).
        if UsageTracker.staticIsAtLimit {
            log.log("[PersistentRecorder] 🔒 Fast-path: Free limit reached — blocking segment")
            DispatchQueue.main.async { [weak self] in
                self?.writeErrorResponse(
                    requestId: command.requestId,
                    message: String(localized: "Free limit reached — open Vox.md to unlock")
                )
                self?.needsUnlock = true
            }
            return
        }

        // CRITICAL: Mark buffer position immediately — this is the time-sensitive part.
        // The circular buffer is thread-safe, so reading indices off-main is safe.
        let preRollSamples = Int64(preRollSeconds * whisperSampleRate)
        let currentIndex = circularBuffer.totalSamplesWritten
        let earliest = circularBuffer.earliestAvailableIndex
        let startIdx = max(currentIndex - preRollSamples, earliest)
        let startedAt = Date().timeIntervalSince1970

        log.log("[PersistentRecorder] Buffer state: totalWritten=\(currentIndex) earliest=\(earliest) segmentStart=\(startIdx)")

        // Write IPC status immediately so the keyboard sees confirmation fast
        TranscriptionIPC.writeStatus(RecordingStatus(
            requestId: command.requestId,
            phase: .recording,
            recordingStartedAt: startedAt
        ))

        // Clear stale audio level and reset throttle
        TranscriptionIPC.clearAudioLevel()
        lastLevelWriteTime = 0

        log.log("[PersistentRecorder] ✅ Buffer position marked at index \(startIdx) (pre-roll: \(preRollSamples) samples)")

        // Update observable state on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.segmentStartIndex = startIdx
            self.segmentRequestId = command.requestId
            self.segmentModelId = command.modelId
            self.segmentLanguage = command.language
            self.segmentFlowId = command.flowId
            self.segmentCompletionMode = .completionMode(
                forExternalCommand: command,
                fallbackFlowID: command.flowId ?? CapturePresetStore.selectedFlowId()
            )
            self.segmentPresetSnapshot = self.segmentCompletionMode.flatMap {
                RecordingCompletionMode.presetSnapshot(
                    for: $0,
                    lookup: { CapturePresetStore.flow(id: $0) },
                    fallback: { CapturePresetStore.selectedFlow() }
                )
            }
            self.segmentVoiceProcessingConfiguration = self.segmentCompletionMode.flatMap {
                RecordingCompletionMode.voiceProcessingConfiguration(
                    for: $0,
                    selectedPreset: command.flowId.flatMap { CapturePresetStore.flow(id: $0) }
                )
            }
            self.segmentOrigin = command.origin
            self.segmentStartedAt = startedAt
            self.isSegmentActive = true
            self.segmentDuration = 0
            self.isSegmentPaused = false
            self.segmentPauseStartIndex = nil
            self.segmentPausedRanges = []
            self.segmentElapsedBeforePause = 0
            if self.segmentCompletionMode == .keyboardTranscription {
                self.recordingQueue.interruptForInteractiveWork()
            } else {
                self.recordingQueue.setCaptureActive(true)
            }
            self.startSegmentJournal(requestID: command.requestId)
            self.startDurationTimer()
            log.log("[PersistentRecorder] ✅ Segment UI state updated on main thread")
        }
    }

    /// Mark the start of a transcription segment (main-thread path, kept for direct calls).
    private func handleStartSegment(_ command: RecordingCommand) {
        guard isListening else {
            log.log("[PersistentRecorder] ❌ startSegment but not listening")
            return
        }

        guard !isSegmentActive else {
            log.log("[PersistentRecorder] ⚠️ startSegment but another segment is active")
            writeErrorResponse(
                requestId: command.requestId,
                message: String(localized: "Finish the current recording first")
            )
            return
        }
        // Paywall check — block if free tier exhausted
        if usageTracker.isAtLimit {
            log.log("[PersistentRecorder] 🔒 Free limit reached — blocking segment")
            writeErrorResponse(
                requestId: command.requestId,
                message: String(localized: "Free limit reached — open Vox.md to unlock")
            )
            needsUnlock = true
            return
        }

        log.log("[PersistentRecorder] 🎙 Starting segment: \(command.requestId)")

        // Re-assert the audio session category in case something (e.g. on-device
        // LLM inference, a notification sound, or a system service) reconfigured
        // it between startListening() and now. Without this, the tap can end up
        // delivering silence while the engine still appears to be running.
        let session = AVAudioSession.sharedInstance()
        log.log("[PersistentRecorder] Session category=\(session.category.rawValue) isInputAvailable=\(session.isInputAvailable)")
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setActive(true)
            log.log("[PersistentRecorder] ✅ Audio session re-asserted for segment")
        } catch {
            log.log("[PersistentRecorder] ⚠️ Audio session re-assert failed: \(error)")
        }

        // Calculate start index with pre-roll
        let preRollSamples = Int64(preRollSeconds * whisperSampleRate)
        let currentIndex = circularBuffer.totalSamplesWritten
        let earliest = circularBuffer.earliestAvailableIndex
        segmentStartIndex = max(currentIndex - preRollSamples, earliest)
        log.log("[PersistentRecorder] Buffer state: totalWritten=\(currentIndex) earliest=\(earliest) segmentStart=\(max(currentIndex - preRollSamples, earliest))")

        segmentRequestId = command.requestId
        segmentModelId = command.modelId
        segmentLanguage = command.language
        segmentFlowId = command.flowId
        segmentOrigin = command.origin ?? segmentOrigin
        if segmentCompletionMode == nil {
            segmentCompletionMode = .completionMode(
                forExternalCommand: command,
                fallbackFlowID: command.flowId ?? CapturePresetStore.selectedFlowId()
            )
        }
        if segmentPresetSnapshot == nil, let segmentCompletionMode {
            segmentPresetSnapshot = RecordingCompletionMode.presetSnapshot(
                for: segmentCompletionMode,
                lookup: { CapturePresetStore.flow(id: $0) },
                fallback: { CapturePresetStore.selectedFlow() }
            )
        }
        if segmentVoiceProcessingConfiguration == nil, let segmentCompletionMode {
            segmentVoiceProcessingConfiguration = RecordingCompletionMode.voiceProcessingConfiguration(
                for: segmentCompletionMode,
                selectedPreset: command.flowId.flatMap { CapturePresetStore.flow(id: $0) }
            )
        }
        if segmentCompletionMode == .keyboardTranscription {
            lastTranscriptionResult = nil
        }
        segmentStartedAt = Date().timeIntervalSince1970
        isSegmentActive = true
        segmentDuration = 0
        isSegmentPaused = false
        segmentPauseStartIndex = nil
        segmentPausedRanges = []
        segmentElapsedBeforePause = 0
        if segmentCompletionMode == .keyboardTranscription {
            recordingQueue.interruptForInteractiveWork()
        } else {
            recordingQueue.setCaptureActive(true)
        }
        startSegmentJournal(requestID: command.requestId)

        startLiveTranscriptionIfSupported(
            command: command,
            startIndex: segmentStartIndex,
            language: segmentLanguage ?? "auto"
        )
        startVoiceAutoStopIfSupported(
            command: command,
            startIndex: currentIndex
        )

        // Start duration timer
        startDurationTimer()

        // Write status for keyboard
        TranscriptionIPC.writeStatus(RecordingStatus(
            requestId: command.requestId,
            phase: .recording,
            recordingStartedAt: segmentStartedAt
        ))

        LiveActivityController.shared.update(
            isSegmentActive: true,
            startedAt: segmentStartedAt,
            requestId: command.requestId
        )
        WatchRecordingController.shared.publishState()

        log.log("[PersistentRecorder] ✅ Segment started at buffer index \(segmentStartIndex) (pre-roll: \(preRollSamples) samples)")
    }

    /// Extract the segment's audio from the circular buffer, skipping every
    /// paused range. With no pauses this is the original contiguous read.
    private func extractSegmentSamples(endIndex: Int64) -> [Float]? {
        Self.extractSegmentSamples(
            from: circularBuffer,
            startIndex: segmentStartIndex,
            endIndex: endIndex,
            pausedRanges: segmentPausedRanges
        )
    }

    /// Internal (testable) core of paused-range extraction: concatenates the
    /// non-paused spans between `startIndex` and `endIndex`.
    static func extractSegmentSamples(
        from buffer: CircularAudioBuffer,
        startIndex: Int64,
        endIndex: Int64,
        pausedRanges: [(start: Int64, end: Int64)]
    ) -> [Float]? {
        guard !pausedRanges.isEmpty else {
            return buffer.extract(from: startIndex, to: endIndex)
        }
        var samples: [Float] = []
        var cursor = startIndex
        for (pauseStart, pauseEnd) in pausedRanges {
            if pauseStart > cursor {
                guard let chunk = buffer.extract(from: cursor, to: pauseStart) else { return nil }
                samples.append(contentsOf: chunk)
            }
            // Advance past the paused span — also when the segment start
            // (pre-roll) landed inside the pause.
            cursor = max(cursor, pauseEnd)
        }
        if cursor < endIndex {
            guard let tail = buffer.extract(from: cursor, to: endIndex) else { return nil }
            samples.append(contentsOf: tail)
        }
        return samples
    }

    private func startLiveTranscriptionIfSupported(
        command: RecordingCommand,
        startIndex: Int64,
        language: String
    ) {
        cancelLiveTranscription()
        TranscriptionIPC.clearLiveTranscriptionState()

        let publishesToKeyboard = command.origin == .keyboardExtension
        let publishesToCapture = command.requestId.hasPrefix("inapp-")
        let publishesToDraft: Bool
        if publishesToCapture,
           let completionMode = segmentCompletionMode,
           case .captureDraft = completionMode {
            publishesToDraft = true
        } else {
            publishesToDraft = false
        }
        if publishesToCapture {
            liveCaptureRequestId = command.requestId
            liveCaptureDraftRequestId = publishesToDraft ? command.requestId : nil
            liveCaptureSessionID = UUID()
            liveFinalizedTranscription = nil
            liveVolatileTranscription = nil
            isCaptureLiveTranscriptionActive = false
        }

        guard (publishesToKeyboard || publishesToCapture),
              command.modelId == TranscriptionBackendID.automatic else {
            return
        }

        let service = transcriptionService
        let buffer = circularBuffer
        let requestId = command.requestId
        let sampleRate = whisperSampleRate
        let captureSessionID = liveCaptureSessionID
        let draftEventHandler = publishesToDraft ? captureDraftEventHandler : nil

        liveTranscriptionSetupTask = Task.detached(priority: .userInitiated) {
            var startedSession: (any SystemLiveTranscriptionSession)?
            let progress = LiveTranscriptionProgress()
            do {
                guard let session = try await service.startLiveTranscription(
                    modelID: TranscriptionBackendID.automatic,
                    language: language,
                    onUpdate: { update in
                        await progress.record(update)
                        if publishesToKeyboard {
                            TranscriptionIPC.writeLiveSnapshot(LiveTranscriptionSnapshot(
                                requestId: requestId,
                                revision: update.revision,
                                finalizedText: update.finalizedText,
                                volatileText: update.volatileText
                            ))
                        } else if publishesToCapture {
                            let requestIsCurrent = await MainActor.run { [weak self] in
                                guard let self,
                                      self.liveCaptureRequestId == requestId,
                                      self.liveCaptureSessionID == captureSessionID else { return false }
                                self.liveFinalizedTranscription = update.finalizedText.isEmpty
                                    ? nil
                                    : update.finalizedText
                                self.liveVolatileTranscription = update.volatileText
                                return true
                            }
                            guard requestIsCurrent else { return }
                            if let draftEventHandler, let captureSessionID {
                                _ = await draftEventHandler(.liveTranscript(
                                    sessionID: captureSessionID,
                                    finalizedText: update.finalizedText,
                                    volatileText: update.volatileText
                                ))
                            }
                        }
                    }
                ) else {
                    return nil
                }
                startedSession = session
                try Task.checkCancellation()

                let coordinator = LiveSegmentTranscriptionCoordinator(
                    session: session,
                    circularBuffer: buffer,
                    startIndex: startIndex,
                    sampleRate: sampleRate,
                    progress: progress
                )
                await coordinator.start()
                if publishesToCapture {
                    await MainActor.run { [weak self] in
                        guard let self,
                              self.liveCaptureRequestId == requestId,
                              self.liveCaptureSessionID == captureSessionID,
                              self.isSegmentActive else { return }
                        self.isCaptureLiveTranscriptionActive = true
                    }
                }
                return coordinator
            } catch {
                if let startedSession {
                    await startedSession.cancel()
                }
                if publishesToCapture {
                    KeyboardDebugLog.shared.log("[PersistentRecorder] Live Apple Speech setup failed; using batch transcription: \(error.localizedDescription)")
                }
                return nil
            }
        }
    }

    private func cancelLiveTranscription() {
        guard let setupTask = liveTranscriptionSetupTask else { return }
        liveTranscriptionSetupTask = nil
        setupTask.cancel()
        Task.detached {
            if let coordinator = await setupTask.value {
                await coordinator.cancel()
            }
        }
    }

    private func startVoiceAutoStopIfSupported(
        command: RecordingCommand,
        startIndex: Int64
    ) {
        cancelEndOfSpeechDetection()

        guard let capturePath = VoiceAutoStopPolicy.capturePath(for: command),
              AppConstants.voiceAutoStopEnabled(for: capturePath),
              VoiceActivityModelAsset.isInstalled else {
            return
        }

        let requestID = command.requestId
        let service = voiceActivityDetectionService
        let buffer = circularBuffer
        let minimumSilenceDuration = AppConstants.voiceAutoStopPauseDuration

        endOfSpeechSetupTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let session = try await service.makeStreamingSession(
                    minimumSilenceDuration: minimumSilenceDuration
                )
                try Task.checkCancellation()

                let isStillActive = await MainActor.run { [weak self] in
                    self?.isSegmentActive == true && self?.segmentRequestId == requestID
                }
                guard isStillActive else { return nil }

                let coordinator = VoiceAutoStopCoordinator(
                    requestID: requestID,
                    session: session,
                    circularBuffer: buffer,
                    startIndex: startIndex
                ) { [weak self] in
                    guard let self,
                          self.isSegmentActive,
                          self.segmentRequestId == requestID else { return }
                    log.log("[PersistentRecorder] ⏹ Auto-stopping after voice pause: \(requestID.prefix(8))")
                    self.handleStopSegment(
                        RecordingCommand(requestId: requestID, action: .stopSegment),
                        trigger: .endOfSpeech
                    )
                }
                await coordinator.start()
                await MainActor.run {
                    log.log("[PersistentRecorder] Voice pause detection armed for \(requestID.prefix(8)) path=\(capturePath.rawValue)")
                }
                return coordinator
            } catch is CancellationError {
                return nil
            } catch {
                await MainActor.run {
                    log.log("[PersistentRecorder] Voice pause detection unavailable; manual stop remains active: \(error.localizedDescription)")
                }
                return nil
            }
        }
    }

    private func cancelEndOfSpeechDetection() {
        guard let setupTask = endOfSpeechSetupTask else { return }
        endOfSpeechSetupTask = nil
        setupTask.cancel()
        Task.detached {
            if let coordinator = await setupTask.value {
                await coordinator.cancel()
            }
        }
    }

    private func clearCaptureLiveTranscription(requestId: String?) {
        guard let requestId, liveCaptureRequestId == requestId else { return }
        let shouldCancelDraftPreview = liveCaptureDraftRequestId == requestId
        let cancelledSessionID = liveCaptureSessionID
        liveCaptureRequestId = nil
        liveCaptureDraftRequestId = nil
        liveCaptureSessionID = nil
        liveFinalizedTranscription = nil
        liveVolatileTranscription = nil
        isCaptureLiveTranscriptionActive = false
        guard shouldCancelDraftPreview,
              let cancelledSessionID,
              let captureDraftEventHandler else { return }
        Task { @MainActor in
            _ = await captureDraftEventHandler(.cancelLiveTranscript(sessionID: cancelledSessionID))
        }
    }

    private enum SegmentStopTrigger: String {
        case manual
        case endOfSpeech
    }

    /// Mark the end of a segment — extract audio and transcribe.
    private func handleStopSegment(
        _ command: RecordingCommand,
        trigger: SegmentStopTrigger = .manual
    ) {
        osLog.notice("⏹ handleStopSegment called — trigger=\(trigger.rawValue) isSegmentActive=\(self.isSegmentActive) segmentRequestId=\(self.segmentRequestId ?? "nil") command.requestId=\(command.requestId)")
        guard isSegmentActive else {
            if processingRequestId == command.requestId {
                log.log("[PersistentRecorder] Ignoring duplicate stop for request already transcribing: \(command.requestId.prefix(8))")
                return
            }
            if command.origin == .liveActivity {
                log.log("[PersistentRecorder] Ignoring Live Activity stop because no segment is active")
                return
            }

            log.log("[PersistentRecorder] ⚠️ stopSegment but no active segment")
            osLog.error("❌ stopSegment but isSegmentActive=false! Writing error response.")
            // Write an error response so the keyboard doesn't get stuck in "Transcribing…" forever
            let requestId = segmentRequestId ?? command.requestId
            writeErrorResponse(
                requestId: requestId,
                message: String(localized: "Recording session expired — please try again")
            )
            clearCaptureLiveTranscription(requestId: requestId)
            return
        }

        guard let requestId = command.resolvedStopRequestId(activeRequestId: segmentRequestId) else {
            log.log("[PersistentRecorder] ⚠️ Ignoring stop for mismatched request \(command.requestId.prefix(8))")
            return
        }
        let flowId = segmentFlowId ?? command.flowId ?? CapturePresetStore.selectedFlowId()
        let completionMode = segmentCompletionMode
            ?? .completionMode(forExternalCommand: command, fallbackFlowID: flowId)
        let presetSnapshot = segmentPresetSnapshot
            ?? RecordingCompletionMode.presetSnapshot(
                for: completionMode,
                lookup: { CapturePresetStore.flow(id: $0) },
                fallback: { CapturePresetStore.selectedFlow() }
            )
        // Snapshot every identity needed by the asynchronous handoff before any
        // clearSegmentState call can reset the mutable recorder session.
        let handoffSnapshot = Self.handoffSnapshot(
            draftRequestID: segmentDraftRequestID,
            liveSessionID: liveCaptureSessionID,
            presetSnapshot: presetSnapshot,
            voiceProcessingConfiguration: segmentVoiceProcessingConfiguration
        )
        let draftRequestID = handoffSnapshot.draftRequestID
        let captureSessionID = handoffSnapshot.liveSessionID
        let voiceProcessingConfiguration = handoffSnapshot.voiceProcessingConfiguration
        // Start origin acquisition at the stop event, before audio extraction or
        // transcription. Legacy insertion-only keyboard and draft modes skip it.
        let originLocationTask = beginOriginLocationResolution(
            requestID: requestId,
            completionMode: completionMode,
            commandOrigin: command.origin ?? segmentOrigin,
            presetOverride: presetSnapshot
        )
        processingRequestId = requestId
        progressRequestId = requestId
        lastPublishedTranscriptionPercent = nil
        transcriptionProgress = nil
        transcribingCompletionMode = completionMode
        transcribingCommandOrigin = command.origin ?? segmentOrigin
        if completionMode == .keyboardTranscription {
            processingRequestId = requestId
            progressRequestId = requestId
            lastPublishedTranscriptionPercent = nil
            transcriptionProgress = nil
            transcribingCompletionMode = completionMode
        }
        log.log("[PersistentRecorder] ⏹ Stopping segment: \(requestId.prefix(8)) trigger=\(trigger.rawValue) (segmentRequestId=\(segmentRequestId?.prefix(8) ?? "nil"), command.requestId=\(command.requestId.prefix(8)))")
        osLog.notice("⏹ Stopping segment: \(requestId)")

        stopDurationTimer()
        isSegmentActive = false
        let segmentJournalURL = finalizeSegmentJournal()
        cancelEndOfSpeechDetection()
        TranscriptionIPC.clearAudioLevel()

        // Close any in-flight pause so the final extraction and the live
        // transcription finish both exclude audio captured while paused.
        let endIndex = circularBuffer.totalSamplesWritten
        let pausedTailExclusionEnd: Int64?
        if isSegmentPaused {
            if let pauseStart = segmentPauseStartIndex, endIndex > pauseStart {
                segmentPausedRanges.append((pauseStart, endIndex))
            }
            segmentPauseStartIndex = nil
            isSegmentPaused = false
            pausedTailExclusionEnd = endIndex
        } else {
            pausedTailExclusionEnd = nil
        }

        // Extract audio from the circular buffer, excluding paused ranges
        guard let samples = extractSegmentSamples(endIndex: endIndex) else {
            // Two distinct failure modes land here. Distinguish them so the
            // log is actionable and we only self-heal when appropriate.
            if endIndex == segmentStartIndex {
                // The audio tap is not delivering samples — usually because
                // iOS disconnected it during an interruption that we never
                // saw an `.ended` event for (app was backgrounded during a
                // call, phone locked for hours, etc.). Recover by rebuilding
                // the engine + tap from scratch so the next recording works.
                log.log("[PersistentRecorder] ❌ Audio tap not delivering samples — restarting listening to recover")
                if shouldAutoStopListeningAfterCurrentRecording {
                    finishStoppedSegmentWithError(
                        requestId: requestId,
                        message: String(localized: "Microphone wasn't receiving audio — please try again"),
                        originLocationTask: originLocationTask
                    )
                } else {
                    writeErrorResponse(
                        requestId: requestId,
                        message: String(localized: "Microphone wasn't receiving audio — please try again")
                    )
                    clearCaptureLiveTranscription(requestId: requestId)
                    processingRequestId = nil
                    transcribingCompletionMode = nil
                    transcribingCommandOrigin = nil
                    discardOriginLocationResolution(originLocationTask, requestID: requestId)
                    clearSegmentState()
                    recordingQueue.setCaptureActive(false)
                    stopListening()
                    startListening()
                }
            } else {
                log.log("[PersistentRecorder] ❌ Could not extract audio — data was overwritten")
                finishStoppedSegmentWithError(
                    requestId: requestId,
                    message: String(localized: "Audio buffer overwritten — try a shorter recording"),
                    originLocationTask: originLocationTask
                )
            }
            return
        }

        let durationSec = Float(samples.count) / Float(whisperSampleRate)
        log.log("[PersistentRecorder] Extracted \(samples.count) samples (\(String(format: "%.1f", durationSec))s)")

        guard samples.count > Int(whisperSampleRate * 0.3) else {
            log.log("[PersistentRecorder] ⚠️ Segment too short (<0.3s)")
            finishStoppedSegmentWithError(
                requestId: requestId,
                message: String(localized: "Recording too short"),
                originLocationTask: originLocationTask
            )
            return
        }

        // Check audio isn't silent
        let maxAmp = samples.map { abs($0) }.max() ?? 0
        log.log("[PersistentRecorder] Audio maxAmp=\(String(format: "%.4f", maxAmp))")
        if maxAmp < 0.005 {
            log.log("[PersistentRecorder] ⚠️ Audio appears silent")
            finishStoppedSegmentWithError(
                requestId: requestId,
                message: String(localized: "No speech detected"),
                originLocationTask: originLocationTask
            )
            return
        }

        // Write WAV file
        guard let wavURL = writeWAV(samples: samples) else {
            finishStoppedSegmentWithError(
                requestId: requestId,
                message: String(localized: "Failed to save audio"),
                originLocationTask: originLocationTask
            )
            return
        }

        log.log("[PersistentRecorder] WAV written: \(wavURL.lastPathComponent)")

        if completionMode != .keyboardTranscription {
            let modelId = segmentModelId ?? command.modelId ?? AppConstants.defaultTranscriptionBackendID
            let language = segmentLanguage ?? command.language ?? "auto"
            let duration = TimeInterval(durationSec)

            if shouldAutoStopListeningAfterCurrentRecording {
                if UIApplication.shared.applicationState == .active {
                    stopListening()
                } else {
                    // Backgrounded one-shot (recording toggled from a shortcut
                    // or hardware trigger): keep the audio session active so
                    // iOS cannot suspend the process while the queued job
                    // transcribes and delivers — a suspended process strands
                    // the Live Activity in "Working" until the app is opened.
                    // executeQueuedJob tears the session down when done.
                    shouldEndLiveActivityAfterCurrentTranscription = true
                }
            } else {
                LiveActivityController.shared.update(
                    isSegmentActive: false,
                    isTranscribing: false,
                    startedAt: nil
                )
            }
            let jobID = captureSessionID ?? UUID()
            let delivery: RecordingJobDelivery = {
                if case .runVox = completionMode, let presetSnapshot {
                    return .preset(presetSnapshot)
                }
                return completionMode.recordingJobDelivery
            }()
            let fallbackModelID = AppConstants.sharedDefaults?.string(
                forKey: AppConstants.selectedFallbackModelKey
            )
            let queueConfiguration = RecordingQueuePreferences.load()
            let handoffIntentStore = AppConstants.recordingsDirectoryURL.map(
                RecordingJobHandoffIntentStore.init(recordingsDirectoryURL:)
            )
            guard let handoffIntentStore else {
                lastError = String(localized: "The recording handoff could not be preserved. The original audio was preserved.")
                discardOriginLocationResolution(originLocationTask, requestID: requestId)
                clearSegmentState()
                recordingQueue.setCaptureActive(false)
                return
            }
            do {
                try handoffIntentStore.save(RecordingJobHandoffIntent(
                    jobID: jobID,
                    audioFilename: wavURL.lastPathComponent,
                    relatedAudioFilenames: [segmentJournalURL?.lastPathComponent].compactMap { $0 },
                    requestID: requestId,
                    draftRequestID: draftRequestID,
                    liveSessionID: captureSessionID,
                    captureSource: CaptureSource.recordingSource(for: command.origin ?? segmentOrigin),
                    locationOutcome: presetSnapshot?.locationPolicy.isEnabled == true
                        ? .unavailable(.unavailable, attemptedAt: Date())
                        : nil,
                    duration: duration,
                    source: .iOSApp,
                    delivery: delivery,
                    voiceProcessingConfiguration: voiceProcessingConfiguration,
                    modelID: modelId,
                    fallbackModelID: fallbackModelID,
                    language: language,
                    configuration: queueConfiguration
                ))
            } catch {
                lastError = String(localized: "The recording handoff could not be preserved. The original audio was preserved.")
                discardOriginLocationResolution(originLocationTask, requestID: requestId)
                clearSegmentState()
                recordingQueue.setCaptureActive(false)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let originSnapshot = await originLocationTask?.value
                guard originLocationTask == nil || originSnapshot != nil else {
                    self.lastError = String(localized: "Shared capture storage is unavailable. The recording was preserved.")
                    self.recordingQueue.setCaptureActive(false)
                    return
                }
                do {
                    guard let stagedIntent = try handoffIntentStore.load(jobID: jobID) else {
                        throw NSError(domain: "RecordingHandoff", code: 2)
                    }
                    try handoffIntentStore.save(stagedIntent.finalized(
                        audioFilename: wavURL.lastPathComponent,
                        relatedAudioFilenames: [segmentJournalURL?.lastPathComponent].compactMap { $0 },
                        duration: duration,
                        captureSource: originSnapshot?.source,
                        locationOutcome: originSnapshot?.outcome
                    ))
                } catch {
                    self.lastError = String(localized: "The recording handoff could not be preserved. The original audio was preserved.")
                    self.recordingQueue.setCaptureActive(false)
                    return
                }
                self.enqueueAppRecording(
                    audioURL: wavURL,
                    requestId: requestId,
                    modelId: modelId,
                    fallbackModelId: fallbackModelID,
                    language: language,
                    duration: duration,
                    completionMode: completionMode,
                    jobID: jobID,
                    draftRequestID: draftRequestID,
                    liveSessionID: captureSessionID,
                    fallbackRecoveryURL: segmentJournalURL,
                    captureSource: originSnapshot?.source,
                    locationOutcome: originSnapshot?.outcome,
                    presetSnapshot: presetSnapshot,
                    voiceProcessingConfiguration: voiceProcessingConfiguration,
                    queueConfiguration: queueConfiguration,
                    finishCaptureHandoff: true
                )
            }
            clearSegmentState()
            TranscriptionIPC.clearStatus()
            WatchRecordingController.shared.publishState()
            return
        }

        recordingQueue.interruptForInteractiveWork()

        // Update status to transcribing. If this was a one-shot recording,
        // tear down audio capture now (restoring system haptics) while leaving
        // the Live Activity visible in a lightweight processing state.
        isTranscribing = true
        let recordingStartedAt = segmentStartedAt
        let transcriptionStartedAt = Date().timeIntervalSince1970
        TranscriptionIPC.writeStatus(RecordingStatus(
            requestId: requestId,
            phase: .transcribing,
            recordingStartedAt: recordingStartedAt,
            recordingStoppedAt: transcriptionStartedAt
        ))
        LiveActivityController.shared.update(isSegmentActive: false, isTranscribing: true, startedAt: nil)
        WatchRecordingController.shared.publishState()

        // Request background time before deactivating the audio session. One-shot
        // recordings may be stopped from the Lock Screen/Dynamic Island while the
        // app is backgrounded, and transcription still needs time to finish.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            log.log("[PersistentRecorder] ⚠️ Background task expired")
            // Safety net when the session was kept alive through transcription:
            // tear it down rather than leaving the microphone running.
            if let self,
               self.shouldAutoStopListeningAfterCurrentRecording,
               !self.isSegmentActive {
                self.stopListening()
            }
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        if shouldAutoStopListeningAfterCurrentRecording {
            shouldEndLiveActivityAfterCurrentTranscription = true
            // Backgrounded one-shots (recording toggled from a shortcut or
            // hardware trigger) keep the audio session active through
            // transcription: a suspendable process freezes mid-processing and
            // strands the Live Activity in a "Working" state until the app is
            // reopened. The completion and error paths stop listening, and the
            // task-expiry handler above is the safety net. Foreground stops
            // keep the early teardown so system haptics recover immediately.
            if UIApplication.shared.applicationState == .active {
                stopListening(endLiveActivity: false)
            }
        }

        // Transcribe
        let modelId = segmentModelId ?? command.modelId ?? AppConstants.defaultTranscriptionBackendID
        let language = segmentLanguage ?? command.language ?? "auto"
        let duration = TimeInterval(durationSec)
        let liveSetupTask = liveTranscriptionSetupTask
        liveTranscriptionSetupTask = nil

        Task.detached(priority: .userInitiated) { [self] in
            var liveResult: OnDeviceTranscriptionResult?
            var usesLiveDelivery = false
            if let liveSetupTask,
               let coordinator = await liveSetupTask.value {
                do {
                    if let pausedTailExclusionEnd {
                        await coordinator.resume(until: pausedTailExclusionEnd)
                    }
                    let output = try await coordinator.finish(through: endIndex)
                    liveResult = OnDeviceTranscriptionResult(
                        text: output.text,
                        backendID: TranscriptionBackendID.appleSpeech,
                        backendName: "Apple Speech",
                        backendKind: .appleSpeech,
                        language: output.language
                    )
                } catch {
                    await coordinator.cancel()
                    await MainActor.run {
                        log.log("[PersistentRecorder] Live Apple Speech failed; using batch fallback: \(error.localizedDescription)")
                    }
                }
                usesLiveDelivery = await coordinator.hasPublishedFinalizedText()
            }

                do {
                let cleanupResult = try await KeyboardRecordingArtifactRetention.perform(
                    wavURL: wavURL,
                    journalURL: segmentJournalURL
                ) {
                    _ = try await self.transcribe(
                        audioURL: wavURL,
                        modelId: modelId,
                        language: language,
                        requestId: requestId,
                        duration: duration,
                        completionMode: completionMode,
                        sourceAudioURL: wavURL,
                        resolvedResult: liveResult,
                        usesLiveDelivery: usesLiveDelivery,
                        recordingStartedAt: recordingStartedAt,
                        transcriptionStartedAt: transcriptionStartedAt,
                        originLocationTask: originLocationTask,
                        presetSnapshot: presetSnapshot,
                        cleanupWorkingAudio: false
                    )
                }
                if !cleanupResult.didRemoveAllArtifacts {
                    KeyboardDebugLog.shared.log(
                        "[PersistentRecorder] Keyboard delivery succeeded; "
                        + "retained \(cleanupResult.retainedArtifactCount) artifact(s) after cleanup failure; "
                        + "unprotected=\(cleanupResult.unprotectedRetainedArtifactCount)"
                    )
                }
            } catch {
                // The transcription method has already published the interactive
                // keyboard error. Keep the WAV so support/recovery tooling can
                // recover it instead of deleting the only source recording.
                KeyboardDebugLog.shared.log("[PersistentRecorder] Keyboard transcription preserved after failure: \(error.localizedDescription)")
            }

            await MainActor.run {
                self.isTranscribing = false
                self.transcribingCompletionMode = nil
                self.transcribingCommandOrigin = nil
                if self.processingRequestId == requestId {
                    self.processingRequestId = nil
                    self.progressRequestId = nil
                    self.transcriptionProgress = nil
                    self.lastPublishedTranscriptionPercent = nil
                }
                self.finishLiveActivityAfterTranscription()
                self.recordingQueue.finishInteractiveWork(includeIdle: true)
                WatchRecordingController.shared.publishState()
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                }
            }
        }

        // Clear segment state
        clearSegmentState()
    }

    private func finishStoppedSegmentWithError(
        requestId: String,
        message: String,
        originLocationTask: Task<CaptureRecordingOriginSnapshot?, Never>? = nil
    ) {
        writeErrorResponse(requestId: requestId, message: message)
        discardOriginLocationResolution(originLocationTask, requestID: requestId)
        clearCaptureLiveTranscription(requestId: requestId)
        isTranscribing = false
        transcribingCompletionMode = nil
        transcribingCommandOrigin = nil
        if processingRequestId == requestId {
            isTranscribing = false
            transcribingCompletionMode = nil
            processingRequestId = nil
            progressRequestId = nil
            transcriptionProgress = nil
            lastPublishedTranscriptionPercent = nil
        }
        clearSegmentState()
        recordingQueue.setCaptureActive(false)

        if shouldAutoStopListeningAfterCurrentRecording {
            stopListening()
        } else {
            LiveActivityController.shared.update(isSegmentActive: false, isTranscribing: false, startedAt: nil)
            WatchRecordingController.shared.publishState()
        }
    }

    private func finishLiveActivityAfterTranscription() {
        guard !isSegmentActive else { return }
        if shouldEndLiveActivityAfterCurrentTranscription {
            shouldEndLiveActivityAfterCurrentTranscription = false
            LiveActivityController.shared.end()
        } else if isListening {
            LiveActivityController.shared.update(isSegmentActive: false, isTranscribing: false, startedAt: nil)
        }
    }

    static func handoffSnapshot(
        draftRequestID: UUID?,
        liveSessionID: UUID?,
        presetSnapshot: CapturePreset?,
        voiceProcessingConfiguration: RecordingVoiceProcessingConfiguration? = nil
    ) -> RecordingSegmentHandoffSnapshot {
        RecordingSegmentHandoffSnapshot(
            draftRequestID: draftRequestID,
            liveSessionID: liveSessionID,
            presetSnapshot: presetSnapshot,
            voiceProcessingConfiguration: voiceProcessingConfiguration
        )
    }

    private func clearSegmentState() {
        cancelLiveTranscription()
        cancelEndOfSpeechDetection()
        segmentRequestId = nil
        segmentModelId = nil
        segmentLanguage = nil
        segmentFlowId = nil
        segmentCompletionMode = nil
        segmentPresetSnapshot = nil
        segmentVoiceProcessingConfiguration = nil
        segmentOrigin = nil
        segmentDraftRequestID = nil
        segmentDuration = 0
        isSegmentPaused = false
        segmentPauseStartIndex = nil
        segmentPausedRanges = []
        segmentElapsedBeforePause = 0
        segmentJournalLock.withLock { journalPaused = false }
    }

    /// Cancel an active segment without transcribing.
    func cancelSegment(preserveAudioForRecovery: Bool = false) {
        guard isSegmentActive else { return }
        log.log("[PersistentRecorder] Cancelling segment")

        stopDurationTimer()
        isSegmentActive = false
        TranscriptionIPC.clearAudioLevel()
        clearCaptureLiveTranscription(requestId: segmentRequestId)
        let recoveryURL = finalizeSegmentJournal()
        if !preserveAudioForRecovery, let recoveryURL {
            try? FileManager.default.removeItem(at: recoveryURL)
        }
        clearSegmentState()
        recordingQueue.setCaptureActive(false)

        TranscriptionIPC.clearStatus()
        LiveActivityController.shared.update(isSegmentActive: false, isTranscribing: false, startedAt: nil)
        WatchRecordingController.shared.publishState()
    }

    // MARK: - Active Recording Journal

    private func startSegmentJournal(requestID: String) {
        let oldWriter = segmentJournalLock.withLock { () -> IncrementalWAVWriter? in
            let oldWriter = segmentJournalWriter
            segmentJournalWriter = nil
            journalPaused = false
            return oldWriter
        }
        if oldWriter != nil {
            segmentJournalWriteQueue.sync {}
            _ = try? oldWriter?.finalize()
        }

        guard let directory = AppConstants.recordingsDirectoryURL else { return }
        let safeRequestID = requestID
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            .prefix(80)
        let url = directory
            .appendingPathComponent("segment_active_\(safeRequestID)_\(UUID().uuidString.lowercased())")
            .appendingPathExtension("wav")
        do {
            let writer = try IncrementalWAVWriter(url: url, sampleRate: whisperSampleRate)
            segmentJournalLock.withLock { segmentJournalWriter = writer }
        } catch {
            log.log("[PersistentRecorder] ⚠️ Could not start durable recording journal: \(error.localizedDescription)")
        }
    }

    private func appendToSegmentJournal(_ samples: UnsafeBufferPointer<Float>) {
        let ownedSamples = Array(samples)
        segmentJournalLock.withLock {
            guard let writer = segmentJournalWriter, !journalPaused else { return }
            segmentJournalWriteQueue.async {
                do {
                    try writer.append(samples: ownedSamples)
                } catch {
                    KeyboardDebugLog.shared.log(
                        "[PersistentRecorder] ⚠️ Durable recording journal write failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func finalizeSegmentJournal() -> URL? {
        let writer = segmentJournalLock.withLock { () -> IncrementalWAVWriter? in
            let writer = segmentJournalWriter
            segmentJournalWriter = nil
            return writer
        }
        guard let writer else { return nil }
        segmentJournalWriteQueue.sync {}
        do {
            return try writer.finalize()
        } catch {
            log.log("[PersistentRecorder] ⚠️ Could not finalize durable recording journal: \(error.localizedDescription)")
            return writer.url
        }
    }

    // MARK: - Durable Recording Queue

    func resumeRecordingQueue(includeIdle: Bool = true) {
        recordingQueue.resume(includeIdle: includeIdle)
    }

    private func enqueueAppRecording(
        audioURL: URL,
        requestId: String,
        modelId: String,
        fallbackModelId: String? = nil,
        language: String,
        duration: TimeInterval,
        completionMode: RecordingCompletionMode,
        source: RecordingJobSource = .iOSApp,
        jobID: UUID = UUID(),
        draftRequestID: UUID? = nil,
        liveSessionID: UUID? = nil,
        fallbackRecoveryURL: URL? = nil,
        captureSource: CaptureSource? = nil,
        locationOutcome: CaptureLocationOutcome? = nil,
        presetSnapshot: CapturePreset? = nil,
        voiceProcessingConfiguration: RecordingVoiceProcessingConfiguration? = nil,
        queueConfiguration: RecordingQueueConfiguration? = nil,
        finishCaptureHandoff: Bool = false
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if finishCaptureHandoff {
                    self.recordingQueue.setCaptureActive(false)
                }
            }
            do {
                let delivery: RecordingJobDelivery
                if case .runVox = completionMode, let presetSnapshot {
                    delivery = .preset(presetSnapshot)
                } else {
                    delivery = completionMode.recordingJobDelivery
                }
                _ = try await self.recordingQueue.enqueue(
                    sourceURL: audioURL,
                    id: jobID,
                    requestID: requestId,
                    draftRequestID: draftRequestID,
                    liveSessionID: liveSessionID,
                    captureSource: captureSource,
                    locationOutcome: locationOutcome,
                    duration: duration,
                    source: source,
                    delivery: delivery,
                    voiceProcessingConfiguration: voiceProcessingConfiguration,
                    modelID: modelId,
                    fallbackModelID: fallbackModelId,
                    language: language,
                    configuration: queueConfiguration
                )
                if let fallbackRecoveryURL {
                    try? FileManager.default.removeItem(at: fallbackRecoveryURL)
                }
            } catch {
                self.lastError = String(localized: "The recording could not be queued. \(error.localizedDescription) The original audio was preserved.")
            }
        }
    }

    private func executeQueuedJob(
        _ job: RecordingJob,
        audioURL: URL,
        onProgress: @escaping RecordingJobProgressHandler
    ) async throws -> RecordingJobExecutionResult {
        guard let completionMode = RecordingCompletionMode(jobDelivery: job.delivery) else {
            throw PersistentRecordingJobError.recoveryRoutingRequired
        }
        guard !usageTracker.isAtLimit else {
            needsUnlock = true
            throw PersistentRecordingJobError.transcriptionLimitReached
        }
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "RecordingJob-\(job.id.uuidString)") { [weak self] in
            log.log("[PersistentRecorder] Recording queue background time expired for \(job.id.uuidString.prefix(8))")
            Task { @MainActor in
                self?.recordingQueue.interruptForSystemExpiration()
            }
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        let requestId = job.requestID ?? "queued-\(job.id.uuidString)"
        let flowSnapshot: CapturePreset?
        if case .preset(let preset) = job.delivery {
            flowSnapshot = preset
        } else {
            flowSnapshot = nil
        }

        isTranscribing = true
        transcribingCompletionMode = completionMode
        processingRequestId = requestId
        progressRequestId = requestId
        transcriptionProgress = nil
        lastPublishedTranscriptionPercent = nil
        lastError = nil
        lastSpeakerDiarizationSkipReason = nil
        defer {
            isTranscribing = false
            transcribingCompletionMode = nil
            if processingRequestId == requestId {
                processingRequestId = nil
                progressRequestId = nil
                transcriptionProgress = nil
                lastPublishedTranscriptionPercent = nil
            }
            finishLiveActivityAfterTranscription()
            WatchRecordingController.shared.publishState()
            // A backgrounded one-shot that kept its audio session alive for
            // this transcription ends its microphone lease here.
            if shouldAutoStopListeningAfterCurrentRecording, !isSegmentActive {
                stopListening()
            }
        }

        do {
            return try await transcribe(
                audioURL: audioURL,
                modelId: job.modelID,
                fallbackModelId: job.fallbackModelID,
                language: job.language,
                requestId: requestId,
                duration: job.duration,
                completionMode: completionMode,
                sourceAudioURL: audioURL,
                captureSource: job.captureSource,
                selectedFlowOverride: flowSnapshot,
                voiceProcessingConfiguration: job.effectiveVoiceProcessingConfiguration,
                originLocationOutcomeOverride: job.locationOutcome,
                draftRequestID: job.draftRequestID,
                liveSessionID: job.liveSessionID,
                cleanupWorkingAudio: false,
                jobProgressHandler: onProgress,
                transcriptID: job.id,
                exportedNotePath: job.exportedNotePath,
                exportedAudioPath: job.exportedAudioPath,
                audioReferenceAttachedAt: job.audioReferenceAttachedAt
            )
        } catch is CancellationError {
            lastSpeakerDiarizationSkipReason = nil
            throw CancellationError()
        } catch {
            lastSpeakerDiarizationSkipReason = nil
            lastError = "\(error.localizedDescription) The recording was preserved in the queue."
            throw error
        }
    }

    // MARK: - Transcription

    private func beginOriginLocationResolution(
        requestID: String,
        completionMode: RecordingCompletionMode,
        commandOrigin: RecordingCommand.Origin?,
        sourceOverride: CaptureSource? = nil,
        flowOverrideID: String? = nil,
        draftProfile: CapturePresetProfile? = nil,
        presetOverride: CapturePreset? = nil
    ) -> Task<CaptureRecordingOriginSnapshot?, Never>? {
        guard let source = CaptureSource.recordingSource(
                for: commandOrigin,
                overriding: sourceOverride
              ) else { return nil }
        let flow: CapturePreset
        if let presetOverride {
            flow = presetOverride
        } else { switch completionMode {
        case .runVox(let flowID):
            flow = CapturePresetStore.flow(id: flowID) ?? CapturePresetStore.selectedFlow()
        case .captureDraft:
            guard let flowOverrideID else { return nil }
            flow = CapturePresetStore.flow(id: flowOverrideID) ?? CapturePresetStore.selectedFlow()
        case .keyboardTranscription:
            return nil
        } }
        guard flow.locationPolicy.isEnabled else { return nil }
        let policy = flow.locationPolicy
        let presetID = flow.id
        guard let rootURL = AppConstants.captureDirectoryURL else {
            isResolvingLocation = true
            return Task { @MainActor [weak self] in
                defer { self?.isResolvingLocation = false }
                self?.lastError = String(localized: "Shared capture storage is unavailable.")
                return nil
            }
        }
        let store = CaptureRecordingOriginStore(rootDirectoryURL: rootURL)
        isResolvingLocation = true
        return Task { @MainActor [weak self] in
            defer { self?.isResolvingLocation = false }
            let attemptedAt = Date()
            let placeholder = CaptureRecordingOriginSnapshot(
                presetID: presetID,
                source: source,
                outcome: .unavailable(.unavailable, attemptedAt: attemptedAt)
            )
            // For draft imports, bind source, placeholder, and immutable policy
            // to the durable draft before Core Location or conversion begins.
            if let draftProfile,
               await self?.captureDraftEventHandler?(.origin(
                    source: source,
                    locationOutcome: placeholder.outcome,
                    profileSnapshot: draftProfile
               )) != true {
                self?.lastError = String(localized: "Shared capture storage is unavailable.")
                return nil
            }
            // Persist a typed stop/invocation boundary before Core Location or
            // transcription can suspend this process. If this first durable
            // write fails, do not continue with location or transcription.
            do {
                try await store.save(placeholder, recordingID: requestID)
            } catch {
                self?.lastError = String(localized: "Shared capture storage is unavailable.")
                return nil
            }
            let outcome = await CaptureLocationService().resolveLocation(
                policy: policy,
                source: source
            )
            let snapshot = CaptureRecordingOriginSnapshot(
                presetID: presetID,
                source: source,
                outcome: outcome
            )
            do {
                try await store.save(snapshot, recordingID: requestID)
                if let draftProfile,
                   await self?.captureDraftEventHandler?(.origin(
                        source: source,
                        locationOutcome: snapshot.outcome,
                        profileSnapshot: draftProfile
                   )) != true {
                    // The draft already owns the durable placeholder. Keep that
                    // origin boundary rather than allowing a later reacquisition.
                    self?.lastError = String(localized: "Shared capture storage is unavailable.")
                    return placeholder
                }
                return snapshot
            } catch {
                // The durable placeholder still fixes the origin boundary and
                // prevents a later retry from acquiring a newer location.
                self?.lastError = String(localized: "Shared capture storage is unavailable.")
                return placeholder
            }
        }
    }

    private func discardOriginLocationResolution(
        _ task: Task<CaptureRecordingOriginSnapshot?, Never>?,
        requestID: String
    ) {
        guard task != nil || AppConstants.captureDirectoryURL != nil else { return }
        task?.cancel()
        Task {
            _ = await task?.value
            guard let rootURL = AppConstants.captureDirectoryURL else { return }
            try? await CaptureRecordingOriginStore(rootDirectoryURL: rootURL)
                .remove(recordingID: requestID)
        }
    }

    private func removeOriginLocationSnapshot(requestID: String) async {
        guard let rootURL = AppConstants.captureDirectoryURL else { return }
        try? await CaptureRecordingOriginStore(rootDirectoryURL: rootURL)
            .remove(recordingID: requestID)
    }

    private func transcribe(
        audioURL: URL,
        modelId: String,
        fallbackModelId: String? = nil,
        language: String,
        requestId: String,
        duration: TimeInterval,
        completionMode: RecordingCompletionMode,
        sourceAudioURL: URL? = nil,
        resolvedResult: OnDeviceTranscriptionResult? = nil,
        usesLiveDelivery: Bool = false,
        recordingStartedAt: TimeInterval? = nil,
        transcriptionStartedAt: TimeInterval? = nil,
        originLocationTask: Task<CaptureRecordingOriginSnapshot?, Never>? = nil,
        captureSource: CaptureSource? = nil,
        captureProfile: CapturePresetProfile? = nil,
        presetSnapshot: CapturePreset? = nil,
        selectedFlowOverride: CapturePreset? = nil,
        voiceProcessingConfiguration: RecordingVoiceProcessingConfiguration? = nil,
        originLocationOutcomeOverride: CaptureLocationOutcome? = nil,
        draftRequestID: UUID? = nil,
        liveSessionID: UUID? = nil,
        cleanupWorkingAudio: Bool = true,
        jobProgressHandler: RecordingJobProgressHandler? = nil,
        transcriptID: UUID? = nil,
        exportedNotePath: String? = nil,
        exportedAudioPath: String? = nil,
        audioReferenceAttachedAt: Date? = nil
    ) async throws -> RecordingJobExecutionResult {
        osLog.notice("🔄 Transcribing audio: \(audioURL.lastPathComponent) backend=\(modelId)")
        log.log("[PersistentRecorder] Transcribing with backend \(modelId)…")

        if case .captureDraft(let attachAudio) = completionMode, attachAudio {
            guard let transcriptID else {
                throw PersistentRecordingJobError.audioStagingFailed
            }
            let staged = await captureDraftEventHandler?(.audio(
                sourceAudioURL ?? audioURL,
                draftRequestID: draftRequestID,
                deliveryID: transcriptID
            )) ?? false
            guard staged else { throw PersistentRecordingJobError.audioStagingFailed }
        }

        let selectedFlow: CapturePreset?
        if let presetSnapshot {
            selectedFlow = presetSnapshot
        } else { switch completionMode {
        case .keyboardTranscription, .captureDraft:
            selectedFlow = nil
        case .runVox(let flowID):
            selectedFlow = selectedFlowOverride
                ?? CapturePresetStore.flow(id: flowID)
                ?? CapturePresetStore.selectedFlow()
        } }
        let originSnapshot: CaptureRecordingOriginSnapshot?
        if let originLocationTask {
            originSnapshot = await originLocationTask.value
        } else if let originLocationOutcomeOverride {
            originSnapshot = CaptureRecordingOriginSnapshot(
                presetID: selectedFlow?.id ?? "",
                source: captureSource ?? .voice,
                outcome: originLocationOutcomeOverride
            )
        } else if let rootURL = AppConstants.captureDirectoryURL {
            originSnapshot = try? await CaptureRecordingOriginStore(rootDirectoryURL: rootURL)
                .load(recordingID: requestId)
        } else {
            originSnapshot = nil
        }
        if originLocationTask != nil, originSnapshot == nil {
            if case .captureDraft = completionMode,
               captureSource == .fileImport,
               let captureProfile {
                _ = await captureDraftEventHandler?(.clearOrigin(profileID: captureProfile.id))
            }
            await MainActor.run {
                self.lastError = String(localized: "Shared capture storage is unavailable.")
            }
            throw PersistentRecordingJobError.originMetadataPersistenceFailed
        }
        let originLocationOutcome = originSnapshot?.outcome
        let originCaptureSource = originSnapshot?.source ?? captureSource ?? .voice

        if case .captureDraft = completionMode,
           captureSource == .fileImport,
           let captureProfile {
            guard await captureDraftEventHandler?(.origin(
                source: .fileImport,
                locationOutcome: originLocationOutcome,
                profileSnapshot: captureProfile
            )) == true else {
                await MainActor.run {
                    self.lastError = String(localized: "Shared capture storage is unavailable.")
                }
                throw PersistentRecordingJobError.originMetadataPersistenceFailed
            }
            // The draft now owns the exact outcome and policy; remove the
            // short-lived duplicate recording journal immediately.
            await removeOriginLocationSnapshot(requestID: requestId)
        }

        let effectiveVoiceProcessingConfiguration = voiceProcessingConfiguration
            ?? selectedFlow.map(RecordingVoiceProcessingConfiguration.init(preset:))
        let identifiesSpeakers = effectiveVoiceProcessingConfiguration?.speakerDiarizationEnabled == true
        let progressHandler: TranscriptionProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                jobProgressHandler?(progress)
                self?.acceptTranscriptionProgress(
                    progress,
                    requestId: requestId,
                    completionMode: completionMode,
                    recordingStartedAt: recordingStartedAt,
                    transcriptionStartedAt: transcriptionStartedAt
                )
            }
        }

        let result: OnDeviceTranscriptionResult
        do {
            // Live Apple Speech returns text optimized for immediate insertion.
            // An opted-in speaker pass needs batch timestamps, so prefer batch
            // recognition but retain the valid live text if that optional pass
            // fails before diarization can begin.
            if let resolvedResult {
                if identifiesSpeakers {
                    do {
                        result = try await transcriptionService.transcribeResult(
                            audioURL: audioURL,
                            modelID: modelId,
                            fallbackModelID: fallbackModelId
                                ?? AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedFallbackModelKey),
                            language: language,
                            onProgress: progressHandler
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        log.log("[PersistentRecorder] ⚠️ Timestamped batch recognition failed; keeping live transcript: \(error.localizedDescription)")
                        result = resolvedResult
                    }
                } else {
                    result = resolvedResult
                }
            } else {
                result = try await transcriptionService.transcribeResult(
                    audioURL: audioURL,
                    modelID: modelId,
                    fallbackModelID: fallbackModelId
                        ?? AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedFallbackModelKey),
                    language: language,
                    onProgress: progressHandler
                )
            }
        } catch is CancellationError {
            await cancelTranscription(
                requestId: requestId,
                audioURL: audioURL,
                cleanupWorkingAudio: cleanupWorkingAudio
            )
            throw CancellationError()
        } catch {
            log.log("[PersistentRecorder] ❌ Transcription failed: \(error.localizedDescription)")
            if case .captureDraft(let attachAudio) = completionMode,
               captureSource == .fileImport,
               !attachAudio,
               let captureProfile {
                _ = await captureDraftEventHandler?(.clearOrigin(profileID: captureProfile.id))
            }
            await MainActor.run {
                self.stopAcceptingTranscriptionProgress(requestId: requestId)
                self.clearCaptureLiveTranscription(requestId: requestId)
                self.lastTranscriptionResult = nil
                self.writeErrorResponse(requestId: requestId, message: error.localizedDescription)
            }
            if cleanupWorkingAudio {
                try? FileManager.default.removeItem(at: audioURL)
                await removeOriginLocationSnapshot(requestID: requestId)
            }
            throw error
        }

        // Percentage covers ASR only. Reject queued callbacks before optional
        // diarization, formatting, enrichment, delivery, or export begins.
        await MainActor.run {
            self.stopAcceptingTranscriptionProgress(requestId: requestId)
        }

        let speakerResolution: SpeakerDiarizationResolution
        do {
            speakerResolution = try await speakerDiarizationService.resolve(
                audioURL: audioURL,
                transcription: result,
                configuration: effectiveVoiceProcessingConfiguration
            )
        } catch is CancellationError {
            await cancelTranscription(
                requestId: requestId,
                audioURL: audioURL,
                cleanupWorkingAudio: cleanupWorkingAudio
            )
            throw CancellationError()
        }
        let resolvedText = speakerResolution.text
        let speakerTurns = speakerResolution.turns
        let speakerDiarizationSkipReason = speakerResolution.skipReason
        if let speakerDiarizationSkipReason {
            log.log("[PersistentRecorder] ⚠️ Speaker identification skipped: \(speakerDiarizationSkipReason.rawValue)")
        } else if let speakerTurns {
            log.log("[PersistentRecorder] ✅ Identified \(Set(speakerTurns.map(\.speaker)).count) speakers")
        }
        await MainActor.run {
            self.lastSpeakerDiarizationSkipReason = speakerDiarizationSkipReason
        }

        let text: String? = resolvedText
        log.log("[PersistentRecorder] Result from \(result.backendName): \(resolvedText.count) chars")
        osLog.notice("✅ Transcription result: \(resolvedText.count) chars")

        // Checkpoint successful queued ASR before any requested external
        // delivery. TranscriptStore replaces by ID, and UsageTracker receipts by
        // ID, so retries are exactly-once even if delivery later fails.
        if let transcriptID, !resolvedText.isEmpty {
            try await MainActor.run {
                self.transcriptStore.add(Transcript(
                    id: transcriptID,
                    text: resolvedText,
                    date: Date(),
                    duration: duration,
                    modelUsed: result.backendName,
                    language: result.language,
                    speakerTurns: speakerTurns,
                    speakerDiarizationSkipReason: speakerDiarizationSkipReason
                ))
                if let persistenceError = self.transcriptStore.lastPersistenceError {
                    throw persistenceError
                }
                self.usageTracker.addUsage(seconds: duration, deliveryID: transcriptID)
            }
        }

        if case .captureDraft = completionMode, !resolvedText.isEmpty {
            guard let transcriptID else {
                throw PersistentRecordingJobError.transcriptStagingFailed
            }
            let saved = await captureDraftEventHandler?(.transcript(
                resolvedText,
                draftRequestID: draftRequestID,
                liveSessionID: liveSessionID,
                deliveryID: transcriptID
            )) ?? false
            guard saved else { throw PersistentRecordingJobError.transcriptStagingFailed }
        }

        let scheduledDeliveryTask: Task<Bool, Never>? = try await MainActor.run {
            var deliveryTask: Task<Bool, Never>?
            self.clearCaptureLiveTranscription(requestId: requestId)
            if let text, !text.isEmpty {
                // Only publish to the IPC channel for keyboard-initiated requests.
                // In-app recordings surface the result via `lastTranscriptionResult`;
                // writing response.json here would leave a stale file that the
                // keyboard later treats as an orphaned transcription and pastes
                // into the next text field that comes up.
                let shouldPublishToKeyboard = !requestId.hasPrefix("inapp-") && !requestId.hasPrefix("import-")
                if shouldPublishToKeyboard {
                    let response = TranscriptionResponse(
                        requestId: requestId,
                        text: text,
                        usesLiveTranscription: usesLiveDelivery ? true : nil
                    )
                    do {
                        try TranscriptionIPC.writeResponse(response)
                        log.log("[PersistentRecorder] 📤 Response written (requestId=\(requestId.prefix(8)), chars=\(text.count))")
                    } catch {
                        log.log("[PersistentRecorder] ❌ writeResponse FAILED: \(error) — preserving keyboard audio")
                        throw PersistentRecordingJobError.keyboardDeliveryFailed
                    }
                    TranscriptionIPC.postResponseNotification()
                    osLog.notice("📤 Response written and notification posted for \(requestId)")

                    TranscriptionIPC.writeStatus(RecordingStatus(
                        requestId: requestId,
                        phase: .done
                    ))
                } else {
                    TranscriptionIPC.clearStatus()
                }

                // Save one record to the unified history. Draft recordings keep
                // the raw transcript editable; explicit Preset runs preserve their
                // formatting, enrichment, and configured export behavior.
                let rawTranscript = Transcript(
                    id: transcriptID ?? UUID(),
                    text: text,
                    date: Date(),
                    duration: duration,
                    modelUsed: result.backendName,
                    language: result.language,
                    speakerTurns: speakerTurns,
                    speakerDiarizationSkipReason: speakerDiarizationSkipReason
                )
                let transcript = selectedFlow.map { TranscriptFlowFormatter.apply(flow: $0, to: rawTranscript) }
                    ?? rawTranscript
                self.transcriptStore.add(transcript)
                if let persistenceError = self.transcriptStore.lastPersistenceError {
                    throw persistenceError
                }
                self.usageTracker.addUsage(seconds: duration, deliveryID: transcriptID)
                ReviewPromptManager.shared.recordSuccessfulTranscription(
                    totalTranscriptionCount: self.transcriptStore.transcripts.count,
                    transcriptDates: self.transcriptStore.transcripts.map(\.date)
                )

                if let selectedFlow {
                    // On-device LLM enrichment (title, tags, category, cleanedText).
                    // When enrichment is enabled, we defer the file export until
                    // the enricher finishes so the exported file reflects the
                    // enriched title/tags/cleaned text. On failure or timeout, we
                    // still export whatever is in the store (raw fields).
                    let store = self.transcriptStore
                    let savedId = transcript.id
                    let initialTranscript = transcript
                    let flowForExport = selectedFlow
                let audioSourceForExport: URL? = {
                    guard flowForExport.audioSaveMode != .off else { return nil }
                    let source = sourceAudioURL ?? audioURL
                    if !cleanupWorkingAudio { return source }
                    guard let dir = AppConstants.recordingsDirectoryURL else { return nil }
                    let ext = source.pathExtension.isEmpty ? "wav" : source.pathExtension
                    let retained = dir.appendingPathComponent("export_audio_\(UUID().uuidString)").appendingPathExtension(ext)
                    do {
                        try FileManager.default.copyItem(at: source, to: retained)
                        return retained
                    } catch {
                        log.log("[PersistentRecorder] ⚠️ Could not retain audio for export: \(error)")
                        return nil
                    }
                }()
                let noteDeliveryTransactionURL = transcriptID.map {
                    self.recordingQueue.store.externalDeliveryTransactionDirectoryURL(
                        for: $0,
                        artifact: .note
                    )
                }
                let audioDeliveryTransactionURL = transcriptID.map {
                    self.recordingQueue.store.externalDeliveryTransactionDirectoryURL(
                        for: $0,
                        artifact: .audio
                    )
                }
                let audioReferenceDeliveryTransactionURL = transcriptID.map {
                    self.recordingQueue.store.externalDeliveryTransactionDirectoryURL(
                        for: $0,
                        artifact: .noteAudioReference
                    )
                }

                let runExport: @Sendable () async -> Bool = { [self] in
                    let captureDestinationID = await ConfiguredTranscriptCaptureDestinationExporter
                        .resolvedDestinationID(flow: flowForExport)
                    // Legacy exports consume this private working copy. Precise
                    // capture exports keep it until either delivery succeeds or
                    // an exact audio-bearing inbox request is durable.
                    let audioWasRequested = flowForExport.audioSaveMode != .off
                    var canRemoveRetainedAudio = !audioWasRequested
                    defer {
                        if cleanupWorkingAudio, canRemoveRetainedAudio, let audioSourceForExport {
                            try? FileManager.default.removeItem(at: audioSourceForExport)
                        }
                    }
                    let latest = await MainActor.run {
                        store.transcripts.first(where: { $0.id == savedId }) ?? initialTranscript
                    }

                    if let captureDestinationID {
                        if let exportedNotePath {
                            let checkpointedURL = URL(fileURLWithPath: exportedNotePath)
                            if FileManager.default.fileExists(atPath: checkpointedURL.path) {
                                canRemoveRetainedAudio = true
                                await MainActor.run {
                                    self.lastFileExportEvent = FileExportEvent(result: .success(checkpointedURL))
                                }
                                return true
                            }
                        }
                        do {
                            let receipt = try await ConfiguredTranscriptCaptureDestinationExporter.export(
                                transcript: latest,
                                flow: flowForExport,
                                destinationID: captureDestinationID,
                                audioSourceURL: audioSourceForExport,
                                locationOutcome: originLocationOutcome,
                                source: originCaptureSource
                            )
                            if let transcriptID {
                                try await self.recordingQueue.markExportedNote(
                                    id: transcriptID,
                                    url: receipt.noteURL
                                )
                            }
                            canRemoveRetainedAudio = true
                            if let rootURL = AppConstants.captureDirectoryURL {
                                try? await CaptureRecordingOriginStore(rootDirectoryURL: rootURL)
                                    .remove(recordingID: requestId)
                            }
                            await MainActor.run {
                                self.lastFileExportEvent = FileExportEvent(result: .success(receipt.noteURL))
                            }
                            return true
                        } catch {
                            let queuedForRetry: Bool
                            if let configuredError = error as? ConfiguredTranscriptCaptureError {
                                switch configuredError {
                                case .queuedForRetry:
                                    // The inbox owns an exact staged audio copy and
                                    // the origin-bound request metadata.
                                    canRemoveRetainedAudio = true
                                    queuedForRetry = true
                                case .locationUnavailableCancelled:
                                    canRemoveRetainedAudio = true
                                    queuedForRetry = false
                                default:
                                    queuedForRetry = false
                                }
                                if canRemoveRetainedAudio,
                                   let rootURL = AppConstants.captureDirectoryURL {
                                    try? await CaptureRecordingOriginStore(rootDirectoryURL: rootURL)
                                        .remove(recordingID: requestId)
                                }
                            } else {
                                queuedForRetry = false
                            }
                            KeyboardDebugLog.shared.log("[PersistentRecorder] ❌ Precise capture routing failed: \(error)")
                            await MainActor.run {
                                self.lastFileExportEvent = FileExportEvent(result: .failure(error.localizedDescription))
                            }
                            return queuedForRetry
                        }
                    }

                    var folderOverride: URL? = nil
                    var autoOrganizeSubfolder: String? = nil

                    if #available(iOS 26, *), FoundationModelsBackend.isAvailable {
                        let router = FoundationModelsBackend()
                        let flowHasExplicitExportFolder = flowForExport.exportSettings.usesCustomExportSettings
                            && flowForExport.exportSettings.folderBookmark != nil

                        // 1. Legacy Smart Folders: route to a user-defined destination
                        // only when the selected flow does not already specify a folder.
                        // Routing is best-effort and deadline-bounded: a stalled model
                        // session must not hang the export behind it (#11).
                        if !flowHasExplicitExportFolder, AppConstants.smartFoldersEnabled {
                            let folders = AppConstants.loadSmartFolders()
                            if !folders.isEmpty,
                               let idx = try? await withRunningTask(timeout: Self.exportRoutingTimeout, operation: {
                                   try await router.routeToFolder(transcript: latest, folders: folders)
                               }) {
                                folderOverride = folders[idx].resolveURL()
                            }
                        }

                        // 2. Auto-Organize fallback: generate a subfolder under the base export folder.
                        if folderOverride == nil, AppConstants.autoOrganizeEnabled,
                           let baseURL = TranscriptFileExporter.resolveExportFolderURL(flow: flowForExport) {
                            let needsScoping = baseURL.startAccessingSecurityScopedResource()
                            let existingFolders = (try? FileManager.default.contentsOfDirectory(
                                at: baseURL,
                                includingPropertiesForKeys: [.isDirectoryKey],
                                options: .skipsHiddenFiles
                            ).filter { url in
                                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                            }.map { $0.lastPathComponent }) ?? []
                            if needsScoping { baseURL.stopAccessingSecurityScopedResource() }

                            autoOrganizeSubfolder = try? await withRunningTask(timeout: Self.exportRoutingTimeout, operation: {
                                try await router.generateFolderName(
                                    transcript: latest,
                                    existingFolders: existingFolders
                                )
                            })
                        }
                    }

                    let checkpointedNoteURL = exportedNotePath.map(URL.init(fileURLWithPath:))
                        .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                    let url: URL
                    do {
                        if let checkpointedNoteURL {
                            url = checkpointedNoteURL
                        } else {
                            switch try TranscriptFileExporter.exportConfigured(
                                latest,
                                folderURLOverride: folderOverride,
                                autoOrganizeSubfolder: autoOrganizeSubfolder,
                                flow: flowForExport,
                                deliveryTransactionDirectoryURL: noteDeliveryTransactionURL
                            ) {
                            case .disabled:
                                if audioWasRequested {
                                    await MainActor.run {
                                        self.lastFileExportEvent = FileExportEvent(
                                            result: .failure("Audio retention is enabled, but this Preset has no export destination.")
                                        )
                                    }
                                    return false
                                }
                                return true
                            case .exported(let exportedURL):
                                url = exportedURL
                                if let transcriptID {
                                    try await self.recordingQueue.markExportedNote(
                                        id: transcriptID,
                                        url: exportedURL
                                    )
                                }
                            }
                        }
                    } catch {
                        KeyboardDebugLog.shared.log("[PersistentRecorder] ❌ File export failed: \(error)")
                        await MainActor.run {
                            self.lastFileExportEvent = FileExportEvent(result: .failure(error.localizedDescription))
                        }
                        return false
                    }

                    if let audioSourceForExport {
                        let noteFolderScopeURL = folderOverride ?? TranscriptFileExporter.resolveExportFolderURL(flow: flowForExport)
                        do {
                            let checkpointedAudioURL = exportedAudioPath.map(URL.init(fileURLWithPath:))
                            if try await CheckpointedAudioDelivery.deliver(
                                sourceAudioURL: audioSourceForExport,
                                transcriptFileURL: url,
                                flow: flowForExport,
                                transcriptFolderScopeURL: noteFolderScopeURL,
                                previouslyExportedURL: checkpointedAudioURL,
                                audioReferenceAlreadyAttached: audioReferenceAttachedAt != nil,
                                audioDeliveryTransactionDirectoryURL: audioDeliveryTransactionURL,
                                audioReferenceDeliveryTransactionDirectoryURL: audioReferenceDeliveryTransactionURL,
                                checkpointExport: { audioURL in
                                    if let transcriptID {
                                        try await self.recordingQueue.markExportedAudio(
                                            id: transcriptID,
                                            url: audioURL
                                        )
                                    }
                                },
                                checkpointReference: {
                                    if let transcriptID {
                                        try await self.recordingQueue.markAudioReferenceAttached(
                                            id: transcriptID
                                        )
                                    }
                                }
                            ) != nil {
                                canRemoveRetainedAudio = true
                            }
                        } catch {
                            KeyboardDebugLog.shared.log("[PersistentRecorder] ⚠️ Audio export failed: \(error)")
                            await MainActor.run {
                                self.lastFileExportEvent = FileExportEvent(
                                    result: .failure("The note was saved, but its audio attachment failed: \(error.localizedDescription)")
                                )
                            }
                            return false
                        }
                    }

                    if audioWasRequested && !canRemoveRetainedAudio {
                        await MainActor.run {
                            self.lastFileExportEvent = FileExportEvent(
                                result: .failure("The note was saved, but its requested audio could not be exported.")
                            )
                        }
                        return false
                    }
                    await MainActor.run {
                        self.lastFileExportEvent = FileExportEvent(result: .success(url))
                    }
                    return true
                }

                    if let enricher = self.transcriptEnricher, flowForExport.usesAIEnrichment {
                        deliveryTask = Task.detached(priority: .utility) {
                            await enricher.enrichAndUpdate(transcript: initialTranscript, flow: flowForExport, into: store)
                            return await runExport()
                        }
                    } else {
                        deliveryTask = Task.detached(priority: .utility) { await runExport() }
                    }
                }

                let analyticsMetadata: OnboardingAnalyticsModelMetadata
                if let localModel = WhisperModelInfo.availableModels.first(where: { $0.id == result.backendID }) {
                    analyticsMetadata = OnboardingAnalyticsModelMetadata(model: localModel)
                } else {
                    analyticsMetadata = OnboardingAnalyticsModelMetadata(engine: .appleSpeech, sizeBucket: .unknown)
                }
                self.trackOnboardingCompletedIfNeeded(metadata: analyticsMetadata)

                // Keyboard requests return through IPC. Do not also surface them
                // as app-owned Capture results.
                if originCaptureSource != .keyboard,
                   completionMode != .keyboardTranscription {
                    self.lastTranscriptionResult = text
                }

                log.log("[PersistentRecorder] ✅ Transcription complete: \(text.count) chars")
            } else {
                self.lastTranscriptionResult = nil
                writeErrorResponse(requestId: requestId, message: "No speech detected")
                Task { await self.removeOriginLocationSnapshot(requestID: requestId) }
            }
            return deliveryTask
        }

        if let scheduledDeliveryTask,
           await scheduledDeliveryTask.value == false {
            throw PersistentRecordingJobError.deliveryFailed
        }

        guard !resolvedText.isEmpty else {
            throw PersistentRecordingJobError.noSpeechDetected
        }
        if cleanupWorkingAudio {
            try? FileManager.default.removeItem(at: audioURL)
        }
        return RecordingJobExecutionResult(
            transcriptText: completionMode == .keyboardTranscription ? resolvedText : nil
        )
    }

    @MainActor
    private func acceptTranscriptionProgress(
        _ progress: TranscriptionProgress,
        requestId: String,
        completionMode: RecordingCompletionMode,
        recordingStartedAt: TimeInterval?,
        transcriptionStartedAt: TimeInterval?
    ) {
        guard progressRequestId == requestId else { return }
        if let current = transcriptionProgress?.exactFractionCompleted {
            guard let incoming = progress.exactFractionCompleted,
                  incoming >= current else { return }
        }
        transcriptionProgress = progress

        guard let percent = progress.wholePercentCompleted,
              percent != lastPublishedTranscriptionPercent,
              let fraction = progress.exactFractionCompleted else { return }
        lastPublishedTranscriptionPercent = percent

        if completionMode == .keyboardTranscription {
            TranscriptionIPC.writeStatus(RecordingStatus(
                requestId: requestId,
                phase: .transcribing,
                recordingStartedAt: recordingStartedAt,
                recordingStoppedAt: transcriptionStartedAt,
                transcriptionProgress: fraction
            ))
        }
        if !isSegmentActive {
            LiveActivityController.shared.update(
                isSegmentActive: false,
                isTranscribing: true,
                startedAt: nil,
                transcriptionProgress: fraction
            )
        }
    }

    @MainActor
    private func stopAcceptingTranscriptionProgress(requestId: String) {
        guard progressRequestId == requestId else { return }
        progressRequestId = nil
        transcriptionProgress = nil
        lastPublishedTranscriptionPercent = nil
        if isTranscribing && !isSegmentActive {
            LiveActivityController.shared.update(
                isSegmentActive: false,
                isTranscribing: true,
                startedAt: nil,
                transcriptionProgress: nil
            )
        }
    }

    private func cancelTranscription(
        requestId: String,
        audioURL: URL,
        cleanupWorkingAudio: Bool
    ) async {
        await MainActor.run {
            self.stopAcceptingTranscriptionProgress(requestId: requestId)
            self.clearCaptureLiveTranscription(requestId: requestId)
            self.lastTranscriptionResult = nil
            self.lastSpeakerDiarizationSkipReason = nil
            TranscriptionIPC.clearStatus()
        }
        if cleanupWorkingAudio {
            try? FileManager.default.removeItem(at: audioURL)
            await removeOriginLocationSnapshot(requestID: requestId)
        }
    }

    // MARK: - WAV Writing

    private func writeWAV(samples: [Float]) -> URL? {
        guard let dir = AppConstants.recordingsDirectoryURL else { return nil }
        let url = dir.appendingPathComponent("segment_\(UUID().uuidString).wav")

        // Convert Float32 → Int16
        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * 32767.0)
        }

        let dataSize = int16Samples.count * 2
        let fileSize = 36 + dataSize
        let sampleRate = UInt32(whisperSampleRate)

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.appendUInt32LE(UInt32(fileSize))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.appendUInt32LE(16)                    // fmt chunk size
        header.appendUInt16LE(1)                     // PCM format
        header.appendUInt16LE(1)                     // mono
        header.appendUInt32LE(sampleRate)            // sample rate
        header.appendUInt32LE(sampleRate * 2)        // byte rate
        header.appendUInt16LE(2)                     // block align
        header.appendUInt16LE(16)                    // bits per sample
        header.append(contentsOf: "data".utf8)
        header.appendUInt32LE(UInt32(dataSize))

        var fileData = header
        int16Samples.withUnsafeBufferPointer { buffer in
            fileData.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UInt8.self),
                count: dataSize
            ))
        }

        do {
            try fileData.write(to: url, options: .atomic)
            return url
        } catch {
            log.log("[PersistentRecorder] ❌ WAV write failed: \(error)")
            return nil
        }
    }

    // MARK: - IPC Command Listener

    /// High-priority queue for processing IPC commands with minimal latency.
    /// Avoids waiting for the main thread run loop when the app is backgrounded.
    private static let commandQueue = DispatchQueue(label: "com.voxboard.commandProcessing", qos: .userInteractive)

    private func registerCommandObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        // Listen for new-style commands (startSegment, stopSegment)
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let recorder = Unmanaged<PersistentRecorder>
                    .fromOpaque(observer).takeUnretainedValue()
                // Use high-priority queue to avoid main thread latency when backgrounded
                PersistentRecorder.commandQueue.async { recorder.handleCommandFromBackground() }
            },
            TranscriptionIPC.commandNotificationName,
            nil,
            .deliverImmediately
        )

        // Also listen for legacy stop commands (backward compat)
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let recorder = Unmanaged<PersistentRecorder>
                    .fromOpaque(observer).takeUnretainedValue()
                PersistentRecorder.commandQueue.async { recorder.handleCommandFromBackground() }
            },
            TranscriptionIPC.stopCommandNotificationName,
            nil,
            .deliverImmediately
        )

        log.log("[PersistentRecorder] Registered command observers")
    }

    private func unregisterCommandObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterRemoveObserver(
            center, observer,
            CFNotificationName(TranscriptionIPC.commandNotificationName),
            nil
        )
        CFNotificationCenterRemoveObserver(
            center, observer,
            CFNotificationName(TranscriptionIPC.stopCommandNotificationName),
            nil
        )
    }

    /// Darwin notifications are only a latency optimization. iOS can delay or
    /// drop them while the host is transitioning to the background, so poll the
    /// durable command file as the source of truth. The same serial queue handles
    /// notifications and polling to ensure a command is claimed only once.
    private func startCommandPolling() {
        stopCommandPolling()

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isListening else { return }
            PersistentRecorder.commandQueue.async { [weak self] in
                self?.handlePendingCommandFromPoll()
            }
        }
        commandPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopCommandPolling() {
        commandPollTimer?.invalidate()
        commandPollTimer = nil
    }

    private func handlePendingCommandFromPoll() {
        guard TranscriptionIPC.readCommand() != nil else { return }
        handleCommandFromBackground()
    }

    /// Process command on the high-priority background queue.
    /// Reads the IPC command and marks the buffer position immediately,
    /// then dispatches UI state updates to main thread.
    private func handleCommandFromBackground() {
        guard let command = TranscriptionIPC.readCommand() else {
            osLog.warning("⚠️ Command notification received but no command file found")
            return
        }

        log.log("[PersistentRecorder] Received command: \(command.action.rawValue) (requestId=\(command.requestId))")
        osLog.notice("📩 Received command: \(command.action.rawValue) requestId=\(command.requestId)")
        TranscriptionIPC.clearCommand()

        switch command.action {
        case .startSegment:
            // Dispatch to main so we can safely check & cancel any stale active segment
            // before marking the new buffer position. The 2-second pre-roll makes the
            // extra ~few-ms dispatch latency negligible.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Never infer that another active capture is stale merely because
                // a new keyboard command arrived. Cancelling here used to delete
                // the app/widget recording and its journal. Preserve the owner and
                // ask the interactive caller to finish that capture first.
                if self.isSegmentActive {
                    log.log("[PersistentRecorder] ⚠️ Rejecting overlapping start; active request remains preserved")
                    self.writeErrorResponse(
                        requestId: command.requestId,
                        message: String(localized: "Finish the current recording first")
                    )
                    return
                }
                self.handleStartSegment(command)
            }

        case .stopSegment, .stop:
            // Stop and extract need main thread for UI + transcription kickoff
            DispatchQueue.main.async { [weak self] in
                self?.handleStopSegment(command)
            }
        }
    }

    @MainActor
    private func handleCommandIfNeeded() {
        guard let command = TranscriptionIPC.readCommand() else { return }

        log.log("[PersistentRecorder] Received command: \(command.action.rawValue) (requestId=\(command.requestId))")
        TranscriptionIPC.clearCommand()

        switch command.action {
        case .startSegment:
            handleStartSegment(command)

        case .stopSegment, .stop:
            handleStopSegment(command)
        }
    }

    // MARK: - Audio Level Computation

    /// Compute RMS level from raw float samples and write to IPC (throttled).
    /// Called from the audio tap callback — must be fast.
    private func writeAudioLevelIfNeeded(_ samples: UnsafePointer<Float>, frameCount: Int) {
        // Only write levels when a segment is actively recording
        guard isSegmentActive, !isSegmentPaused else { return }

        let now = CACurrentMediaTime()
        guard now - lastLevelWriteTime >= levelWriteInterval else { return }
        lastLevelWriteTime = now

        // Compute RMS
        var sumSquares: Float = 0
        let buf = UnsafeBufferPointer(start: samples, count: frameCount)
        for sample in buf {
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameCount))

        // Normalize: typical speech RMS is 0.01–0.15, scale to 0–1 range
        // Use a gentle curve so quiet speech still shows movement
        let normalized = min(1.0, rms * 6.0)

        TranscriptionIPC.writeAudioLevel(normalized)
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        stopDurationTimer()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = Optional(self.segmentStartedAt), self.isSegmentActive else { return }
                // Paused intervals are excluded: freeze at the accumulated
                // recording time until the segment resumes.
                self.segmentDuration = self.isSegmentPaused
                    ? self.segmentElapsedBeforePause
                    : self.segmentElapsedBeforePause + Date().timeIntervalSince1970 - startedAt
            }
        }

        guard let requestId = segmentRequestId else { return }
        let maximumSegmentDuration = maximumSegmentDuration
        segmentSafetyStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(maximumSegmentDuration))
            guard !Task.isCancelled,
                  let self,
                  self.isSegmentActive,
                  self.segmentRequestId == requestId else { return }

            log.log("[PersistentRecorder] ⏹ Auto-stopping at the circular-buffer safety limit")
            self.lastError = String(localized: "Recording reached the 9:45 safety limit and was stopped automatically.")
            self.handleStopSegment(RecordingCommand(
                requestId: requestId,
                action: .stopSegment
            ))
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        segmentSafetyStopTask?.cancel()
        segmentSafetyStopTask = nil
    }

    // MARK: - Helpers

    private func writeErrorResponse(requestId: String, message: String) {
        log.log("[PersistentRecorder] ❌ \(message)")
        // In-app errors don't go through IPC — surface via `lastError` instead.
        // Writing here would leave a stale response.json the keyboard would
        // later treat as a recoverable transcription/error.
        guard !requestId.hasPrefix("inapp-") else {
            TranscriptionIPC.clearStatus()
            lastError = message
            WatchRecordingController.shared.publishState()
            return
        }
        let response = TranscriptionResponse(requestId: requestId, error: message)
        try? TranscriptionIPC.writeResponse(response)
        TranscriptionIPC.postResponseNotification()
        TranscriptionIPC.writeStatus(RecordingStatus(
            requestId: requestId,
            phase: .error,
            message: message
        ))
        WatchRecordingController.shared.publishState()
    }

    private func ensureRecordingsDirectory() {
        guard let dir = AppConstants.recordingsDirectoryURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

private enum PersistentRecordingJobError: LocalizedError, RecordingJobFailureClassifying {
    case noSpeechDetected
    case audioStagingFailed
    case transcriptStagingFailed
    case originMetadataPersistenceFailed
    case recoveryRoutingRequired
    case transcriptionLimitReached
    case deliveryFailed
    case keyboardDeliveryFailed

    var recordingJobFailureStage: RecordingJobFailureStage {
        switch self {
        case .audioStagingFailed, .transcriptStagingFailed, .deliveryFailed, .keyboardDeliveryFailed:
            return .delivery
        case .originMetadataPersistenceFailed, .recoveryRoutingRequired:
            return .storage
        case .noSpeechDetected, .transcriptionLimitReached:
            return .transcription
        }
    }

    var errorDescription: String? {
        switch self {
        case .noSpeechDetected:
            return String(localized: "No speech was detected in the recording.")
        case .audioStagingFailed:
            return String(localized: "The recording could not be attached to the Capture draft.")
        case .transcriptStagingFailed:
            return String(localized: "The transcript could not be attached to the Capture draft.")
        case .originMetadataPersistenceFailed:
            return String(localized: "Shared capture storage is unavailable.")
        case .recoveryRoutingRequired:
            return String(localized: "Choose a Capture Preset before retrying this recovered recording.")
        case .transcriptionLimitReached:
            return String(localized: "You've used your free transcription time. Unlock Vox.md to process this recording.")
        case .deliveryFailed:
            return String(localized: "The transcript was saved, but its configured destination did not finish. The source recording was preserved for retry.")
        case .keyboardDeliveryFailed:
            return String(localized: "The keyboard could not receive the transcript. The recording was preserved.")
        }
    }
}

// MARK: - Data Helpers for WAV Writing

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
