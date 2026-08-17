import AppKit
import Foundation
@preconcurrency import Speech
import UniformTypeIdentifiers
import VoxboardShared

enum MacRecordingCompletionMode: Equatable, Sendable {
    case transcriptionOnly
    case captureDraft(attachAudio: Bool)
    case runPreset(flow: CapturePreset)

    var recordingJobDelivery: RecordingJobDelivery {
        switch self {
        case .transcriptionOnly:
            return .clipboard
        case .captureDraft(let attachAudio):
            return .captureDraft(attachAudio: attachAudio)
        case .runPreset(let flow):
            return .preset(flow)
        }
    }

    init?(jobDelivery: RecordingJobDelivery) {
        switch jobDelivery {
        case .clipboard:
            self = .transcriptionOnly
        case .captureDraft(let attachAudio):
            self = .captureDraft(attachAudio: attachAudio)
        case .preset(let flow):
            self = .runPreset(flow: flow)
        case .keyboard, .recovery:
            return nil
        }
    }
}

private struct MacMeetingNormalizedArtifacts: Sendable {
    let microphoneURL: URL?
    let systemURL: URL?
    let mixURL: URL
}

enum MacCaptureDraftRecordingEvent: Sendable {
    case origin(
        source: CaptureSource,
        locationOutcome: CaptureLocationOutcome?,
        profileSnapshot: CapturePresetProfile
    )
    case clearOrigin(profileID: String)
    case audio(URL)
    case transcript(String)
    case audio(URL, draftRequestID: UUID?, deliveryID: UUID)
    case transcript(String, draftRequestID: UUID?, liveSessionID: UUID?, deliveryID: UUID)
    case liveTranscript(sessionID: UUID, finalizedText: String, volatileText: String?)
    case cancelLiveTranscript(sessionID: UUID?)
}

typealias MacCaptureDraftRecordingEventHandler = @MainActor @Sendable (MacCaptureDraftRecordingEvent) async -> Bool
typealias MacLiveTranscriptInvalidationHandler = @MainActor @Sendable (UUID) -> Void
typealias MacPendingCaptureRetryHandler = @MainActor @Sendable () async -> Void

@Observable
@MainActor
final class MacRecorder {
    #if DEBUG
    private static let runtimeQueuePauseAfterClaimArgument =
        "--runtime-queue-pause-after-claim"
    private static let runtimeMicrophoneCaptureArgument =
        "--runtime-microphone-capture"
    #endif

    var isRecording = false
    var isMeetingRecording = false
    var isTranscribing = false
    var isExporting = false
    var isResolvingLocation = false
    var recordingDuration: TimeInterval = 0
    var transcriptionProgress: TranscriptionProgress?
    var lastTranscriptionResult: String?
    var lastSpeakerDiarizationSkipReason: SpeakerDiarizationSkipReason?
    var lastError: String?
    var lastExportURL: URL?
    var lastRecoveryAudioURL: URL?
    var needsUnlock = false

    private let recorder = AudioRecorder()
    let meetingCapture = MacMeetingCaptureCoordinator()
    private let transcriptStore: TranscriptStore
    private let usageTracker: UsageTracker
    private let transcriptEnricher: TranscriptEnricher?
    private let captureDraftEventHandler: MacCaptureDraftRecordingEventHandler?
    private let liveTranscriptInvalidationHandler: MacLiveTranscriptInvalidationHandler?
    private let pendingCaptureRetryHandler: MacPendingCaptureRetryHandler?
    private let transcriptionService: OnDeviceTranscriptionService
    private let speakerDiarizationService: SpeakerDiarizationService
    private(set) var recordingQueue: RecordingJobQueue!
    private var activeCompletionMode: MacRecordingCompletionMode?
    private var activeVoiceProcessingConfiguration: RecordingVoiceProcessingConfiguration?
    private var activeDraftRequestID: UUID?
    private var activeRecordingJobID: UUID?
    private var liveRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveRecognitionTask: SFSpeechRecognitionTask?
    private var livePreviewSessionID: UUID?
    private var acceptsLivePreview = false
    private var durationTimer: Timer?
    private var progressRequestID: UUID?
    private var isCaptureStarting = false
    private var isMeetingCaptureFinalizing = false
    private var activeCaptureLease: RecordingJobQueue.CaptureLease?
    private var meetingWasInterruptedDuringStart = false

    init(
        transcriptStore: TranscriptStore,
        usageTracker: UsageTracker,
        transcriptEnricher: TranscriptEnricher? = nil,
        transcriptionService: OnDeviceTranscriptionService = OnDeviceTranscriptionService(),
        speakerDiarizationService: SpeakerDiarizationService = SpeakerDiarizationService(),
        captureDraftEventHandler: MacCaptureDraftRecordingEventHandler? = nil,
        liveTranscriptInvalidationHandler: MacLiveTranscriptInvalidationHandler? = nil,
        pendingCaptureRetryHandler: MacPendingCaptureRetryHandler? = nil
    ) {
        self.transcriptStore = transcriptStore
        self.usageTracker = usageTracker
        self.transcriptEnricher = transcriptEnricher
        self.transcriptionService = transcriptionService
        self.speakerDiarizationService = speakerDiarizationService
        self.captureDraftEventHandler = captureDraftEventHandler
        self.liveTranscriptInvalidationHandler = liveTranscriptInvalidationHandler
        self.pendingCaptureRetryHandler = pendingCaptureRetryHandler

        let queueRoot = AppConstants.recordingJobsDirectoryURL
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("VoxboardRecordingJobs", isDirectory: true)
        let jobStore = RecordingJobStore(rootDirectoryURL: queueRoot)
        self.recordingQueue = RecordingJobQueue(store: jobStore) { [weak self] job, audioURL, progress in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(
                MacRecorder.runtimeQueuePauseAfterClaimArgument
            ) {
                try await Task.sleep(for: .seconds(30))
                return RecordingJobExecutionResult()
            }
            #endif
            guard let self else { throw CancellationError() }
            return try await self.executeQueuedJob(job, audioURL: audioURL, onProgress: progress)
        }
        meetingCapture.interruptionHandler = { [weak self] message in
            self?.handleMeetingInterruption(message)
        }
    }

    func startMeetingRecording(
        modelManager: ModelManager,
        flowId: String,
        completionMode: MacRecordingCompletionMode,
        draftRequestID: UUID? = nil
    ) async {
        guard !isRecording, !isCaptureStarting, !isMeetingCaptureFinalizing else { return }
        isCaptureStarting = true
        defer { isCaptureStarting = false }
        guard !usageTracker.isAtLimit else {
            needsUnlock = true
            lastError = String(localized: "Free limit reached — unlock Vox.md to keep recording.")
            return
        }
        guard validateSelectedModel(modelManager) else { return }
        lastError = nil
        lastTranscriptionResult = nil
        lastRecoveryAudioURL = nil
        meetingWasInterruptedDuringStart = false
        activeCompletionMode = completionMode
        activeDraftRequestID = draftRequestID
        activeRecordingJobID = UUID()
        do {
            try await meetingCapture.presentApplicationPicker(
                delivery: completionMode.recordingJobDelivery,
                modelID: modelManager.selectedModelId,
                fallbackModelID: modelManager.preferredFallbackModelID,
                language: modelManager.selectedLanguage,
                draftRequestID: draftRequestID
            )
            guard !meetingWasInterruptedDuringStart else { return }
            isRecording = true
            isMeetingRecording = true
            activeCaptureLease = recordingQueue.beginCaptureLease()
            recordingDuration = 0
            startDurationTimer()
            CapturePresetStore.selectFlow(id: flowId)
        } catch MacMeetingCaptureCoordinator.CaptureError.pickerCancelled {
            activeCompletionMode = nil
            activeDraftRequestID = nil
            activeRecordingJobID = nil
        } catch {
            activeCompletionMode = nil
            activeDraftRequestID = nil
            activeRecordingJobID = nil
            lastError = "Meeting recording could not start: \(error.localizedDescription)"
        }
    }

    func startRecording(
        modelManager: ModelManager,
        flowId: String,
        completionMode: MacRecordingCompletionMode? = nil,
        draftRequestID: UUID? = nil
    ) {
        guard !isRecording, !isCaptureStarting, !isMeetingCaptureFinalizing else { return }
        guard !usageTracker.isAtLimit else {
            needsUnlock = true
            lastError = String(localized: "Free limit reached — unlock Vox.md to keep recording.")
            return
        }
        guard validateSelectedModel(modelManager) else { return }

        lastError = nil
        lastTranscriptionResult = nil
        lastSpeakerDiarizationSkipReason = nil
        lastRecoveryAudioURL = nil
        let selectedPreset = presetSnapshot(id: flowId)
        let resolvedCompletionMode = completionMode ?? .runPreset(flow: selectedPreset)
        if recorder.startRecording() {
            activeCompletionMode = resolvedCompletionMode
            if case .captureDraft = resolvedCompletionMode {
                activeVoiceProcessingConfiguration = RecordingVoiceProcessingConfiguration(
                    preset: selectedPreset
                )
            } else {
                activeVoiceProcessingConfiguration = nil
            }
            activeDraftRequestID = draftRequestID
            let recordingJobID = UUID()
            activeRecordingJobID = recordingJobID
            isRecording = true
            activeCaptureLease = recordingQueue.beginCaptureLease()
            recordingDuration = 0
            startLivePreviewIfSupported(
                language: modelManager.selectedLanguage,
                completionMode: activeCompletionMode,
                sessionID: recordingJobID
            )
            startDurationTimer()
            CapturePresetStore.selectFlow(id: flowId)
        } else {
            lastError = String(localized: "Could not access the microphone. Check macOS Privacy & Security settings.")
        }
    }

    func stopAndTranscribe(modelManager: ModelManager, flowId: String) {
        guard isRecording else { return }
        if isMeetingRecording {
            stopMeetingAndTranscribe(modelManager: modelManager, flowId: flowId)
            return
        }
        stopDurationTimer()
        isRecording = false

        let duration = max(recordingDuration, recorder.recordingDuration)
        let completionMode = activeCompletionMode ?? .runPreset(flow: presetSnapshot(id: flowId))
        let voiceProcessingConfiguration = activeVoiceProcessingConfiguration
        let draftRequestID = activeDraftRequestID
        let recordingJobID = activeRecordingJobID ?? UUID()
        let captureLease = activeCaptureLease
        activeCaptureLease = nil
        activeCompletionMode = nil
        activeVoiceProcessingConfiguration = nil
        activeDraftRequestID = nil
        activeRecordingJobID = nil
        stopLivePreview()
        guard let recordedURL = recorder.stopRecording() else {
            if let captureLease { recordingQueue.endCaptureLease(captureLease) }
            if case .captureDraft = completionMode {
                Task { await captureDraftEventHandler?(.cancelLiveTranscript(sessionID: recordingJobID)) }
            }
            lastError = String(localized: "No audio was captured.")
            return
        }

        guard let recordingsDirectoryURL = AppConstants.recordingsDirectoryURL else {
            lastRecoveryAudioURL = recordedURL
            lastError = String(localized: "The recording handoff could not be preserved. The original audio was preserved.")
            if let captureLease { recordingQueue.endCaptureLease(captureLease) }
            return
        }
        let modelID = modelManager.selectedModelId
        let fallbackModelID = modelManager.preferredFallbackModelID
        let language = modelManager.selectedLanguage
        let configuration = RecordingQueuePreferences.load()
        let source: RecordingJobSource = completionMode == .transcriptionOnly ? .macClipboard : .macApp
        let delivery = completionMode.recordingJobDelivery
        let stagedIntent = RecordingJobHandoffIntent(
            jobID: recordingJobID,
            audioFilename: recordedURL.lastPathComponent,
            draftRequestID: draftRequestID,
            liveSessionID: recordingJobID,
            captureSource: .mac,
            locationOutcome: {
                guard case .runPreset(let preset) = completionMode,
                      preset.locationPolicy.isEnabled else { return nil }
                return .unavailable(.unavailable, attemptedAt: Date())
            }(),
            duration: duration,
            source: source,
            delivery: delivery,
            voiceProcessingConfiguration: voiceProcessingConfiguration,
            modelID: modelID,
            fallbackModelID: fallbackModelID,
            language: language,
            configuration: configuration
        )
        do {
            try RecordingJobHandoffIntentStore(
                recordingsDirectoryURL: recordingsDirectoryURL
            ).save(stagedIntent)
        } catch {
            lastRecoveryAudioURL = recordedURL
            lastError = String(localized: "The recording handoff could not be preserved. The original audio was preserved.")
            if let captureLease { recordingQueue.endCaptureLease(captureLease) }
            return
        }
        let originLocation = beginOriginLocationResolution(
            completionMode: completionMode,
            audioURL: recordedURL,
            source: .mac
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let originSnapshot = try await originLocation?.task.value
                if originLocation != nil, originSnapshot == nil {
                    throw MacRecordingHandoffError.originMetadataPersistenceFailed
                }
                try RecordingJobHandoffIntentStore(
                    recordingsDirectoryURL: recordingsDirectoryURL
                ).save(stagedIntent.finalized(
                    audioFilename: recordedURL.lastPathComponent,
                    duration: duration,
                    captureSource: originSnapshot?.source ?? .mac,
                    locationOutcome: originSnapshot?.outcome
                ))
                self.enqueueRecording(
                    audioURL: recordedURL,
                    modelId: modelID,
                    fallbackModelId: fallbackModelID,
                    language: language,
                    duration: duration,
                    completionMode: completionMode,
                    source: source,
                    draftRequestID: draftRequestID,
                    jobID: recordingJobID,
                    liveSessionID: recordingJobID,
                    captureSource: originSnapshot?.source,
                    locationOutcome: originSnapshot?.outcome,
                    voiceProcessingConfiguration: voiceProcessingConfiguration,
                    queueConfiguration: configuration,
                    captureLease: captureLease
                )
            } catch {
                self.lastRecoveryAudioURL = recordedURL
                self.lastError = String(localized: "The recording could not be queued. \(error.localizedDescription) The original audio was preserved.")
                if let captureLease { self.recordingQueue.endCaptureLease(captureLease) }
            }
        }
    }

    func importAudioFile(
        from url: URL,
        modelManager: ModelManager,
        flowId: String,
        completionMode requestedCompletionMode: MacRecordingCompletionMode? = nil,
        draftRequestID: UUID? = nil
    ) {
        guard !isRecording, !isCaptureStarting, !isMeetingCaptureFinalizing else {
            lastError = String(localized: "Finish the current recording before importing audio.")
            return
        }
        guard !usageTracker.isAtLimit else {
            needsUnlock = true
            lastError = String(localized: "Free limit reached — unlock Vox.md to import audio.")
            return
        }
        guard validateSelectedModel(modelManager) else { return }
        guard let dir = AppConstants.recordingsDirectoryURL else {
            lastError = String(localized: "Could not access the recordings folder.")
            return
        }

        let modelId = modelManager.selectedModelId
        let fallbackModelId = modelManager.preferredFallbackModelID
        let language = modelManager.selectedLanguage
        let importFlow = presetSnapshot(id: flowId)
        let completionMode = requestedCompletionMode ?? .runPreset(flow: importFlow)
        let voiceProcessingConfiguration: RecordingVoiceProcessingConfiguration? = {
            guard case .captureDraft = completionMode else { return nil }
            return RecordingVoiceProcessingConfiguration(preset: importFlow)
        }()
        let configuration = RecordingQueuePreferences.load()
        let jobID = UUID()
        lastTranscriptionResult = nil
        lastSpeakerDiarizationSkipReason = nil
        lastError = nil
        lastRecoveryAudioURL = nil

        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }

        do {
            let recoveryOriginRecordingID: String? = {
                let selected = url.standardizedFileURL
                let appOwnedDirectory = dir.standardizedFileURL
                if selected.deletingLastPathComponent() == appOwnedDirectory {
                    return selected.lastPathComponent
                }
                guard let recoveryURL = lastRecoveryAudioURL,
                      recoveryURL.standardizedFileURL == selected else { return nil }
                return recoveryURL.lastPathComponent
            }()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let sourceExt = url.pathExtension.isEmpty ? "audio" : url.pathExtension
            let sourceCopy = dir
                .appendingPathComponent("mac_import_source_\(UUID().uuidString)")
                .appendingPathExtension(sourceExt)
            try? FileManager.default.removeItem(at: sourceCopy)
            try FileManager.default.copyItem(at: url, to: sourceCopy)

            let wavURL = dir
                .appendingPathComponent("mac_import_\(UUID().uuidString)")
                .appendingPathExtension("wav")
            let stagedIntent = RecordingJobHandoffIntent(
                    jobID: jobID,
                    audioFilename: sourceCopy.lastPathComponent,
                    draftRequestID: draftRequestID,
                    captureSource: .fileImport,
                    locationOutcome: importFlow.locationPolicy.isEnabled
                        ? .unavailable(.unavailable, attemptedAt: Date())
                        : nil,
                    duration: 0,
                    source: .importedAudio,
                    delivery: completionMode.recordingJobDelivery,
                    voiceProcessingConfiguration: voiceProcessingConfiguration,
                    modelID: modelId,
                    fallbackModelID: fallbackModelId,
                    language: language,
                    configuration: configuration
                )
            try RecordingJobHandoffIntentStore(recordingsDirectoryURL: dir).save(stagedIntent)
            let captureLease = recordingQueue.beginCaptureLease()
            // File selection is the import's origin boundary. Use the retained
            // app-owned copy as a stable journal key before conversion begins.
            let originLocation = beginOriginLocationResolution(
                completionMode: completionMode,
                audioURL: sourceCopy,
                source: .fileImport,
                flowOverride: importFlow,
                recoveryRecordingID: recoveryOriginRecordingID
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
                guard let self else { return }
                var activeOriginLocation = originLocation
                do {
                    if let disabledLocationDraftJournalTask,
                       await disabledLocationDraftJournalTask.value == false {
                        throw MacRecordingHandoffError.originMetadataPersistenceFailed
                    }
                    let originSnapshot: CaptureRecordingOriginSnapshot?
                    if let originLocation {
                        originSnapshot = try await originLocation.task.value
                        guard originSnapshot != nil else {
                            throw MacRecordingHandoffError.originMetadataPersistenceFailed
                        }
                    } else {
                        originSnapshot = nil
                    }
                    let workingURL = try AudioFileConverter.convertToWhisperWAV(
                        inputURL: sourceCopy,
                        outputURL: wavURL
                    )
                    if let originLocation,
                       let originSnapshot,
                       workingURL.lastPathComponent != originLocation.recordingID,
                       let rootURL = AppConstants.captureDirectoryURL {
                        let originStore = CaptureRecordingOriginStore(rootDirectoryURL: rootURL)
                        try await originStore.save(
                            originSnapshot,
                            recordingID: workingURL.lastPathComponent
                        )
                        try? await originStore.remove(recordingID: originLocation.recordingID)
                        if let priorRecordingID = originLocation.priorRecordingID {
                            try? await originStore.remove(recordingID: priorRecordingID)
                        }
                        activeOriginLocation = MacOriginLocationResolution(
                            recordingID: workingURL.lastPathComponent,
                            priorRecordingID: nil,
                            task: Task<CaptureRecordingOriginSnapshot?, Error> { originSnapshot }
                        )
                    }
                    let duration = AudioFileConverter.duration(of: workingURL)
                        ?? AudioFileConverter.duration(of: sourceCopy)
                        ?? 0
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
                        self.enqueueRecording(
                            audioURL: workingURL,
                            modelId: modelId,
                            fallbackModelId: fallbackModelId,
                            language: language,
                            duration: duration,
                            completionMode: completionMode,
                            source: .importedAudio,
                            draftRequestID: draftRequestID,
                            jobID: jobID,
                            captureSource: originSnapshot?.source ?? .fileImport,
                            locationOutcome: originSnapshot?.outcome,
                            voiceProcessingConfiguration: voiceProcessingConfiguration,
                            queueConfiguration: configuration,
                            captureLease: captureLease
                        )
                    }
                } catch {
                    if case .captureDraft = completionMode {
                        _ = await self.captureDraftEventHandler?(.clearOrigin(profileID: importFlow.id))
                    }
                    if let activeOriginLocation {
                        activeOriginLocation.task.cancel()
                        _ = try? await activeOriginLocation.task.value
                        if let rootURL = AppConstants.captureDirectoryURL {
                            try? await CaptureRecordingOriginStore(rootDirectoryURL: rootURL)
                                .remove(recordingID: activeOriginLocation.recordingID)
                        }
                    }
                    await MainActor.run {
                        self.lastError = String(localized: "Could not import audio: \(error.localizedDescription). The imported source was preserved.")
                        self.lastTranscriptionResult = nil
                        self.lastRecoveryAudioURL = sourceCopy
                        self.recordingQueue.endCaptureLease(captureLease)
                    }
                }
            }
        } catch {
            lastError = String(localized: "Could not import audio: \(error.localizedDescription)")
        }
    }

    private func presetSnapshot(id: String) -> CapturePreset {
        CapturePresetStore.flow(id: id) ?? CapturePresetStore.selectedFlow()
    }

    /// Journals a stop-time placeholder before requesting location, atomically
    /// replaces it with the final outcome, and reuses an existing snapshot for
    /// the same retained recording. Transcription awaits this task so a crash
    /// cannot leave a later retry free to acquire a newer location.
    private func beginOriginLocationResolution(
        completionMode: MacRecordingCompletionMode,
        audioURL: URL,
        source: CaptureSource = .mac,
        flowOverride: CapturePreset? = nil,
        recoveryRecordingID: String? = nil
    ) -> MacOriginLocationResolution? {
        let flow: CapturePreset
        if case .runPreset(let preset) = completionMode {
            flow = preset
        } else if case .captureDraft = completionMode, let flowOverride {
            flow = flowOverride
        } else {
            return nil
        }
        guard flow.locationPolicy.isEnabled else { return nil }
        let policy = flow.locationPolicy
        let presetID = flow.id
        let draftProfile: CapturePresetProfile? = {
            guard case .captureDraft = completionMode, source == .fileImport else { return nil }
            return flow.captureProfile
        }()
        let recordingID = audioURL.lastPathComponent
        guard let rootURL = AppConstants.captureDirectoryURL else {
            isResolvingLocation = true
            return MacOriginLocationResolution(
                recordingID: recordingID,
                priorRecordingID: recoveryRecordingID,
                task: Task { @MainActor [weak self] in
                    defer { self?.isResolvingLocation = false }
                    throw MacRecordingHandoffError.originMetadataPersistenceFailed
                }
            )
        }
        let store = CaptureRecordingOriginStore(rootDirectoryURL: rootURL)
        isResolvingLocation = true
        let task: Task<CaptureRecordingOriginSnapshot?, Error> = Task { @MainActor [weak self] in
            defer { self?.isResolvingLocation = false }
            if let existing = try await store.load(recordingID: recordingID) {
                if let draftProfile,
                   await self?.captureDraftEventHandler?(.origin(
                        source: existing.source,
                        locationOutcome: existing.outcome,
                        profileSnapshot: draftProfile
                   )) != true {
                    throw MacRecordingHandoffError.originMetadataPersistenceFailed
                }
                return existing
            }
            if let recoveryRecordingID,
               let recovered = try await store.load(recordingID: recoveryRecordingID),
               recovered.presetID == presetID {
                // Re-key the preserved recording before conversion. Its source
                // and origin result remain authoritative; no new lookup occurs.
                try await store.save(recovered, recordingID: recordingID)
                if let draftProfile,
                   await self?.captureDraftEventHandler?(.origin(
                        source: recovered.source,
                        locationOutcome: recovered.outcome,
                        profileSnapshot: draftProfile
                   )) != true {
                    throw MacRecordingHandoffError.originMetadataPersistenceFailed
                }
                return recovered
            }
            let attemptedAt = Date()
            let placeholder = CaptureRecordingOriginSnapshot(
                presetID: presetID,
                source: source,
                outcome: .unavailable(.unavailable, attemptedAt: attemptedAt)
            )
            if let draftProfile,
               await self?.captureDraftEventHandler?(.origin(
                    source: source,
                    locationOutcome: placeholder.outcome,
                    profileSnapshot: draftProfile
               )) != true {
                throw MacRecordingHandoffError.originMetadataPersistenceFailed
            }
            try await store.save(placeholder, recordingID: recordingID)
            let outcome = await CaptureLocationService().resolveLocation(
                policy: policy,
                source: source
            )
            let snapshot = CaptureRecordingOriginSnapshot(
                presetID: presetID,
                source: source,
                outcome: outcome
            )
            try await store.save(snapshot, recordingID: recordingID)
            if let draftProfile,
               await self?.captureDraftEventHandler?(.origin(
                    source: source,
                    locationOutcome: snapshot.outcome,
                    profileSnapshot: draftProfile
               )) != true {
                // The durable draft retains the placeholder, preventing a
                // later retry from acquiring a different location.
                return placeholder
            }
            return snapshot
        }
        return MacOriginLocationResolution(
            recordingID: recordingID,
            priorRecordingID: recoveryRecordingID,
            task: task
        )
    }

    private func validateSelectedModel(_ modelManager: ModelManager) -> Bool {
        if modelManager.selectedModelId == TranscriptionBackendID.automatic {
            return true
        }
        guard let model = modelManager.selectedModel else {
            lastError = String(localized: "Select or download a transcription model first.")
            return false
        }
        guard modelManager.isModelDownloaded(model) else {
            lastError = String(localized: "Download \(model.name) or choose an existing copy before recording.")
            return false
        }
        return true
    }

    func resumeRecordingQueue(includeIdle: Bool = true) {
        recoverInterruptedMeetingSessions()
        recordingQueue.resume(includeIdle: includeIdle)
    }

    private func recoverInterruptedMeetingSessions() {
        guard let recordings = AppConstants.recordingsDirectoryURL,
              let directories = try? FileManager.default.contentsOfDirectory(
                at: recordings,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ) else { return }
        let activeSessionDirectory = meetingCapture.activeSession?.directoryURL
        for directory in directories where isSafeMeetingDirectory(directory, under: recordings) {
            // Never reconcile the live (or finalizing) meeting: its manifest is
            // `.recording` with chunks as soon as the first chunk finalizes, so
            // it would otherwise look recoverable and its staging could be
            // normalized or cleaned while capture is still writing to it.
            if directory == activeSessionDirectory { continue }
            Task { @MainActor [weak self] in
                guard let self,
                      self.meetingCapture.activeSession?.directoryURL != directory else { return }
                await self.recoverMeetingSession(at: directory)
            }
        }
    }

    private func recoverMeetingSession(at directory: URL) async {
        guard let recordings = AppConstants.recordingsDirectoryURL,
              isSafeMeetingDirectory(directory, under: recordings) else { return }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard isSafeRegularFile(manifestURL, in: directory),
              let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONDecoder().decode(MeetingCaptureManifest.self, from: data),
              manifest.hasSafeRecoveryMetadata,
              manifest.state != .consumed,
              let delivery = manifest.delivery, let modelID = manifest.modelID, let language = manifest.language else { return }
        if recoverFinalizedChunkReceipts(into: &manifest, directory: directory) {
            try? persistMeetingManifest(manifest, to: manifestURL)
        }
        var durableExisting = recordingQueue.jobs.first(where: { $0.id == manifest.sessionID })
        if durableExisting == nil {
            let durableJobs = try? await recordingQueue.store.load(recoverInterrupted: false)
            durableExisting = durableJobs?.first(where: { $0.id == manifest.sessionID })
        }
        if let existing = durableExisting {
            manifest.state = existing.phase == .completed || existing.phase == .discarded ? .consumed : .queued
            manifest.queuedAt = manifest.queuedAt ?? Date()
            try? persistMeetingManifest(manifest, to: manifestURL)
            if manifest.state == .consumed {
                try? FileManager.default.removeItem(at: directory)
            } else {
                cleanupMeetingStagingDirectory(directory, preserving: manifestURL)
            }
            return
        }
        guard manifest.isRecoverable else { return }
        if manifest.state == .preparing || manifest.state == .recording {
            manifest.state = .interrupted
            if !manifest.warnings.contains("Recovered after Vox.md was interrupted.") { manifest.warnings.append("Recovered after Vox.md was interrupted.") }
        }
        do {
            try await normalizeAndEnqueueMeeting(manifest: &manifest, directory: directory, manifestURL: manifestURL, delivery: delivery, modelID: modelID, language: language)
        } catch {
            lastError = "An interrupted meeting remains recoverable: \(error.localizedDescription)"
        }
    }

    private func recoverFinalizedChunkReceipts(
        into manifest: inout MeetingCaptureManifest,
        directory: URL
    ) -> Bool {
        let receiptURLs = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.lastPathComponent.hasSuffix(".m4a.chunk.json") }
        var changed = false
        for receiptURL in receiptURLs {
            guard isSafeRegularFile(receiptURL, in: directory),
                  let data = try? Data(contentsOf: receiptURL),
                  let receipt = try? JSONDecoder().decode(MeetingCaptureChunkReceipt.self, from: data),
                  receiptURL.lastPathComponent == receipt.chunk.filename + ".chunk.json",
                  receipt.chunk.filename == URL(fileURLWithPath: receipt.chunk.filename).lastPathComponent,
                  receipt.chunk.startTime.isFinite,
                  receipt.chunk.endTime.isFinite,
                  receipt.chunk.startTime >= 0,
                  receipt.chunk.endTime >= receipt.chunk.startTime else { continue }
            let chunkURL = directory.appendingPathComponent(receipt.chunk.filename)
            guard isSafeRegularFile(chunkURL, in: directory),
                  let size = (try? chunkURL.resourceValues(forKeys: [.fileSizeKey]).fileSize),
                  size > 0,
                  (receipt.chunk.byteCount == 0 || UInt64(size) == receipt.chunk.byteCount),
                  (AudioFileConverter.duration(of: chunkURL) ?? 0) > 0 else { continue }
            guard !manifest.chunks.contains(where: { $0.filename == receipt.chunk.filename }) else { continue }
            var recoveredChunk = receipt.chunk
            recoveredChunk.byteCount = UInt64(size)
            manifest.chunks.append(recoveredChunk)
            manifest.events.append(contentsOf: receipt.events)
            for warning in receipt.warnings where !manifest.warnings.contains(warning) {
                manifest.warnings.append(warning)
            }
            manifest.duration = max(manifest.duration, recoveredChunk.endTime)
            changed = true
        }
        return changed
    }

    private func isSafeMeetingDirectory(_ directory: URL, under recordings: URL) -> Bool {
        guard directory.lastPathComponent.hasPrefix("meeting-"),
              directory.deletingLastPathComponent().standardizedFileURL == recordings.standardizedFileURL,
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return false }
        let resolvedRoot = recordings.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        return resolvedDirectory.deletingLastPathComponent() == resolvedRoot
    }

    private func isSafeRegularFile(_ url: URL, in directory: URL) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return false }
        return url.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()
            == directory.resolvingSymlinksInPath().standardizedFileURL
    }

    private func cleanupMeetingStagingDirectory(_ directory: URL, preserving manifestURL: URL) {
        guard let recordings = AppConstants.recordingsDirectoryURL,
              isSafeMeetingDirectory(directory, under: recordings) else { return }
        for url in (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [] where url.standardizedFileURL != manifestURL.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    #if DEBUG
    func runRuntimeMicrophoneCaptureIfRequested(modelManager: ModelManager) async {
        let processInfo = ProcessInfo.processInfo
        guard processInfo.arguments.contains(Self.runtimeMicrophoneCaptureArgument),
              processInfo.arguments.contains("--runtime-queue-validation"),
              let overridePath = processInfo.environment[
                AppConstants.debugSharedContainerOverrideEnvironmentKey
              ],
              !overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let overrideURL = Optional(
                URL(fileURLWithPath: overridePath, isDirectory: true)
                    .standardizedFileURL
              ),
              let runtimeParent = Optional(
                URL(
                    fileURLWithPath: "/tmp/VoxQueueRuntimeValidation",
                    isDirectory: true
                ).resolvingSymlinksInPath().standardizedFileURL
              ),
              overrideURL.path.hasPrefix(runtimeParent.path + "/"),
              overrideURL.resolvingSymlinksInPath().path == overrideURL.path,
              AppConstants.sharedContainerURL?.standardizedFileURL.path
                == overrideURL.path else {
            return
        }

        let microphoneGranted = await AudioRecorder.requestMicrophonePermission()
        guard microphoneGranted else {
            writeRuntimeMicrophoneCaptureResult(
                "permission-denied",
                root: overrideURL
            )
            return
        }
        modelManager.selectAutomatic()
        startRecording(
            modelManager: modelManager,
            flowId: CapturePresetStore.generalId,
            completionMode: .transcriptionOnly
        )
        guard isRecording else {
            writeRuntimeMicrophoneCaptureResult(
                "start-failed: \(lastError ?? "unknown error")",
                root: overrideURL
            )
            return
        }
        try? await Task.sleep(for: .seconds(2))
        stopAndTranscribe(
            modelManager: modelManager,
            flowId: CapturePresetStore.generalId
        )

        for _ in 0..<100 {
            let jobs = (try? await recordingQueue.store.load(
                recoverInterrupted: false
            )) ?? []
            if let job = jobs.first(where: { $0.source == .macClipboard }) {
                let audio = recordingQueue.store.audioURL(for: job)
                let size = (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 {
                    writeRuntimeMicrophoneCaptureResult(
                        "queued \(job.id.uuidString.lowercased()) \(size)",
                        root: overrideURL
                    )
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        writeRuntimeMicrophoneCaptureResult("queue-timeout", root: overrideURL)
    }

    private func writeRuntimeMicrophoneCaptureResult(_ value: String, root: URL) {
        try? Data((value + "\n").utf8).write(
            to: root.appendingPathComponent("runtime-microphone-result.txt"),
            options: .atomic
        )
    }
    #endif

    private func handleMeetingInterruption(_ message: String) {
        guard isMeetingRecording || isCaptureStarting else { return }
        if isCaptureStarting { meetingWasInterruptedDuringStart = true }
        lastError = message
        stopMeetingAndTranscribe(modelManager: nil, flowId: CapturePresetStore.selectedFlowId())
    }

    private func stopMeetingAndTranscribe(modelManager: ModelManager?, flowId: String) {
        guard !isMeetingCaptureFinalizing else { return }
        isMeetingCaptureFinalizing = true
        stopDurationTimer()
        isRecording = false
        isMeetingRecording = false
        let completionMode = activeCompletionMode ?? .runPreset(flow: presetSnapshot(id: flowId))
        let draftRequestID = activeDraftRequestID
        let captureLease = activeCaptureLease
        activeCaptureLease = nil
        activeCompletionMode = nil
        activeDraftRequestID = nil
        activeRecordingJobID = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if let captureLease { self.recordingQueue.endCaptureLease(captureLease) }
                self.isMeetingCaptureFinalizing = false
            }
            guard let result = await meetingCapture.stop() else {
                lastError = "The meeting recording could not be finalized. Any completed chunks remain in Recordings."
                return
            }
            var manifest = result.manifest
            if !manifest.warnings.isEmpty { lastError = "Incomplete meeting recording: \(manifest.warnings.joined(separator: " "))" }
            guard !manifest.chunks.isEmpty else {
                lastError = "No meeting audio was captured."
                return
            }
            do {
                try await normalizeAndEnqueueMeeting(
                    manifest: &manifest, directory: result.directoryURL, manifestURL: result.manifestURL,
                    delivery: completionMode.recordingJobDelivery,
                    modelID: modelManager?.selectedModelId ?? manifest.modelID ?? "automatic",
                    language: modelManager?.selectedLanguage ?? manifest.language ?? "en",
                    fallbackModelID: modelManager?.preferredFallbackModelID ?? manifest.fallbackModelID,
                    draftRequestID: draftRequestID
                )
            } catch {
                lastError = "The meeting was preserved but could not enter the processing queue: \(error.localizedDescription)"
            }
        }
    }

    private func normalizeAndEnqueueMeeting(
        manifest: inout MeetingCaptureManifest,
        directory: URL,
        manifestURL: URL,
        delivery: RecordingJobDelivery,
        modelID: String,
        language: String,
        fallbackModelID: String? = nil,
        draftRequestID: UUID? = nil
    ) async throws {
        manifest.state = .normalizing
        manifest.delivery = delivery
        manifest.modelID = modelID
        manifest.fallbackModelID = fallbackModelID ?? manifest.fallbackModelID
        manifest.language = language
        manifest.draftRequestID = draftRequestID ?? manifest.draftRequestID
        try persistMeetingManifest(manifest, to: manifestURL)
        let manifestSnapshot = manifest
        let normalized = try await Task.detached(priority: .userInitiated) {
            func normalize(_ source: MeetingAudioSource, name: String) throws -> URL? {
                let chunks = manifestSnapshot.orderedChunks(for: source)
                guard !chunks.isEmpty else { return nil }
                let output = directory.appendingPathComponent(name)
                return try AudioFileConverter.normalizeMeetingStem(
                    chunks: chunks.map {
                        (directory.appendingPathComponent($0.filename), $0.startTime, $0.endTime)
                    },
                    outputURL: output
                )
            }
            let microphoneURL = try normalize(.microphone, name: "microphone-normalized.wav")
            let systemURL = try normalize(.system, name: "system-normalized.wav")
            let mixURL = directory.appendingPathComponent("meeting-mix.wav")
            _ = try AudioFileConverter.mixWhisperWAVStreaming(
                microphoneURL: microphoneURL,
                systemURL: systemURL,
                outputURL: mixURL
            )
            return MacMeetingNormalizedArtifacts(
                microphoneURL: microphoneURL,
                systemURL: systemURL,
                mixURL: mixURL
            )
        }.value
        // Publish final warning/state snapshot as the queue timeline artifact.
        try persistMeetingManifest(manifest, to: manifestURL)
        var sources: [(role: RecordingArtifactRole, url: URL)] = [
            (.playbackMix, normalized.mixURL),
            (.meetingTimeline, manifestURL),
        ]
        if let microphoneURL = normalized.microphoneURL { sources.append((.meetingMicrophone, microphoneURL)) }
        if let systemURL = normalized.systemURL { sources.append((.meetingSystem, systemURL)) }
        _ = try await recordingQueue.enqueueBundle(
            sources: sources, id: manifest.sessionID, draftRequestID: manifest.draftRequestID,
            liveSessionID: manifest.sessionID, captureSource: .mac, duration: manifest.duration,
            source: .macApp, delivery: delivery, modelID: modelID,
            fallbackModelID: manifest.fallbackModelID, language: language,
            removeSourcesAfterCommit: false
        )
        // Publish the queue receipt before removing any staging member. A
        // relaunch can reconcile either side of this boundary by session ID.
        manifest.state = .queued
        manifest.queuedAt = Date()
        try persistMeetingManifest(manifest, to: manifestURL)
        cleanupMeetingStagingDirectory(directory, preserving: manifestURL)
    }

    private func persistMeetingManifest(_ manifest: MeetingCaptureManifest, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func enqueueRecording(
        audioURL: URL,
        modelId: String,
        fallbackModelId: String?,
        language: String,
        duration: TimeInterval,
        completionMode: MacRecordingCompletionMode,
        source: RecordingJobSource,
        draftRequestID: UUID? = nil,
        jobID: UUID = UUID(),
        liveSessionID: UUID? = nil,
        captureSource: CaptureSource? = nil,
        locationOutcome: CaptureLocationOutcome? = nil,
        voiceProcessingConfiguration: RecordingVoiceProcessingConfiguration? = nil,
        queueConfiguration: RecordingQueueConfiguration? = nil,
        finishCaptureHandoff: Bool = true,
        captureLease: RecordingJobQueue.CaptureLease? = nil
    ) {
        lastError = nil
        lastRecoveryAudioURL = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if finishCaptureHandoff, let captureLease {
                    self.recordingQueue.endCaptureLease(captureLease)
                }
            }
            do {
                _ = try await self.recordingQueue.enqueue(
                    sourceURL: audioURL,
                    id: jobID,
                    draftRequestID: draftRequestID,
                    liveSessionID: liveSessionID,
                    captureSource: captureSource,
                    locationOutcome: locationOutcome,
                    duration: duration,
                    source: source,
                    delivery: completionMode.recordingJobDelivery,
                    voiceProcessingConfiguration: voiceProcessingConfiguration,
                    modelID: modelId,
                    fallbackModelID: fallbackModelId,
                    language: language,
                    configuration: queueConfiguration
                )
            } catch {
                self.lastRecoveryAudioURL = audioURL
                self.lastError = String(localized: "The recording could not be queued. \(error.localizedDescription) The original audio was preserved.")
            }
        }
    }

    private func executeQueuedJob(
        _ job: RecordingJob,
        audioURL: URL,
        onProgress: @escaping RecordingJobProgressHandler
    ) async throws -> RecordingJobExecutionResult {
        guard let completionMode = MacRecordingCompletionMode(jobDelivery: job.delivery) else {
            throw MacRecordingHandoffError.recoveryRoutingRequired
        }
        guard !usageTracker.isAtLimit else {
            needsUnlock = true
            throw MacRecordingHandoffError.transcriptionLimitReached
        }
        isTranscribing = true
        lastError = nil
        lastTranscriptionResult = nil
        lastSpeakerDiarizationSkipReason = nil
        defer {
            isTranscribing = false
            transcriptionProgress = nil
        }

        var hasDurableAudioCopy = false
        if case .captureDraft(let attachAudio) = completionMode, attachAudio {
            hasDurableAudioCopy = await captureDraftEventHandler?(.audio(
                audioURL,
                draftRequestID: job.draftRequestID,
                deliveryID: job.id
            )) ?? false
            guard hasDurableAudioCopy else { throw MacRecordingHandoffError.audioStagingFailed }
        }

        do {
            if job.resolvedArtifacts.contains(where: { $0.role == .meetingMicrophone || $0.role == .meetingSystem }) {
                return try await executeMeetingJob(job, completionMode: completionMode, fallbackAudioURL: audioURL, onProgress: onProgress)
            }
            let result = try await transcriptionService.transcribeResult(
                audioURL: audioURL,
                modelID: job.modelID,
                fallbackModelID: job.fallbackModelID,
                language: job.language,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.transcriptionProgress = progress
                        onProgress(progress)
                    }
                }
            )
            let speakerResolution = try await speakerDiarizationService.resolve(
                audioURL: audioURL,
                transcription: result,
                configuration: completionMode == .transcriptionOnly
                    ? nil
                    : job.effectiveVoiceProcessingConfiguration
            )
            if let reason = speakerResolution.skipReason {
                KeyboardDebugLog.shared.log("[MacRecorder] Speaker identification skipped: \(reason.rawValue)")
            }
            lastSpeakerDiarizationSkipReason = speakerResolution.skipReason
            if completionMode == .transcriptionOnly {
                try await recordingQueue.recordTranscriptCheckpoint(
                    id: job.id,
                    text: speakerResolution.text
                )
            }
            transcriptStore.add(Transcript(
                id: job.id,
                text: speakerResolution.text,
                date: Date(),
                duration: job.duration,
                modelUsed: result.backendName,
                language: result.language,
                speakerTurns: speakerResolution.turns,
                speakerDiarizationSkipReason: speakerResolution.skipReason
            ))
            if let persistenceError = transcriptStore.lastPersistenceError {
                throw persistenceError
            }
            usageTracker.addUsage(seconds: job.duration, deliveryID: job.id)
            let shouldCopyAutomatically = completionMode == .transcriptionOnly
                && (job.initialProcessingPolicy ?? job.processingPolicy) == .immediate
                && job.automaticClipboardDeliveryAttemptedAt == nil
            if shouldCopyAutomatically {
                // Persist the attempt before touching the shared pasteboard. A
                // crash may leave explicit Copy necessary, but can never cause a
                // relaunch retry to overwrite newer clipboard contents.
                try await recordingQueue.markAutomaticClipboardDeliveryAttempted(id: job.id)
            }
            try await finishSuccessfulTranscription(
                text: speakerResolution.text,
                duration: job.duration,
                modelName: result.backendName,
                language: result.language,
                completionMode: completionMode,
                audioURL: audioURL,
                sourceAudioURL: audioURL,
                locationOutcome: job.locationOutcome,
                originRecordingID: nil,
                captureSource: job.captureSource ?? .voice,
                cleanupWorkingAudio: false,
                copiesToClipboard: shouldCopyAutomatically,
                transcriptID: job.id,
                draftRequestID: job.draftRequestID,
                liveSessionID: job.liveSessionID,
                exportedNotePath: job.exportedNotePath,
                exportedAudioPath: job.exportedAudioPath,
                audioReferenceAttachedAt: job.audioReferenceAttachedAt,
                speakerTurns: speakerResolution.turns,
                speakerDiarizationSkipReason: speakerResolution.skipReason
            )
            return RecordingJobExecutionResult(
                transcriptText: completionMode == .transcriptionOnly && !shouldCopyAutomatically
                    ? speakerResolution.text
                    : nil
            )
        } catch {
            if case .captureDraft = completionMode {
                _ = await captureDraftEventHandler?(.cancelLiveTranscript(sessionID: job.liveSessionID))
            }
            lastTranscriptionResult = nil
            lastSpeakerDiarizationSkipReason = nil
            lastRecoveryAudioURL = audioURL
            lastError = "\(error.localizedDescription) The recording was preserved in the queue."
            throw error
        }
    }

    private func executeMeetingJob(
        _ job: RecordingJob,
        completionMode: MacRecordingCompletionMode,
        fallbackAudioURL: URL,
        onProgress: @escaping RecordingJobProgressHandler
    ) async throws -> RecordingJobExecutionResult {
        let queuedArtifacts = Dictionary(
            uniqueKeysWithValues: zip(job.resolvedArtifacts.map(\.role), recordingQueue.store.artifactURLs(for: job))
        )
        func url(_ role: RecordingArtifactRole) -> URL? { queuedArtifacts[role] }
        var warnings: [String] = []
        let meetingManifest: MeetingCaptureManifest? = url(.meetingTimeline).flatMap { timelineURL in
            guard let decoded = try? JSONDecoder().decode(
                MeetingCaptureManifest.self,
                from: Data(contentsOf: timelineURL)
            ), decoded.hasSafeRecoveryMetadata else { return nil }
            return decoded
        }
        warnings.append(contentsOf: meetingManifest?.warnings ?? [])
        var units: [MeetingTimedText] = []
        var backendNames: [String] = []
        var language = job.language
        var remoteResult: OnDeviceTranscriptionResult?
        for (role, source) in [(RecordingArtifactRole.meetingMicrophone, MeetingAudioSource.microphone), (.meetingSystem, .system)] {
            guard let stem = url(role) else { warnings.append(source == .microphone ? "Microphone audio unavailable." : "System audio unavailable."); continue }
            do {
                let result = try await transcriptionService.transcribeResult(
                    audioURL: stem, modelID: job.modelID, fallbackModelID: job.fallbackModelID, language: job.language,
                    onProgress: { progress in Task { @MainActor in onProgress(progress) } }
                )
                backendNames.append(result.backendName); language = result.language
                if source == .system { remoteResult = result }
                if result.segments.isEmpty {
                    units.append(MeetingTimedText(source: source, text: result.text, startTime: 0, endTime: job.duration))
                } else if let meetingManifest {
                    units.append(contentsOf: MeetingTranscriptAssembler.mapToMeetingTimeline(
                        segments: result.segments, source: source, manifest: meetingManifest
                    ))
                } else {
                    warnings.append("Meeting timeline metadata was unavailable; source timestamps may be incomplete.")
                    units.append(contentsOf: result.segments.map { MeetingTimedText(source: source, text: $0.text, startTime: $0.startTime, endTime: $0.endTime) })
                }
            } catch { warnings.append("\(source == .microphone ? "Microphone" : "System") transcription failed: \(error.localizedDescription)") }
        }
        guard !units.isEmpty else { throw MacRecordingHandoffError.transcriptStagingFailed }
        var turns = MeetingTranscriptAssembler.turns(from: units)
        guard !turns.isEmpty else { throw MacRecordingHandoffError.transcriptStagingFailed }
        if case .runPreset(let preset) = completionMode, preset.speakerDiarizationEnabled,
           let remoteResult, let systemURL = url(.meetingSystem), !remoteResult.segments.isEmpty {
            do {
                let diarization = try await speakerDiarizationService.diarize(audioURL: systemURL, transcriptText: remoteResult.text, transcriptionSegments: remoteResult.segments)
                let remoteTurns = diarization.turns.map { turn in
                    TranscriptSpeakerTurn(speaker: turn.speaker + 1, text: turn.text, startTime: turn.startTime, endTime: turn.endTime, role: .remoteAnonymous)
                }
                turns = (turns.filter { $0.role == .local } + remoteTurns).sorted { $0.startTime < $1.startTime }
            } catch { warnings.append("Remote speaker identification was skipped: \(error.localizedDescription)") }
        }
        let rendered = MeetingTranscriptAssembler.renderedText(from: turns)
        let text = warnings.isEmpty ? rendered : "⚠️ Incomplete meeting capture: \(warnings.joined(separator: " "))\n\n\(rendered)"
        let mixURL = url(.playbackMix) ?? fallbackAudioURL
        if completionMode == .transcriptionOnly {
            try await recordingQueue.recordTranscriptCheckpoint(id: job.id, text: text)
            transcriptStore.add(Transcript(
                id: job.id,
                text: text,
                date: Date(),
                duration: job.duration,
                modelUsed: backendNames.joined(separator: " + "),
                language: language,
                speakerTurns: turns
            ))
            if let persistenceError = transcriptStore.lastPersistenceError {
                throw persistenceError
            }
        }
        let shouldCopyAutomatically = MeetingClipboardPolicy.shouldCopyAutomatically(
            delivery: job.delivery,
            initialPolicy: job.initialProcessingPolicy ?? job.processingPolicy,
            attemptedAt: job.automaticClipboardDeliveryAttemptedAt
        )
        if shouldCopyAutomatically { try await recordingQueue.markAutomaticClipboardDeliveryAttempted(id: job.id) }
        try await finishSuccessfulTranscription(
            text: text, duration: job.duration, modelName: backendNames.joined(separator: " + "), language: language,
            completionMode: completionMode, audioURL: mixURL, sourceAudioURL: mixURL, locationOutcome: job.locationOutcome,
            captureSource: .mac, cleanupWorkingAudio: false, copiesToClipboard: shouldCopyAutomatically, transcriptID: job.id,
            draftRequestID: job.draftRequestID, liveSessionID: job.liveSessionID,
            exportedNotePath: job.exportedNotePath, exportedAudioPath: job.exportedAudioPath,
            audioReferenceAttachedAt: job.audioReferenceAttachedAt, speakerTurns: turns
        )
        return RecordingJobExecutionResult(
            transcriptText: completionMode == .transcriptionOnly && !shouldCopyAutomatically ? text : nil
        )
    }

    private func transcribe(
        audioURL: URL,
        modelId: String,
        language: String,
        duration: TimeInterval,
        completionMode: MacRecordingCompletionMode,
        sourceAudioURL: URL?,
        originLocation: MacOriginLocationResolution?,
        captureSource: CaptureSource = .mac,
        captureProfile: CapturePresetProfile? = nil
    ) {
        let progressRequestID = UUID()
        self.progressRequestID = progressRequestID
        transcriptionProgress = nil
        isTranscribing = true
        lastError = nil
        lastTranscriptionResult = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.transcribeFromBackground(
                audioURL: audioURL,
                modelId: modelId,
                language: language,
                duration: duration,
                completionMode: completionMode,
                sourceAudioURL: sourceAudioURL,
                progressRequestID: progressRequestID,
                originLocation: originLocation,
                captureSource: captureSource,
                captureProfile: captureProfile
            )
        }
    }

    private nonisolated func transcribeFromBackground(
        audioURL: URL,
        modelId: String,
        language: String,
        duration: TimeInterval,
        completionMode: MacRecordingCompletionMode,
        sourceAudioURL: URL?,
        progressRequestID: UUID,
        originLocation: MacOriginLocationResolution?,
        captureSource: CaptureSource,
        captureProfile: CapturePresetProfile?
    ) async {
        var hasDurableAudioCopy = false
        do {
            // Resolve and durably journal the origin boundary before speech
            // recognition can begin.
            let originSnapshot = try await originLocation?.task.value
            let locationOutcome = originSnapshot?.outcome
            let resolvedCaptureSource = originSnapshot?.source ?? captureSource
            if case .captureDraft = completionMode,
               captureSource == .fileImport,
               let captureProfile {
                guard await captureDraftEventHandler?(.origin(
                    source: resolvedCaptureSource,
                    locationOutcome: locationOutcome,
                    profileSnapshot: captureProfile
                )) == true else {
                    throw MacRecordingHandoffError.originMetadataPersistenceFailed
                }
                if let originLocation,
                   let rootURL = AppConstants.captureDirectoryURL {
                    try? await CaptureRecordingOriginStore(rootDirectoryURL: rootURL)
                        .remove(recordingID: originLocation.recordingID)
                }
            }
            if case .captureDraft(let attachAudio) = completionMode, attachAudio {
                hasDurableAudioCopy = await captureDraftEventHandler?(
                    .audio(
                        sourceAudioURL ?? audioURL,
                        draftRequestID: nil,
                        deliveryID: UUID()
                    )
                ) ?? false
                guard hasDurableAudioCopy else { throw MacRecordingHandoffError.audioStagingFailed }
            }
            let result = try await transcriptionService.transcribeResult(
                audioURL: audioURL,
                modelID: modelId,
                fallbackModelID: AppConstants.sharedDefaults?.string(
                    forKey: AppConstants.selectedFallbackModelKey
                ),
                language: language,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.progressRequestID == progressRequestID else { return }
                        if let current = self.transcriptionProgress?.exactFractionCompleted {
                            guard let incoming = progress.exactFractionCompleted,
                                  incoming >= current else { return }
                        }
                        self.transcriptionProgress = progress
                    }
                }
            )
            await MainActor.run {
                if self.progressRequestID == progressRequestID {
                    self.progressRequestID = nil
                    self.transcriptionProgress = nil
                }
            }
            try await finishSuccessfulTranscription(
                text: result.text,
                duration: duration,
                modelName: result.backendName,
                language: result.language,
                completionMode: completionMode,
                audioURL: audioURL,
                sourceAudioURL: sourceAudioURL,
                locationOutcome: locationOutcome,
                originRecordingID: originLocation?.recordingID,
                captureSource: resolvedCaptureSource
            )
        } catch {
            if case .captureDraft = completionMode,
               captureSource == .fileImport,
               !hasDurableAudioCopy,
               let captureProfile {
                _ = await captureDraftEventHandler?(.clearOrigin(profileID: captureProfile.id))
            }
            let discardsRecording: Bool
            if case .transcriptionOnly = completionMode {
                discardsRecording = true
            } else {
                discardsRecording = false
            }
            await MainActor.run {
                if self.progressRequestID == progressRequestID {
                    self.progressRequestID = nil
                    self.transcriptionProgress = nil
                }
            }
            await finishWithError(
                error.localizedDescription,
                cleanupURL: hasDurableAudioCopy || discardsRecording ? audioURL : nil,
                recoveryURL: hasDurableAudioCopy || discardsRecording ? nil : audioURL,
                completionMode: completionMode
            )
        }
    }

    private func finishSuccessfulTranscription(
        text: String,
        duration: TimeInterval,
        modelName: String,
        language: String,
        completionMode: MacRecordingCompletionMode,
        audioURL: URL,
        sourceAudioURL: URL?,
        locationOutcome: CaptureLocationOutcome? = nil,
        originRecordingID: String? = nil,
        captureSource: CaptureSource = .voice,
        cleanupWorkingAudio: Bool = true,
        copiesToClipboard: Bool = true,
        transcriptID: UUID? = nil,
        draftRequestID: UUID? = nil,
        liveSessionID: UUID? = nil,
        exportedNotePath: String? = nil,
        exportedAudioPath: String? = nil,
        audioReferenceAttachedAt: Date? = nil,
        speakerTurns: [TranscriptSpeakerTurn]? = nil,
        speakerDiarizationSkipReason: SpeakerDiarizationSkipReason? = nil
    ) async throws {
        if case .transcriptionOnly = completionMode {
            var copied = true
            if copiesToClipboard {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                copied = pasteboard.setString(text, forType: .string)
            }
            usageTracker.addUsage(seconds: duration, deliveryID: transcriptID)
            lastTranscriptionResult = text
            guard copied else {
                lastError = String(localized: "The transcript was created but could not be copied to the clipboard. Copy it from the recording queue.")
                lastRecoveryAudioURL = audioURL
                isTranscribing = false
                throw MacRecordingHandoffError.deliveryFailed
            }
            lastError = nil
            lastRecoveryAudioURL = nil
            if cleanupWorkingAudio {
                try? FileManager.default.removeItem(at: audioURL)
                if let sourceAudioURL, sourceAudioURL != audioURL {
                    try? FileManager.default.removeItem(at: sourceAudioURL)
                }
            }
            isTranscribing = false
            return
        }

        let rawTranscript = Transcript(
            id: transcriptID ?? UUID(),
            text: text,
            date: Date(),
            duration: duration,
            modelUsed: modelName,
            language: language,
            speakerTurns: speakerTurns,
            speakerDiarizationSkipReason: speakerDiarizationSkipReason
        )

        if case .captureDraft(let attachAudio) = completionMode {
            guard let transcriptID else {
                throw MacRecordingHandoffError.transcriptStagingFailed
            }
            let transcriptSaved = await captureDraftEventHandler?(.transcript(
                text,
                draftRequestID: draftRequestID,
                liveSessionID: liveSessionID,
                deliveryID: transcriptID
            )) ?? false
            guard transcriptSaved else {
                _ = await captureDraftEventHandler?(.cancelLiveTranscript(sessionID: liveSessionID))
                if cleanupWorkingAudio, attachAudio {
                    // The staged attachment is already durable, so this working
                    // copy can be removed even though the transcript was rejected.
                    try? FileManager.default.removeItem(at: audioURL)
                    lastRecoveryAudioURL = nil
                } else {
                    lastRecoveryAudioURL = audioURL
                }
                lastError = attachAudio
                    ? String(localized: "The transcript could not be saved. The recording remains attached to the Capture draft.")
                    : String(localized: "The transcript could not be saved. The recording was preserved so it can be recovered.")
                isTranscribing = false
                throw MacRecordingHandoffError.transcriptStagingFailed
            }
            transcriptStore.add(rawTranscript)
            if let persistenceError = transcriptStore.lastPersistenceError {
                throw persistenceError
            }
            usageTracker.addUsage(seconds: duration, deliveryID: transcriptID)
            lastTranscriptionResult = text
            lastError = nil
            lastRecoveryAudioURL = nil
            if cleanupWorkingAudio {
                try? FileManager.default.removeItem(at: audioURL)
            }
            isTranscribing = false
            return
        }

        guard case .runPreset(let flowSnapshot) = completionMode else { return }
        let selectedFlow = prepareFlowForFileExportIfNeeded(flowSnapshot)
        let transcript = TranscriptFlowFormatter.apply(flow: selectedFlow, to: rawTranscript)

        transcriptStore.add(transcript)
        if let persistenceError = transcriptStore.lastPersistenceError {
            throw persistenceError
        }
        lastTranscriptionResult = transcript.cleanedText ?? transcript.text
        lastError = nil
        isExporting = true
        isTranscribing = false

        let audioWasRequested = selectedFlow.audioSaveMode != .off
        let retainedAudioURL = cleanupWorkingAudio
            ? retainAudioIfNeeded(sourceAudioURL ?? audioURL, flow: selectedFlow)
            : (audioWasRequested ? audioURL : nil)
        if audioWasRequested, retainedAudioURL == nil {
            lastRecoveryAudioURL = audioURL
            lastError = String(localized: "Your transcript was saved locally, but the requested audio could not be prepared. The recording was preserved for recovery.")
        }
        let store = transcriptStore
        let savedId = transcript.id
        let initialTranscript = transcript
        let flowForExport = selectedFlow
        let enricher = transcriptEnricher
        let recorderForExport = self
        let retryPendingCapture = pendingCaptureRetryHandler
        let noteDeliveryTransactionURL = transcriptID.map {
            recordingQueue.store.externalDeliveryTransactionDirectoryURL(
                for: $0,
                artifact: .note
            )
        }
        let audioDeliveryTransactionURL = transcriptID.map {
            recordingQueue.store.externalDeliveryTransactionDirectoryURL(
                for: $0,
                artifact: .audio
            )
        }
        let audioReferenceDeliveryTransactionURL = transcriptID.map {
            recordingQueue.store.externalDeliveryTransactionDirectoryURL(
                for: $0,
                artifact: .noteAudioReference
            )
        }

        let deliverySucceeded = await Task.detached(priority: .utility) { [recorderForExport] () -> Bool in
            defer {
                Task { @MainActor in recorderForExport.isExporting = false }
            }
            let captureDestinationID = await ConfiguredTranscriptCaptureDestinationExporter
                .resolvedDestinationID(flow: flowForExport)
            // Requested audio is removed only after a durable audio-bearing
            // Capture request or legacy file export succeeds.
            var canRemoveRetainedAudio = !audioWasRequested
            var canRemoveOriginSnapshot = false
            defer {
                if cleanupWorkingAudio, canRemoveRetainedAudio, let retainedAudioURL {
                    try? FileManager.default.removeItem(at: retainedAudioURL)
                }
                if canRemoveOriginSnapshot,
                   let originRecordingID,
                   let rootURL = AppConstants.captureDirectoryURL {
                    Task {
                        try? await CaptureRecordingOriginStore(rootDirectoryURL: rootURL)
                            .remove(recordingID: originRecordingID)
                    }
                }
            }

            if let enricher, flowForExport.usesAIEnrichment {
                await enricher.enrichAndUpdate(transcript: initialTranscript, flow: flowForExport, into: store)
            }

            let latest = await MainActor.run {
                store.transcripts.first(where: { $0.id == savedId }) ?? initialTranscript
            }

            if let captureDestinationID {
                do {
                    let receipt = try await ConfiguredTranscriptCaptureDestinationExporter.export(
                        transcript: latest,
                        flow: flowForExport,
                        destinationID: captureDestinationID,
                        audioSourceURL: retainedAudioURL,
                        locationOutcome: locationOutcome,
                        source: captureSource
                    )
                    canRemoveRetainedAudio = true
                    canRemoveOriginSnapshot = true
                    await MainActor.run {
                        recorderForExport.lastExportURL = receipt.noteURL
                    }
                    return true
                } catch {
                    let queuedForRetry: Bool
                    let canceledForLocation: Bool
                    if let configuredError = error as? ConfiguredTranscriptCaptureError {
                        switch configuredError {
                        case .queuedForRetry:
                            // The exporter copied the audio and exact outcome
                            // into the durable inbox.
                            canRemoveRetainedAudio = true
                            canRemoveOriginSnapshot = true
                            queuedForRetry = true
                            canceledForLocation = false
                        case .locationUnavailableCancelled:
                            canRemoveRetainedAudio = true
                            canRemoveOriginSnapshot = true
                            queuedForRetry = false
                            canceledForLocation = true
                        default:
                            queuedForRetry = false
                            canceledForLocation = false
                        }
                    } else {
                        queuedForRetry = false
                        canceledForLocation = false
                    }
                    KeyboardDebugLog.shared.log("[MacRecorder] Precise capture routing failed: \(error)")
                    let shouldExposeRecovery = !canRemoveRetainedAudio
                    await MainActor.run {
                        recorderForExport.lastError = canceledForLocation
                            ? String(localized: "Capture canceled because this preset requires an origin-time location.")
                            : String(localized: "Your transcript was saved locally. \(error.localizedDescription)")
                        recorderForExport.lastExportURL = nil
                        if shouldExposeRecovery {
                            recorderForExport.lastRecoveryAudioURL = retainedAudioURL ?? audioURL
                        } else if canceledForLocation {
                            recorderForExport.lastRecoveryAudioURL = nil
                        }
                    }
                    if queuedForRetry {
                        await retryPendingCapture?()
                        return true
                    }
                    return false
                }
            }

            var folderOverride: URL?
            var autoOrganizeSubfolder: String?

            if #available(macOS 26, *), FoundationModelsBackend.isAvailable {
                let router = FoundationModelsBackend()
                let flowHasExplicitExportFolder = flowForExport.exportSettings.usesCustomExportSettings
                    && flowForExport.exportSettings.folderBookmark != nil

                // Match iOS: route to legacy Smart Folders only when the
                // selected Capture Preset does not already specify an export folder.
                if !flowHasExplicitExportFolder, AppConstants.smartFoldersEnabled {
                    let folders = AppConstants.loadSmartFolders()
                    if !folders.isEmpty,
                       let idx = try? await router.routeToFolder(transcript: latest, folders: folders) {
                        folderOverride = folders[idx].resolveURL()
                    }
                }

                // Match iOS Auto-Organize: generate a subfolder beneath the
                // base export folder when no Smart Folder override won.
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

                    autoOrganizeSubfolder = try? await router.generateFolderName(
                        transcript: latest,
                        existingFolders: existingFolders
                    )
                }
            }

            let checkpointedNoteURL = exportedNotePath.map(URL.init(fileURLWithPath:))
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let exportURL: URL?
            if let checkpointedNoteURL {
                exportURL = checkpointedNoteURL
            } else {
                do {
                    switch try TranscriptFileExporter.exportConfigured(
                        latest,
                        folderURLOverride: folderOverride,
                        autoOrganizeSubfolder: autoOrganizeSubfolder,
                        flow: flowForExport,
                        deliveryTransactionDirectoryURL: noteDeliveryTransactionURL
                    ) {
                    case .disabled:
                        exportURL = nil
                    case .exported(let url):
                        exportURL = url
                        if let transcriptID {
                            try await recorderForExport.recordingQueue.markExportedNote(
                                id: transcriptID,
                                url: url
                            )
                        }
                    }
                } catch {
                    KeyboardDebugLog.shared.log("[MacRecorder] File export failed: \(error)")
                    await MainActor.run {
                        recorderForExport.lastError = String(localized: "Your transcript was saved locally, but file export failed. \(error.localizedDescription)")
                        recorderForExport.lastExportURL = nil
                        recorderForExport.lastRecoveryAudioURL = retainedAudioURL ?? audioURL
                    }
                    return false
                }
            }

            if let exportURL, let retainedAudioURL {
                let noteFolderScopeURL = folderOverride ?? TranscriptFileExporter.resolveExportFolderURL(flow: flowForExport)
                do {
                    let checkpointedAudioURL = exportedAudioPath.map(URL.init(fileURLWithPath:))
                    if try await CheckpointedAudioDelivery.deliver(
                        sourceAudioURL: retainedAudioURL,
                        transcriptFileURL: exportURL,
                        flow: flowForExport,
                        transcriptFolderScopeURL: noteFolderScopeURL,
                        previouslyExportedURL: checkpointedAudioURL,
                        audioReferenceAlreadyAttached: audioReferenceAttachedAt != nil,
                        audioDeliveryTransactionDirectoryURL: audioDeliveryTransactionURL,
                        audioReferenceDeliveryTransactionDirectoryURL: audioReferenceDeliveryTransactionURL,
                        checkpointExport: { audioExportURL in
                            // The audio file is now durable even if inserting
                            // its Markdown reference subsequently fails.
                            if let transcriptID {
                                try await recorderForExport.recordingQueue.markExportedAudio(
                                    id: transcriptID,
                                    url: audioExportURL
                                )
                            }
                        },
                        checkpointReference: {
                            if let transcriptID {
                                try await recorderForExport.recordingQueue.markAudioReferenceAttached(
                                    id: transcriptID
                                )
                            }
                        }
                    ) != nil {
                        canRemoveRetainedAudio = true
                    }
                } catch {
                    KeyboardDebugLog.shared.log("[MacRecorder] Audio export failed: \(error)")
                    await MainActor.run {
                        recorderForExport.lastError = String(localized: "The note was saved, but its audio attachment failed. \(error.localizedDescription)")
                        recorderForExport.lastRecoveryAudioURL = retainedAudioURL
                    }
                    return false
                }
            }

            canRemoveOriginSnapshot = true
            let shouldExposeRecovery = audioWasRequested && !canRemoveRetainedAudio
            await MainActor.run {
                recorderForExport.lastExportURL = exportURL
                if shouldExposeRecovery {
                    recorderForExport.lastRecoveryAudioURL = retainedAudioURL ?? audioURL
                    if recorderForExport.lastError == nil {
                        recorderForExport.lastError = String(localized: "The transcript was saved, but the requested audio could not be exported. The recording was preserved for recovery.")
                    }
                }
            }
            return !shouldExposeRecovery
        }.value

        guard deliverySucceeded else {
            throw MacRecordingHandoffError.deliveryFailed
        }
        usageTracker.addUsage(seconds: duration, deliveryID: transcriptID)

        if cleanupWorkingAudio && (!audioWasRequested || retainedAudioURL != nil) {
            try? FileManager.default.removeItem(at: audioURL)
        }
    }

    private func prepareFlowForFileExportIfNeeded(_ flow: CapturePreset) -> CapturePreset {
        guard flow.captureDestinationID == nil else { return flow }
        guard flow.exportSettings.usesCustomExportSettings else {
            prepareGlobalExportFolderIfNeeded()
            return flow
        }
        guard flow.exportSettings.exportEnabled else { return flow }
        guard resolveSecurityScopedURL(from: flow.exportSettings.folderBookmark) == nil else { return flow }
        guard let selection = requestDirectoryAccess(
            title: String(localized: "Choose Export Folder"),
            message: String(localized: "Vox.md needs permission to save notes for the \"\(flow.displayName)\" Capture Preset.")
        ) else {
            KeyboardDebugLog.shared.log("[MacRecorder] Export folder selection cancelled for flow \(flow.id)")
            return flow
        }

        var updated = flow
        updated.exportSettings.folderBookmark = selection.bookmark
        updated.exportSettings.folderName = selection.name
        saveUpdatedFlow(updated)
        return updated
    }

    private func prepareGlobalExportFolderIfNeeded() {
        guard let defaults = AppConstants.sharedDefaults,
              defaults.bool(forKey: AppConstants.fileExportEnabledKey),
              resolveSecurityScopedURL(from: defaults.data(forKey: AppConstants.fileExportBookmarkKey)) == nil,
              let selection = requestDirectoryAccess(
                title: String(localized: "Choose Export Folder"),
                message: String(localized: "Vox.md needs permission to save transcript files.")
              ) else {
            return
        }
        defaults.set(selection.bookmark, forKey: AppConstants.fileExportBookmarkKey)
    }

    private func requestDirectoryAccess(title: String, message: String) -> (bookmark: Data, name: String)? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = String(localized: "Allow")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return nil
        }
        return (bookmark, url.lastPathComponent)
    }

    private func resolveSecurityScopedURL(from bookmarkData: Data?) -> URL? {
        guard let bookmarkData,
              let resolution = try? CaptureBookmarkResolver.resolve(bookmarkData),
              !resolution.isStale else { return nil }
        return resolution.url
    }

    private func saveUpdatedFlow(_ updated: CapturePreset) {
        var flows = CapturePresetStore.loadFlows()
        if let index = flows.firstIndex(where: { $0.id == updated.id }) {
            // The recording uses an immutable preset snapshot. Persist only
            // the newly granted folder access so concurrent Settings edits are
            // not overwritten by that older snapshot.
            flows[index].exportSettings.folderBookmark = updated.exportSettings.folderBookmark
            flows[index].exportSettings.folderName = updated.exportSettings.folderName
        } else {
            flows.append(updated)
        }
        CapturePresetStore.saveFlows(flows)
    }

    private func retainAudioIfNeeded(_ sourceURL: URL, flow: CapturePreset) -> URL? {
        guard flow.audioSaveMode != .off,
              let dir = AppConstants.recordingsDirectoryURL else {
            return nil
        }
        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let retained = dir.appendingPathComponent("mac_export_audio_\(UUID().uuidString)").appendingPathExtension(ext)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: retained)
            return retained
        } catch {
            KeyboardDebugLog.shared.log("[MacRecorder] Could not retain audio for export: \(error)")
            return nil
        }
    }

    private func startLivePreviewIfSupported(
        language: String,
        completionMode: MacRecordingCompletionMode?,
        sessionID: UUID
    ) {
        guard let completionMode, case .captureDraft = completionMode else { return }
        livePreviewSessionID = sessionID
        Task { @MainActor [weak self] in
            guard let self, self.livePreviewSessionID == sessionID else { return }
            let status: SFSpeechRecognizerAuthorizationStatus
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                status = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                }
            } else {
                status = SFSpeechRecognizer.authorizationStatus()
            }
            guard status == .authorized,
                  self.isRecording,
                  self.livePreviewSessionID == sessionID else { return }

            let locale = language == "auto" || language.isEmpty
                ? Locale.current
                : Locale(identifier: language)
            guard let recognizer = SFSpeechRecognizer(locale: locale),
                  recognizer.isAvailable,
                  recognizer.supportsOnDeviceRecognition else { return }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            self.liveRecognitionRequest = request
            self.acceptsLivePreview = true
            self.liveRecognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
                guard let result else { return }
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                let isFinal = result.isFinal
                Task { @MainActor [weak self] in
                    guard let self,
                          self.acceptsLivePreview,
                          self.livePreviewSessionID == sessionID else { return }
                    _ = await self.captureDraftEventHandler?(.liveTranscript(
                        sessionID: sessionID,
                        finalizedText: isFinal ? text : "",
                        volatileText: isFinal ? nil : text
                    ))
                }
            }
            self.recorder.audioBufferHandler = { [weak request] buffer in
                request?.append(buffer)
            }
        }
    }

    private func stopLivePreview() {
        let invalidatedSessionID = livePreviewSessionID
        livePreviewSessionID = nil
        acceptsLivePreview = false
        recorder.audioBufferHandler = nil
        liveRecognitionRequest?.endAudio()
        liveRecognitionTask?.cancel()
        liveRecognitionRequest = nil
        liveRecognitionTask = nil
        if let invalidatedSessionID {
            liveTranscriptInvalidationHandler?(invalidatedSessionID)
        }
    }

    private func finishWithError(
        _ message: String,
        cleanupURL: URL?,
        recoveryURL: URL?,
        completionMode: MacRecordingCompletionMode
    ) async {
        if case .captureDraft = completionMode {
            _ = await captureDraftEventHandler?(.cancelLiveTranscript(sessionID: nil))
        }
        await MainActor.run {
            self.isTranscribing = false
            self.lastTranscriptionResult = nil
            self.lastRecoveryAudioURL = recoveryURL
            self.lastError = recoveryURL == nil
                ? message
                : "\(message) The recording was preserved so it can be recovered."
        }
        if let cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) }
    }

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordingDuration = self.recorder.recordingDuration
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
}

private struct MacOriginLocationResolution: Sendable {
    let recordingID: String
    let priorRecordingID: String?
    let task: Task<CaptureRecordingOriginSnapshot?, Error>
}

private enum MacRecordingHandoffError: LocalizedError, RecordingJobFailureClassifying {
    case audioStagingFailed
    case originMetadataPersistenceFailed
    case transcriptStagingFailed
    case recoveryRoutingRequired
    case transcriptionLimitReached
    case deliveryFailed

    var recordingJobFailureStage: RecordingJobFailureStage {
        switch self {
        case .audioStagingFailed, .transcriptStagingFailed, .deliveryFailed:
            return .delivery
        case .originMetadataPersistenceFailed, .recoveryRoutingRequired:
            return .storage
        case .transcriptionLimitReached:
            return .transcription
        }
    }

    var errorDescription: String? {
        switch self {
        case .audioStagingFailed:
            return String(localized: "The recording could not be attached to the Capture draft.")
        case .originMetadataPersistenceFailed:
            return String(localized: "Shared capture storage is unavailable.")
        case .transcriptStagingFailed:
            return String(localized: "The transcript could not be attached to the Capture draft.")
        case .recoveryRoutingRequired:
            return String(localized: "Choose a Capture Preset before retrying this recovered recording.")
        case .transcriptionLimitReached:
            return String(localized: "You've used your free transcription time. Unlock Vox.md to process this recording.")
        case .deliveryFailed:
            return String(localized: "The transcript was saved, but its configured destination did not finish. The source recording was preserved for retry.")
        }
    }
}
