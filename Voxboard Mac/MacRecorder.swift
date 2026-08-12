import AppKit
import Foundation
@preconcurrency import Speech
import UniformTypeIdentifiers
import VoxboardShared

enum MacRecordingCompletionMode: Equatable, Sendable {
    case transcriptionOnly
    case captureDraft(attachAudio: Bool)
    case runPreset(flow: CapturePreset)
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
    case liveTranscript(sessionID: UUID, finalizedText: String, volatileText: String?)
    case cancelLiveTranscript
}

typealias MacCaptureDraftRecordingEventHandler = @MainActor @Sendable (MacCaptureDraftRecordingEvent) async -> Bool
typealias MacLiveTranscriptInvalidationHandler = @MainActor @Sendable (UUID) -> Void
typealias MacPendingCaptureRetryHandler = @MainActor @Sendable () async -> Void

@Observable
@MainActor
final class MacRecorder {
    var isRecording = false
    var isTranscribing = false
    var isExporting = false
    var isResolvingLocation = false
    var recordingDuration: TimeInterval = 0
    var transcriptionProgress: TranscriptionProgress?
    var lastTranscriptionResult: String?
    var lastError: String?
    var lastExportURL: URL?
    var lastRecoveryAudioURL: URL?
    var needsUnlock = false

    private let recorder = AudioRecorder()
    private let transcriptStore: TranscriptStore
    private let usageTracker: UsageTracker
    private let transcriptEnricher: TranscriptEnricher?
    private let captureDraftEventHandler: MacCaptureDraftRecordingEventHandler?
    private let liveTranscriptInvalidationHandler: MacLiveTranscriptInvalidationHandler?
    private let pendingCaptureRetryHandler: MacPendingCaptureRetryHandler?
    private let transcriptionService: OnDeviceTranscriptionService
    private var activeCompletionMode: MacRecordingCompletionMode?
    private var liveRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveRecognitionTask: SFSpeechRecognitionTask?
    private var livePreviewSessionID: UUID?
    private var acceptsLivePreview = false
    private var durationTimer: Timer?
    private var progressRequestID: UUID?

    init(
        transcriptStore: TranscriptStore,
        usageTracker: UsageTracker,
        transcriptEnricher: TranscriptEnricher? = nil,
        transcriptionService: OnDeviceTranscriptionService = OnDeviceTranscriptionService(),
        captureDraftEventHandler: MacCaptureDraftRecordingEventHandler? = nil,
        liveTranscriptInvalidationHandler: MacLiveTranscriptInvalidationHandler? = nil,
        pendingCaptureRetryHandler: MacPendingCaptureRetryHandler? = nil
    ) {
        self.transcriptStore = transcriptStore
        self.usageTracker = usageTracker
        self.transcriptEnricher = transcriptEnricher
        self.transcriptionService = transcriptionService
        self.captureDraftEventHandler = captureDraftEventHandler
        self.liveTranscriptInvalidationHandler = liveTranscriptInvalidationHandler
        self.pendingCaptureRetryHandler = pendingCaptureRetryHandler
    }

    func startRecording(
        modelManager: ModelManager,
        flowId: String,
        completionMode: MacRecordingCompletionMode? = nil
    ) {
        guard !isRecording, !isTranscribing else { return }
        guard !isExporting else {
            lastError = String(localized: "Wait for the current Capture export to finish.")
            return
        }
        guard !usageTracker.isAtLimit else {
            needsUnlock = true
            lastError = String(localized: "Free limit reached — unlock Vox.md to keep recording.")
            return
        }
        guard validateSelectedModel(modelManager) else { return }

        lastError = nil
        lastTranscriptionResult = nil
        lastRecoveryAudioURL = nil
        if recorder.startRecording() {
            activeCompletionMode = completionMode ?? .runPreset(flow: presetSnapshot(id: flowId))
            isRecording = true
            recordingDuration = 0
            startLivePreviewIfSupported(
                language: modelManager.selectedLanguage,
                completionMode: activeCompletionMode
            )
            startDurationTimer()
            CapturePresetStore.selectFlow(id: flowId)
        } else {
            lastError = String(localized: "Could not access the microphone. Check macOS Privacy & Security settings.")
        }
    }

    func stopAndTranscribe(modelManager: ModelManager, flowId: String) {
        guard isRecording else { return }
        stopDurationTimer()
        isRecording = false

        let duration = max(recordingDuration, recorder.recordingDuration)
        let completionMode = activeCompletionMode ?? .runPreset(flow: presetSnapshot(id: flowId))
        activeCompletionMode = nil
        stopLivePreview()
        guard let recordedURL = recorder.stopRecording() else {
            if case .captureDraft = completionMode {
                Task { await captureDraftEventHandler?(.cancelLiveTranscript) }
            }
            lastError = String(localized: "No audio was captured.")
            return
        }

        let originLocation = beginOriginLocationResolution(
            completionMode: completionMode,
            audioURL: recordedURL,
            source: .mac
        )
        transcribe(
            audioURL: recordedURL,
            modelId: modelManager.selectedModelId,
            language: modelManager.selectedLanguage,
            duration: duration,
            completionMode: completionMode,
            sourceAudioURL: recordedURL,
            originLocation: originLocation
        )
    }

    func importAudioFile(
        from url: URL,
        modelManager: ModelManager,
        flowId: String,
        completionMode requestedCompletionMode: MacRecordingCompletionMode? = nil
    ) {
        guard !isRecording, !isTranscribing else {
            lastError = String(localized: "Wait for the current recording to finish.")
            return
        }
        guard !isExporting else {
            lastError = String(localized: "Wait for the current Capture export to finish.")
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
            let modelId = modelManager.selectedModelId
            let language = modelManager.selectedLanguage
            let importFlow = presetSnapshot(id: flowId)
            let completionMode = requestedCompletionMode ?? .runPreset(flow: importFlow)
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
            let progressRequestID = UUID()

            self.progressRequestID = progressRequestID
            transcriptionProgress = nil
            isTranscribing = true
            lastTranscriptionResult = nil
            lastError = nil
            lastRecoveryAudioURL = nil

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
                    await self.transcribeFromBackground(
                        audioURL: workingURL,
                        modelId: modelId,
                        language: language,
                        duration: duration,
                        completionMode: completionMode,
                        sourceAudioURL: sourceCopy,
                        progressRequestID: progressRequestID,
                        originLocation: activeOriginLocation,
                        captureSource: .fileImport,
                        captureProfile: importFlow.captureProfile
                    )
                    if workingURL != sourceCopy {
                        try? FileManager.default.removeItem(at: sourceCopy)
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
                        self.lastError = String(localized: "Could not import audio: \(error.localizedDescription)")
                        self.lastTranscriptionResult = nil
                        self.isTranscribing = false
                        if self.progressRequestID == progressRequestID {
                            self.progressRequestID = nil
                            self.transcriptionProgress = nil
                        }
                    }
                    try? FileManager.default.removeItem(at: sourceCopy)
                    try? FileManager.default.removeItem(at: wavURL)
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
        guard model.isDownloaded else {
            lastError = String(localized: "Download \(model.name) before recording.")
            return false
        }
        return true
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
                    .audio(sourceAudioURL ?? audioURL)
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
            await finishSuccessfulTranscription(
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
        locationOutcome: CaptureLocationOutcome?,
        originRecordingID: String?,
        captureSource: CaptureSource
    ) async {
        if case .transcriptionOnly = completionMode {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let copied = pasteboard.setString(text, forType: .string)
            usageTracker.addUsage(seconds: duration)
            lastTranscriptionResult = text
            lastError = copied ? nil : String(localized: "The transcript was created but could not be copied to the clipboard.")
            lastRecoveryAudioURL = nil
            try? FileManager.default.removeItem(at: audioURL)
            if let sourceAudioURL, sourceAudioURL != audioURL {
                try? FileManager.default.removeItem(at: sourceAudioURL)
            }
            isTranscribing = false
            return
        }

        let rawTranscript = Transcript(text: text, duration: duration, modelUsed: modelName, language: language)

        if case .captureDraft(let attachAudio) = completionMode {
            let transcriptSaved = await captureDraftEventHandler?(.transcript(text)) ?? false
            guard transcriptSaved else {
                _ = await captureDraftEventHandler?(.cancelLiveTranscript)
                if attachAudio {
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
                return
            }
            transcriptStore.add(rawTranscript)
            usageTracker.addUsage(seconds: duration)
            lastTranscriptionResult = text
            lastError = nil
            lastRecoveryAudioURL = nil
            try? FileManager.default.removeItem(at: audioURL)
            isTranscribing = false
            return
        }

        guard case .runPreset(let flowSnapshot) = completionMode else { return }
        let selectedFlow = prepareFlowForFileExportIfNeeded(flowSnapshot)
        let transcript = TranscriptFlowFormatter.apply(flow: selectedFlow, to: rawTranscript)

        transcriptStore.add(transcript)
        usageTracker.addUsage(seconds: duration)
        lastTranscriptionResult = transcript.cleanedText ?? transcript.text
        lastError = nil
        isExporting = true
        isTranscribing = false

        let audioWasRequested = selectedFlow.audioSaveMode != .off
        let retainedAudioURL = retainAudioIfNeeded(sourceAudioURL ?? audioURL, flow: selectedFlow)
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

        Task.detached(priority: .utility) { [recorderForExport] in
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
                if canRemoveRetainedAudio, let retainedAudioURL {
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
                    }
                }
                return
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

            let exportURL: URL?
            do {
                switch try TranscriptFileExporter.exportConfigured(
                    latest,
                    folderURLOverride: folderOverride,
                    autoOrganizeSubfolder: autoOrganizeSubfolder,
                    flow: flowForExport
                ) {
                case .disabled:
                    exportURL = nil
                case .exported(let url):
                    exportURL = url
                }
            } catch {
                KeyboardDebugLog.shared.log("[MacRecorder] File export failed: \(error)")
                await MainActor.run {
                    recorderForExport.lastError = String(localized: "Your transcript was saved locally, but file export failed. \(error.localizedDescription)")
                    recorderForExport.lastExportURL = nil
                    recorderForExport.lastRecoveryAudioURL = retainedAudioURL ?? audioURL
                }
                return
            }

            if let exportURL, let retainedAudioURL {
                let noteFolderScopeURL = folderOverride ?? TranscriptFileExporter.resolveExportFolderURL(flow: flowForExport)
                do {
                    if let audioExportURL = try await AudioAttachmentExporter.exportAudioIfNeeded(
                        sourceAudioURL: retainedAudioURL,
                        transcriptFileURL: exportURL,
                        flow: flowForExport,
                        transcriptFolderScopeURL: noteFolderScopeURL
                    ) {
                        // The audio file is now durable even if inserting its
                        // Markdown reference subsequently fails.
                        canRemoveRetainedAudio = true
                        let relativePath = AudioAttachmentExporter.relativePath(from: exportURL, to: audioExportURL)
                        try TranscriptFileExporter.attachAudioReference(
                            to: exportURL,
                            relativePath: relativePath,
                            securityScopedFolderURL: noteFolderScopeURL,
                            embedInMarkdown: flowForExport.exportSettings.embedAudioInMarkdown,
                            embedPlacement: flowForExport.exportSettings.audioEmbedPlacement
                        )
                    }
                } catch {
                    KeyboardDebugLog.shared.log("[MacRecorder] Audio export failed: \(error)")
                    let shouldExposeRecovery = !canRemoveRetainedAudio
                    await MainActor.run {
                        recorderForExport.lastError = String(localized: "The note was saved, but its audio attachment failed. \(error.localizedDescription)")
                        if shouldExposeRecovery {
                            recorderForExport.lastRecoveryAudioURL = retainedAudioURL
                        }
                    }
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
        }

        if !audioWasRequested || retainedAudioURL != nil {
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
        completionMode: MacRecordingCompletionMode?
    ) {
        guard let completionMode, case .captureDraft = completionMode else { return }
        let sessionID = UUID()
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
            _ = await captureDraftEventHandler?(.cancelLiveTranscript)
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

private enum MacRecordingHandoffError: LocalizedError {
    case audioStagingFailed
    case originMetadataPersistenceFailed

    var errorDescription: String? {
        switch self {
        case .audioStagingFailed:
            return String(localized: "The recording could not be attached to the Capture draft.")
        case .originMetadataPersistenceFailed:
            return String(localized: "Shared capture storage is unavailable.")
        }
    }
}
