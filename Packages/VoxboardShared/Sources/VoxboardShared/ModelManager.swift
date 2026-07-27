import Foundation
#if os(iOS) || os(macOS)
import FluidAudio
#endif

/// Manages Automatic/local selection, opt-in model downloads, and language preference.
/// Stores models in the App Group container so both the app and keyboard extension can access them.
@Observable
public final class ModelManager {
    public var downloadProgress: [String: Double] = [:]
    public var isDownloading: [String: Bool] = [:]
    /// Incremented whenever installed model files change so filesystem-backed
    /// download state refreshes immediately in SwiftUI.
    public private(set) var installedModelsRevision = 0
    public var modelOperationError: String?

    /// Active download tasks keyed by model ID.
    /// Not @Observable-tracked — only accessed from the main thread via SwiftUI.
    @ObservationIgnored
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Settings
    // Stored properties so @Observable tracks mutations and SwiftUI re-renders.
    // didSet observers keep the shared UserDefaults in sync for the keyboard extension.

    public var selectedModelId: String {
        didSet {
            AppConstants.sharedDefaults?.set(selectedModelId, forKey: AppConstants.selectedModelKey)
            if WhisperModelInfo.availableModels.contains(where: { $0.id == selectedModelId }) {
                AppConstants.sharedDefaults?.set(selectedModelId, forKey: AppConstants.selectedFallbackModelKey)
            }
            ensureSelectedLanguageIsSupported()
        }
    }

    public var selectedLanguage: String {
        didSet { AppConstants.sharedDefaults?.set(selectedLanguage, forKey: AppConstants.selectedLanguageKey) }
    }

    public var selectedModel: WhisperModelInfo? {
        WhisperModelInfo.availableModels.first { $0.id == selectedModelId }
    }

    public var isAutomaticSelection: Bool {
        selectedModelId == TranscriptionBackendID.automatic
    }

    /// Last explicitly selected local model. Automatic uses it only when the
    /// system recognizer is unavailable or fails before producing a transcript.
    public var preferredFallbackModelID: String? {
        AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedFallbackModelKey)
    }

    public func selectAutomatic() {
        selectedModelId = TranscriptionBackendID.automatic
    }

    public func selectModel(_ model: WhisperModelInfo) {
        selectedModelId = model.id
    }

    /// Languages shown in the picker for the currently-selected backend.
    public var availableLanguages: [LanguageOption] {
        if isAutomaticSelection { return Self.automaticSupportedLanguages }
        return Self.supportedLanguages(for: selectedModel?.engine ?? .whisper)
    }

    public var downloadedModels: [WhisperModelInfo] {
        _ = installedModelsRevision
        return WhisperModelInfo.availableModels.filter { $0.isDownloaded }
    }

    public func isModelDownloaded(_ model: WhisperModelInfo) -> Bool {
        _ = installedModelsRevision
        return model.isDownloaded
    }

    public var isVoiceActivityModelDownloaded: Bool {
        _ = installedModelsRevision
        #if os(iOS) || os(macOS)
        return VoiceActivityModelAsset.isInstalled
        #else
        return false
        #endif
    }

    // MARK: - Initialization

    public init() {
        let defaults = AppConstants.sharedDefaults
        let persistedSelection = defaults?.string(forKey: AppConstants.selectedModelKey)

        #if os(iOS)
        let hasMigrated = defaults?.bool(forKey: AppConstants.transcriptionSelectionMigrationKey) == true
        if persistedSelection == nil || (!hasMigrated && persistedSelection == AppConstants.defaultModelName) {
            // Fresh installs and the former implicitly-bundled Base default move
            // to native system transcription. Preserve an existing Base file as
            // an opt-in fallback without keeping it selected.
            self.selectedModelId = TranscriptionBackendID.automatic
            if persistedSelection == AppConstants.defaultModelName {
                defaults?.set(AppConstants.defaultModelName, forKey: AppConstants.selectedFallbackModelKey)
            }
            defaults?.set(TranscriptionBackendID.automatic, forKey: AppConstants.selectedModelKey)
        } else if persistedSelection == TranscriptionBackendID.automatic
                    || WhisperModelInfo.availableModels.contains(where: { $0.id == persistedSelection }) {
            self.selectedModelId = persistedSelection ?? TranscriptionBackendID.automatic
        } else {
            self.selectedModelId = TranscriptionBackendID.automatic
            defaults?.set(TranscriptionBackendID.automatic, forKey: AppConstants.selectedModelKey)
        }
        defaults?.set(true, forKey: AppConstants.transcriptionSelectionMigrationKey)
        #else
        if let persistedSelection,
           WhisperModelInfo.availableModels.contains(where: { $0.id == persistedSelection }) {
            self.selectedModelId = persistedSelection
        } else {
            self.selectedModelId = AppConstants.defaultModelName
        }
        #endif

        self.selectedLanguage = defaults?.string(forKey: AppConstants.selectedLanguageKey) ?? "auto"

        if defaults?.string(forKey: AppConstants.selectedFallbackModelKey) == nil,
           WhisperModelInfo.availableModels.contains(where: { $0.id == self.selectedModelId }) {
            defaults?.set(self.selectedModelId, forKey: AppConstants.selectedFallbackModelKey)
        }

        ensureSelectedLanguageIsSupported()
        ensureModelsDirectory()
    }

    // MARK: - Download

    /// Start downloading a model. No-op if the model is already downloading.
    public func startDownload(_ model: WhisperModelInfo) {
        guard downloadTasks[model.id] == nil else { return }

        modelOperationError = nil
        isDownloading[model.id] = true
        downloadProgress[model.id] = 0

        let task = Task { [weak self] in
            if model.engine.isParakeet {
                await self?.downloadParakeetModel(model)
            } else {
                await self?.downloadWhisperModel(model)
            }
            // Clean up task handle when done (whether success, failure, or cancellation)
            await MainActor.run { [weak self] in
                self?.downloadTasks[model.id] = nil
            }
        }
        downloadTasks[model.id] = task
    }

    /// Cancel an in-progress download and clean up any partial files.
    public func cancelDownload(_ model: WhisperModelInfo) {
        downloadTasks[model.id]?.cancel()
        downloadTasks[model.id] = nil
        isDownloading[model.id] = false
        downloadProgress[model.id] = 0

        // Remove any partially-downloaded files so a future download starts clean.
        cleanupPartialDownload(for: model)
        print("[ModelManager] Cancelled download for \(model.name)")
    }

    /// Explicitly downloads the small Silero companion used for Parakeet
    /// keyboard pause detection. It is never fetched from a recording path.
    public func startVoiceActivityDownload() {
        #if os(iOS) || os(macOS)
        let modelID = VoiceActivityModelAsset.id
        guard downloadTasks[modelID] == nil else { return }

        modelOperationError = nil
        isDownloading[modelID] = true
        downloadProgress[modelID] = 0

        let task = Task { [weak self] in
            await self?.downloadVoiceActivityModel()
            await MainActor.run { [weak self] in
                self?.downloadTasks[modelID] = nil
            }
        }
        downloadTasks[modelID] = task
        #endif
    }

    public func cancelVoiceActivityDownload() {
        #if os(iOS) || os(macOS)
        let modelID = VoiceActivityModelAsset.id
        guard let task = downloadTasks[modelID] else { return }
        task.cancel()
        // Keep the task registered until it unwinds so a retry cannot race the
        // canceled download while both mutate the same repository directory.
        downloadProgress[modelID] = 0
        #endif
    }

    // MARK: - Whisper Download

    private func downloadWhisperModel(_ model: WhisperModelInfo) async {
        guard let modelsDir = AppConstants.modelsDirectoryURL else {
            await finishDownload(
                modelId: model.id,
                success: false,
                errorMessage: "Could not download \(model.name) because the model storage location is unavailable."
            )
            return
        }
        let destURL = modelsDir.appendingPathComponent(model.fileName)

        do {
            let delegate = DownloadProgressDelegate { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress[model.id] = progress
                }
            }

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

            // Cancel the URLSession when the enclosing Swift Task is cancelled.
            let (tempURL, _) = try await withTaskCancellationHandler {
                try await session.download(from: model.downloadURL)
            } onCancel: {
                session.invalidateAndCancel()
            }

            // Check for cancellation before moving the file
            try Task.checkCancellation()

            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destURL)

            session.invalidateAndCancel()
            print("[ModelManager] Downloaded \(model.name) successfully")
            await finishDownload(modelId: model.id, success: true)
        } catch is CancellationError {
            print("[ModelManager] Download cancelled for \(model.name)")
            await finishDownload(modelId: model.id, success: false)
        } catch {
            print("[ModelManager] Download failed for \(model.name): \(error)")
            await finishDownload(
                modelId: model.id,
                success: false,
                errorMessage: Task.isCancelled
                    ? nil
                    : "Could not download \(model.name). \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Parakeet Download

    private func downloadParakeetModel(_ model: WhisperModelInfo) async {
        #if os(iOS) || os(macOS)
        guard let modelsDir = AppConstants.modelsDirectoryURL else {
            await finishDownload(
                modelId: model.id,
                success: false,
                errorMessage: "Could not download \(model.name) because the model storage location is unavailable."
            )
            return
        }

        let repo: Repo = (model.engine == .parakeetV2) ? .parakeetV2 : .parakeet

        do {
            try await DownloadUtils.downloadRepo(repo, to: modelsDir) { [weak self] progress in
                guard let self else { return }

                // The weight.bin files in the Parakeet repos return `size: N/A` from the
                // HuggingFace tree API, so `totalBytes` inside DownloadUtils is effectively
                // zero — byte-fraction progress is unreliable and stays stuck at ~1%.
                // Use file count instead, which is always accurate.
                let fraction: Double
                switch progress.phase {
                case .listing:
                    fraction = 0.01   // small nonzero so the bar visibly starts
                case .downloading(let completed, let total):
                    fraction = total > 0 ? Double(completed) / Double(total) : 0.01
                case .compiling:
                    fraction = 0.98
                }

                Task { @MainActor [weak self] in
                    self?.downloadProgress[model.id] = fraction
                }
            }

            try Task.checkCancellation()

            guard model.isDownloaded else {
                print("[ModelManager] Parakeet download finished but required files are missing for \(model.name)")
                await finishDownload(
                    modelId: model.id,
                    success: false,
                    errorMessage: "The \(model.name) download finished, but required model files were missing. Please try again."
                )
                return
            }

            print("[ModelManager] Downloaded Parakeet \(model.name) successfully")
            await finishDownload(modelId: model.id, success: true)
        } catch is CancellationError {
            print("[ModelManager] Parakeet download cancelled for \(model.name)")
            await finishDownload(modelId: model.id, success: false)
        } catch {
            print("[ModelManager] Parakeet download failed for \(model.name): \(error)")
            await finishDownload(
                modelId: model.id,
                success: false,
                errorMessage: Task.isCancelled
                    ? nil
                    : "Could not download \(model.name). \(error.localizedDescription)"
            )
        }
        #else
        print("[ModelManager] Parakeet downloads are not available on this platform")
        await finishDownload(
            modelId: model.id,
            success: false,
            errorMessage: "Parakeet downloads are not available on this platform."
        )
        #endif
    }

    // MARK: - Voice Activity Download

    private func downloadVoiceActivityModel() async {
        #if os(iOS) || os(macOS)
        let modelID = VoiceActivityModelAsset.id
        guard let modelsDirectory = AppConstants.modelsDirectoryURL else {
            await finishDownload(
                modelId: modelID,
                success: false,
                errorMessage: "Could not download voice pause detection because the model storage location is unavailable."
            )
            return
        }

        do {
            try await DownloadUtils.downloadRepo(.vad, to: modelsDirectory) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress[modelID] = progress.fractionCompleted
                }
            }
            try Task.checkCancellation()

            guard VoiceActivityModelAsset.isInstalled(in: modelsDirectory) else {
                await finishDownload(
                    modelId: modelID,
                    success: false,
                    errorMessage: "The voice pause detection download finished, but required model files were missing. Please try again."
                )
                return
            }

            print("[ModelManager] Downloaded voice pause detection successfully")
            await finishDownload(modelId: modelID, success: true)
        } catch is CancellationError {
            print("[ModelManager] Voice pause detection download cancelled")
            cleanupVoiceActivityDownload()
            await finishDownload(modelId: modelID, success: false)
        } catch {
            print("[ModelManager] Voice pause detection download failed: \(error)")
            if Task.isCancelled {
                cleanupVoiceActivityDownload()
            }
            await finishDownload(
                modelId: modelID,
                success: false,
                errorMessage: Task.isCancelled
                    ? nil
                    : "Could not download voice pause detection. \(error.localizedDescription)"
            )
        }
        #endif
    }

    // MARK: - Helpers

    @MainActor
    private func finishDownload(
        modelId: String,
        success: Bool,
        errorMessage: String? = nil
    ) {
        isDownloading[modelId] = false
        if !success {
            downloadProgress[modelId] = 0
            if let errorMessage {
                modelOperationError = errorMessage
            }
        } else {
            downloadProgress[modelId] = 1.0
            installedModelsRevision &+= 1
        }
    }

    private func cleanupVoiceActivityDownload() {
        #if os(iOS) || os(macOS)
        guard let modelsDirectory = AppConstants.modelsDirectoryURL else { return }
        try? FileManager.default.removeItem(
            at: VoiceActivityModelAsset.repositoryURL(in: modelsDirectory)
        )
        #endif
    }

    private func cleanupPartialDownload(for model: WhisperModelInfo) {
        guard let modelsDir = AppConstants.modelsDirectoryURL else { return }
        if model.engine.isParakeet {
            // Remove the partial repo directory so the next download starts fresh.
            guard let folder = model.engine.parakeetRepoFolderName else { return }
            let repoDir = modelsDir.appendingPathComponent(folder)
            try? FileManager.default.removeItem(at: repoDir)

            // Clean up the legacy pre-FluidAudio-folder-name directory if present.
            let legacyRepoDir = modelsDir.appendingPathComponent("\(folder)-coreml")
            try? FileManager.default.removeItem(at: legacyRepoDir)
        } else {
            // Remove any partial .bin file.
            let dest = modelsDir.appendingPathComponent(model.fileName)
            try? FileManager.default.removeItem(at: dest)
        }
    }

    // MARK: - Delete

    @discardableResult
    public func deleteVoiceActivityModel() -> Bool {
        #if os(iOS) || os(macOS)
        modelOperationError = nil
        guard let modelsDirectory = AppConstants.modelsDirectoryURL else {
            modelOperationError = "The model storage location is unavailable."
            return false
        }

        do {
            let repositoryURL = VoiceActivityModelAsset.repositoryURL(in: modelsDirectory)
            if FileManager.default.fileExists(atPath: repositoryURL.path) {
                try FileManager.default.removeItem(at: repositoryURL)
            }
        } catch {
            modelOperationError = "Could not delete voice pause detection: \(error.localizedDescription)"
            return false
        }

        installedModelsRevision &+= 1
        return true
        #else
        return false
        #endif
    }

    @discardableResult
    public func deleteModel(_ model: WhisperModelInfo) -> Bool {
        modelOperationError = nil
        guard let url = model.localURL else {
            modelOperationError = "The model storage location is unavailable."
            return false
        }

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            modelOperationError = "Could not delete \(model.name): \(error.localizedDescription)"
            return false
        }

        if preferredFallbackModelID == model.id {
            AppConstants.sharedDefaults?.removeObject(forKey: AppConstants.selectedFallbackModelKey)
        }
        if selectedModelId == model.id {
            selectedModelId = AppConstants.defaultTranscriptionBackendID
        }
        installedModelsRevision &+= 1
        return true
    }

    private func ensureModelsDirectory() {
        guard let dir = AppConstants.modelsDirectoryURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Supported Languages

    public typealias LanguageOption = (code: String, name: String)

    /// Whisper.cpp language options exposed in Voxboard.
    public static let whisperSupportedLanguages: [LanguageOption] = [
        ("auto", "Auto Detect"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("ru", "Russian"),
        ("zh", "Chinese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("tr", "Turkish"),
        ("vi", "Vietnamese"),
        ("th", "Thai"),
        ("uk", "Ukrainian"),
        ("sv", "Swedish"),
        ("da", "Danish"),
        ("no", "Norwegian"),
        ("fi", "Finnish"),
    ]

    /// Automatic's `auto` value follows the device language because Apple's
    /// SpeechTranscriber requires a concrete locale rather than detecting one.
    public static let automaticSupportedLanguages: [LanguageOption] = [
        ("auto", "System Language"),
    ] + whisperSupportedLanguages.filter { $0.code != "auto" }

    /// NVIDIA Parakeet-TDT-0.6b-v3 languages.
    public static let parakeetV3SupportedLanguages: [LanguageOption] = [
        ("auto", "Auto Detect"),
        ("bg", "Bulgarian"),
        ("hr", "Croatian"),
        ("cs", "Czech"),
        ("da", "Danish"),
        ("nl", "Dutch"),
        ("en", "English"),
        ("et", "Estonian"),
        ("fi", "Finnish"),
        ("fr", "French"),
        ("de", "German"),
        ("el", "Greek"),
        ("hu", "Hungarian"),
        ("it", "Italian"),
        ("lv", "Latvian"),
        ("lt", "Lithuanian"),
        ("mt", "Maltese"),
        ("pl", "Polish"),
        ("pt", "Portuguese"),
        ("ro", "Romanian"),
        ("sk", "Slovak"),
        ("sl", "Slovenian"),
        ("es", "Spanish"),
        ("sv", "Swedish"),
        ("ru", "Russian"),
        ("uk", "Ukrainian"),
    ]

    /// Parakeet v2 is currently treated as English-only in Voxboard.
    public static let parakeetV2SupportedLanguages: [LanguageOption] = [
        ("en", "English"),
    ]

    public static func supportedLanguages(for engine: ModelEngine) -> [LanguageOption] {
        switch engine {
        case .whisper:    return whisperSupportedLanguages
        case .parakeetV2: return parakeetV2SupportedLanguages
        case .parakeetV3: return parakeetV3SupportedLanguages
        }
    }

    /// Backward-compatible alias used by older callers.
    public static let supportedLanguages: [LanguageOption] = whisperSupportedLanguages

    private func ensureSelectedLanguageIsSupported() {
        let allowed = availableLanguages
        guard !allowed.isEmpty else { return }
        guard allowed.contains(where: { $0.code == selectedLanguage }) else {
            // Prefer auto-detect when available; otherwise use the first explicit language.
            selectedLanguage = allowed.first(where: { $0.code == "auto" })?.code ?? allowed[0].code
            return
        }
    }
}

// MARK: - Whisper Download Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let progressHandler: @Sendable (Double) -> Void

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Handled by the async/await download call
    }
}
