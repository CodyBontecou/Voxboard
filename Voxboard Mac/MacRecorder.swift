import AppKit
import Foundation
@preconcurrency import Speech
import UniformTypeIdentifiers
import VoxboardShared

enum MacRecordingCompletionMode: Equatable, Sendable {
    case captureDraft(attachAudio: Bool)
    case runPreset(flow: CapturePreset)
}

enum MacCaptureDraftRecordingEvent: Sendable {
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
    var recordingDuration: TimeInterval = 0
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
            lastError = "Wait for the current Capture export to finish."
            return
        }
        guard !usageTracker.isAtLimit else {
            needsUnlock = true
            lastError = "Free limit reached — unlock Vox.md to keep recording."
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
            lastError = "Could not access the microphone. Check macOS Privacy & Security settings."
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
            lastError = "No audio was captured."
            return
        }

        transcribe(
            audioURL: recordedURL,
            modelId: modelManager.selectedModelId,
            language: modelManager.selectedLanguage,
            duration: duration,
            completionMode: completionMode,
            sourceAudioURL: recordedURL
        )
    }

    func importAudioFile(
        from url: URL,
        modelManager: ModelManager,
        flowId: String,
        completionMode requestedCompletionMode: MacRecordingCompletionMode? = nil
    ) {
        guard !isRecording, !isTranscribing else {
            lastError = "Wait for the current recording to finish."
            return
        }
        guard !isExporting else {
            lastError = "Wait for the current Capture export to finish."
            return
        }
        guard !usageTracker.isAtLimit else {
            needsUnlock = true
            lastError = "Free limit reached — unlock Vox.md to import audio."
            return
        }
        guard validateSelectedModel(modelManager) else { return }
        guard let dir = AppConstants.recordingsDirectoryURL else {
            lastError = "Could not access the recordings folder."
            return
        }

        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }

        do {
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
            let completionMode = requestedCompletionMode ?? .runPreset(flow: presetSnapshot(id: flowId))

            isTranscribing = true
            lastTranscriptionResult = nil
            lastError = nil
            lastRecoveryAudioURL = nil

            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let workingURL = try AudioFileConverter.convertToWhisperWAV(
                        inputURL: sourceCopy,
                        outputURL: wavURL
                    )
                    let duration = AudioFileConverter.duration(of: workingURL)
                        ?? AudioFileConverter.duration(of: sourceCopy)
                        ?? 0
                    await self.transcribeFromBackground(
                        audioURL: workingURL,
                        modelId: modelId,
                        language: language,
                        duration: duration,
                        completionMode: completionMode,
                        sourceAudioURL: sourceCopy
                    )
                    if workingURL != sourceCopy {
                        try? FileManager.default.removeItem(at: sourceCopy)
                    }
                } catch {
                    await MainActor.run {
                        self.lastError = "Could not import audio: \(error.localizedDescription)"
                        self.lastTranscriptionResult = nil
                        self.isTranscribing = false
                    }
                    try? FileManager.default.removeItem(at: sourceCopy)
                    try? FileManager.default.removeItem(at: wavURL)
                }
            }
        } catch {
            lastError = "Could not import audio: \(error.localizedDescription)"
        }
    }

    private func presetSnapshot(id: String) -> CapturePreset {
        CapturePresetStore.flow(id: id) ?? CapturePresetStore.selectedFlow()
    }

    private func validateSelectedModel(_ modelManager: ModelManager) -> Bool {
        if modelManager.selectedModelId == TranscriptionBackendID.automatic {
            return true
        }
        guard let model = modelManager.selectedModel else {
            lastError = "Select or download a transcription model first."
            return false
        }
        guard model.isDownloaded else {
            lastError = "Download \(model.name) before recording."
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
        sourceAudioURL: URL?
    ) {
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
                sourceAudioURL: sourceAudioURL
            )
        }
    }

    private nonisolated func transcribeFromBackground(
        audioURL: URL,
        modelId: String,
        language: String,
        duration: TimeInterval,
        completionMode: MacRecordingCompletionMode,
        sourceAudioURL: URL?
    ) async {
        var hasDurableAudioCopy = false
        do {
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
                language: language
            )
            await finishSuccessfulTranscription(
                text: result.text,
                duration: duration,
                modelName: result.backendName,
                language: result.language,
                completionMode: completionMode,
                audioURL: audioURL,
                sourceAudioURL: sourceAudioURL
            )
        } catch {
            await finishWithError(
                error.localizedDescription,
                cleanupURL: hasDurableAudioCopy ? audioURL : nil,
                recoveryURL: hasDurableAudioCopy ? nil : audioURL,
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
        sourceAudioURL: URL?
    ) async {
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
                    ? "The transcript could not be saved. The recording remains attached to the Capture draft."
                    : "The transcript could not be saved. The recording was preserved so it can be recovered."
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
            lastError = "Your transcript was saved locally, but the requested audio could not be prepared. The recording was preserved for recovery."
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
            defer {
                if canRemoveRetainedAudio, let retainedAudioURL {
                    try? FileManager.default.removeItem(at: retainedAudioURL)
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
                        source: .mac
                    )
                    canRemoveRetainedAudio = true
                    await MainActor.run {
                        recorderForExport.lastExportURL = receipt.noteURL
                    }
                } catch {
                    let queuedForRetry: Bool
                    if let configuredError = error as? ConfiguredTranscriptCaptureError,
                       case .queuedForRetry = configuredError {
                        // The exporter copied the audio into the durable inbox.
                        canRemoveRetainedAudio = true
                        queuedForRetry = true
                    } else {
                        queuedForRetry = false
                    }
                    KeyboardDebugLog.shared.log("[MacRecorder] Precise capture routing failed: \(error)")
                    let shouldExposeRecovery = !canRemoveRetainedAudio
                    await MainActor.run {
                        recorderForExport.lastError = "Your transcript was saved locally. \(error.localizedDescription)"
                        recorderForExport.lastExportURL = nil
                        if shouldExposeRecovery {
                            recorderForExport.lastRecoveryAudioURL = retainedAudioURL ?? audioURL
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
                    recorderForExport.lastError = "Your transcript was saved locally, but file export failed. \(error.localizedDescription)"
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
                        recorderForExport.lastError = "The note was saved, but its audio attachment failed. \(error.localizedDescription)"
                        if shouldExposeRecovery {
                            recorderForExport.lastRecoveryAudioURL = retainedAudioURL
                        }
                    }
                }
            }

            let shouldExposeRecovery = audioWasRequested && !canRemoveRetainedAudio
            await MainActor.run {
                recorderForExport.lastExportURL = exportURL
                if shouldExposeRecovery {
                    recorderForExport.lastRecoveryAudioURL = retainedAudioURL ?? audioURL
                    if recorderForExport.lastError == nil {
                        recorderForExport.lastError = "The transcript was saved, but the requested audio could not be exported. The recording was preserved for recovery."
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
            title: "Choose Export Folder",
            message: "Vox.md needs permission to save notes for the \"\(flow.displayName)\" Capture Preset."
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
                title: "Choose Export Folder",
                message: "Vox.md needs permission to save transcript files."
              ) else {
            return
        }
        defaults.set(selection.bookmark, forKey: AppConstants.fileExportBookmarkKey)
    }

    private func requestDirectoryAccess(title: String, message: String) -> (bookmark: Data, name: String)? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "Allow"
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

private enum MacRecordingHandoffError: LocalizedError {
    case audioStagingFailed
    var errorDescription: String? { "The recording could not be attached to the Capture draft." }
}
