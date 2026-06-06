import AppKit
import Foundation
import UniformTypeIdentifiers
import VoxboardShared

@Observable
@MainActor
final class MacRecorder {
    var isRecording = false
    var isTranscribing = false
    var recordingDuration: TimeInterval = 0
    var lastTranscriptionResult: String?
    var lastError: String?
    var lastExportURL: URL?
    var needsUnlock = false

    private let recorder = AudioRecorder()
    private let transcriptStore: TranscriptStore
    private let usageTracker: UsageTracker
    private let transcriptEnricher: TranscriptEnricher?
    private var durationTimer: Timer?
    private var cachedWhisperContext: WhisperContext?
    private var cachedModelId: String?
    private var cachedParakeetContext: ParakeetContext?
    private var cachedParakeetEngine: ModelEngine?

    init(
        transcriptStore: TranscriptStore,
        usageTracker: UsageTracker,
        transcriptEnricher: TranscriptEnricher? = nil
    ) {
        self.transcriptStore = transcriptStore
        self.usageTracker = usageTracker
        self.transcriptEnricher = transcriptEnricher
    }

    func startRecording(modelManager: ModelManager, flowId: String) {
        guard !isRecording, !isTranscribing else { return }
        guard !usageTracker.isAtLimit else {
            needsUnlock = true
            lastError = "Free limit reached — unlock Voxboard to keep recording."
            return
        }
        guard validateSelectedModel(modelManager.selectedModel) else { return }

        lastError = nil
        lastTranscriptionResult = nil
        if recorder.startRecording() {
            isRecording = true
            recordingDuration = 0
            startDurationTimer()
            RecordingFlowStore.selectFlow(id: flowId)
        } else {
            lastError = "Could not access the microphone. Check macOS Privacy & Security settings."
        }
    }

    func stopAndTranscribe(modelManager: ModelManager, flowId: String) {
        guard isRecording else { return }
        stopDurationTimer()
        isRecording = false

        let duration = max(recordingDuration, recorder.recordingDuration)
        guard let audioURL = recorder.stopRecording() else {
            lastError = "No audio was captured."
            return
        }

        transcribe(
            audioURL: audioURL,
            modelId: modelManager.selectedModelId,
            language: modelManager.selectedLanguage,
            duration: duration,
            flowId: flowId,
            sourceAudioURL: audioURL
        )
    }

    func importAudioFile(from url: URL, modelManager: ModelManager, flowId: String) {
        guard !isRecording, !isTranscribing else {
            lastError = "Wait for the current recording to finish."
            return
        }
        guard !usageTracker.isAtLimit else {
            needsUnlock = true
            lastError = "Free limit reached — unlock Voxboard to import audio."
            return
        }
        guard validateSelectedModel(modelManager.selectedModel) else { return }
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

            isTranscribing = true
            lastTranscriptionResult = nil
            lastError = nil

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
                        flowId: flowId,
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

    private func validateSelectedModel(_ model: WhisperModelInfo?) -> Bool {
        guard let model else {
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
        flowId: String,
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
                flowId: flowId,
                sourceAudioURL: sourceAudioURL
            )
        }
    }

    private nonisolated func transcribeFromBackground(
        audioURL: URL,
        modelId: String,
        language: String,
        duration: TimeInterval,
        flowId: String,
        sourceAudioURL: URL?
    ) async {
        guard let model = WhisperModelInfo.availableModels.first(where: { $0.id == modelId }),
              model.isDownloaded else {
            await finishWithError("Model not found. Download a model first.", cleanupURL: audioURL)
            return
        }

        let text: String?
        if model.engine.isParakeet {
            guard let context = await parakeetContext(for: model) else {
                await finishWithError("Failed to load Parakeet model.", cleanupURL: audioURL)
                return
            }
            text = await context.transcribe(audioURL: audioURL)
        } else {
            guard let modelPath = model.localURL?.path else {
                await finishWithError("Model not found. Download a model first.", cleanupURL: audioURL)
                return
            }
            guard let context = await whisperContext(modelPath: modelPath, modelId: modelId) else {
                await finishWithError("Failed to load transcription model.", cleanupURL: audioURL)
                return
            }
            text = context.transcribe(audioURL: audioURL, language: language)
        }
        await MainActor.run {
            self.isTranscribing = false
            if let text, !text.isEmpty {
                self.finishSuccessfulTranscription(
                    text: text,
                    duration: duration,
                    modelName: model.name,
                    language: language,
                    flowId: flowId,
                    audioURL: audioURL,
                    sourceAudioURL: sourceAudioURL
                )
            } else {
                self.lastError = "No speech detected."
                self.lastTranscriptionResult = nil
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
    }

    private nonisolated func whisperContext(modelPath: String, modelId: String) async -> WhisperContext? {
        await MainActor.run { () -> WhisperContext? in
            if cachedModelId == modelId, let cachedWhisperContext {
                return cachedWhisperContext
            }
            guard let loaded = WhisperContext(modelPath: modelPath, useGPU: true) else {
                return nil
            }
            cachedWhisperContext = loaded
            cachedModelId = modelId
            return loaded
        }
    }

    private nonisolated func parakeetContext(for model: WhisperModelInfo) async -> ParakeetContext? {
        if let cached = await MainActor.run(body: { () -> ParakeetContext? in
            cachedParakeetEngine == model.engine ? cachedParakeetContext : nil
        }) {
            return cached
        }
        guard let modelsDirectory = AppConstants.modelsDirectoryURL else { return nil }
        guard let loaded = await ParakeetContext.load(modelsDirectory: modelsDirectory, engine: model.engine) else {
            return nil
        }
        await MainActor.run {
            cachedParakeetContext = loaded
            cachedParakeetEngine = model.engine
        }
        return loaded
    }

    private func finishSuccessfulTranscription(
        text: String,
        duration: TimeInterval,
        modelName: String,
        language: String,
        flowId: String,
        audioURL: URL,
        sourceAudioURL: URL?
    ) {
        let selectedFlow = prepareFlowForFileExportIfNeeded(
            RecordingFlowStore.flow(id: flowId) ?? RecordingFlowStore.selectedFlow()
        )
        let rawTranscript = Transcript(text: text, duration: duration, modelUsed: modelName, language: language)
        let transcript = TranscriptFlowFormatter.apply(flow: selectedFlow, to: rawTranscript)

        transcriptStore.add(transcript)
        usageTracker.addUsage(seconds: duration)
        lastTranscriptionResult = transcript.cleanedText ?? transcript.text
        lastError = nil

        let retainedAudioURL = retainAudioIfNeeded(sourceAudioURL ?? audioURL, flow: selectedFlow)
        let store = transcriptStore
        let savedId = transcript.id
        let initialTranscript = transcript
        let flowForExport = selectedFlow
        let enricher = transcriptEnricher
        let recorderForExport = self

        Task.detached(priority: .utility) { [recorderForExport] in
            defer {
                if let retainedAudioURL {
                    try? FileManager.default.removeItem(at: retainedAudioURL)
                }
            }

            if let enricher, flowForExport.usesAIEnrichment {
                await enricher.enrichAndUpdate(transcript: initialTranscript, flow: flowForExport, into: store)
            }

            let latest = await MainActor.run {
                store.transcripts.first(where: { $0.id == savedId }) ?? initialTranscript
            }

            var folderOverride: URL?
            var autoOrganizeSubfolder: String?

            if #available(macOS 26, *), FoundationModelsBackend.isAvailable {
                let router = FoundationModelsBackend()
                let flowHasExplicitExportFolder = flowForExport.exportSettings.usesCustomExportSettings
                    && flowForExport.exportSettings.folderBookmark != nil

                // Match iOS: route to legacy Smart Folders only when the
                // selected Vox does not already specify an export folder.
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

            let exportURL = TranscriptFileExporter.exportIfEnabled(
                latest,
                folderURLOverride: folderOverride,
                autoOrganizeSubfolder: autoOrganizeSubfolder,
                flow: flowForExport
            )

            if let exportURL, let retainedAudioURL {
                let noteFolderScopeURL = folderOverride ?? TranscriptFileExporter.resolveExportFolderURL(flow: flowForExport)
                do {
                    if let audioExportURL = try await AudioAttachmentExporter.exportAudioIfNeeded(
                        sourceAudioURL: retainedAudioURL,
                        transcriptFileURL: exportURL,
                        flow: flowForExport,
                        transcriptFolderScopeURL: noteFolderScopeURL
                    ) {
                        let relativePath = AudioAttachmentExporter.relativePath(from: exportURL, to: audioExportURL)
                        try TranscriptFileExporter.attachAudioReference(
                            to: exportURL,
                            relativePath: relativePath,
                            securityScopedFolderURL: noteFolderScopeURL
                        )
                    }
                } catch {
                    KeyboardDebugLog.shared.log("[MacRecorder] Audio export failed: \(error)")
                }
            }

            await MainActor.run {
                recorderForExport.lastExportURL = exportURL
            }
        }

        try? FileManager.default.removeItem(at: audioURL)
    }

    private func prepareFlowForFileExportIfNeeded(_ flow: RecordingFlow) -> RecordingFlow {
        guard flow.exportSettings.usesCustomExportSettings else {
            prepareGlobalExportFolderIfNeeded()
            return flow
        }
        guard flow.exportSettings.exportEnabled else { return flow }
        guard resolveSecurityScopedURL(from: flow.exportSettings.folderBookmark) == nil else { return flow }
        guard let selection = requestDirectoryAccess(
            title: "Choose Export Folder",
            message: "Voxboard needs permission to save notes for the \"\(flow.displayName)\" Vox."
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
                message: "Voxboard needs permission to save transcript files."
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
        guard let bookmarkData else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
    }

    private func saveUpdatedFlow(_ updated: RecordingFlow) {
        var flows = RecordingFlowStore.loadFlows()
        if let index = flows.firstIndex(where: { $0.id == updated.id }) {
            flows[index] = updated
        } else {
            flows.append(updated)
        }
        RecordingFlowStore.saveFlows(flows)
    }

    private func retainAudioIfNeeded(_ sourceURL: URL, flow: RecordingFlow) -> URL? {
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

    private func finishWithError(_ message: String, cleanupURL: URL) async {
        await MainActor.run {
            self.isTranscribing = false
            self.lastTranscriptionResult = nil
            self.lastError = message
        }
        try? FileManager.default.removeItem(at: cleanupURL)
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
