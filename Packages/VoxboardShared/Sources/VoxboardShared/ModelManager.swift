import Foundation
#if os(iOS) || os(macOS)
import FluidAudio
#endif

/// Manages Automatic/local selection, opt-in model downloads, and language preference.
/// Stores models in the App Group container so both the app and keyboard extension can access them.
@MainActor
@Observable
public final class ModelManager {
    public private(set) var downloadStates: [String: ModelDownloadState] = [:] {
        didSet {
            #if os(macOS)
            updateDownloadSleepPrevention()
            #endif
        }
    }

    /// Compatibility projections used by app-lifecycle and companion-model UI.
    /// A missing fraction is intentionally omitted rather than represented as 0%.
    public var downloadProgress: [String: Double] {
        downloadStates.compactMapValues(\.fractionCompleted)
    }

    public var isDownloading: [String: Bool] {
        downloadStates.mapValues { _ in true }
    }

    /// True while any transcription or companion model is being downloaded.
    public var hasActiveDownloads: Bool {
        !downloadStates.isEmpty
    }

    /// Incremented whenever installed model files change so filesystem-backed
    /// download state refreshes immediately in SwiftUI.
    public private(set) var installedModelsRevision = 0
    public var modelOperationError: String?

    private struct ActiveDownload {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// Active download tasks keyed by model ID. The operation ID prevents stale
    /// progress or completion from an older cancelled task mutating a retry.
    @ObservationIgnored
    private var activeDownloads: [String: ActiveDownload] = [:]
    @ObservationIgnored
    private var operationRegistry = ModelDownloadOperationRegistry()
    @ObservationIgnored
    private let settingsDefaults: UserDefaults?

    #if os(macOS)
    /// Prevents macOS from idling the display or system while a large model is
    /// downloading. Keeping this token with the manager makes the protection
    /// independent of which app window started the download.
    @ObservationIgnored
    private var downloadSleepActivity: NSObjectProtocol?
    #endif

    // MARK: - Settings
    // Stored properties so @Observable tracks mutations and SwiftUI re-renders.
    // didSet observers keep the shared UserDefaults in sync for the keyboard extension.

    public var selectedModelId: String {
        didSet {
            settingsDefaults?.set(selectedModelId, forKey: AppConstants.selectedModelKey)
            if WhisperModelInfo.availableModels.contains(where: { $0.id == selectedModelId }) {
                settingsDefaults?.set(selectedModelId, forKey: AppConstants.selectedFallbackModelKey)
            }
            ensureSelectedLanguageIsSupported()
        }
    }

    public var selectedLanguage: String {
        didSet { settingsDefaults?.set(selectedLanguage, forKey: AppConstants.selectedLanguageKey) }
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
        settingsDefaults?.string(forKey: AppConstants.selectedFallbackModelKey)
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

    public func downloadState(for modelID: String) -> ModelDownloadState? {
        downloadStates[modelID]
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

    public convenience init() {
        self.init(defaults: AppConstants.sharedDefaults)
    }

    package init(defaults: UserDefaults?) {
        self.settingsDefaults = defaults
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

    deinit {
        #if os(macOS)
        if let downloadSleepActivity {
            ProcessInfo.processInfo.endActivity(downloadSleepActivity)
        }
        #endif
    }

    // MARK: - Download

    /// Start downloading a model. No-op while an earlier operation for this
    /// model is still transferring or unwinding cancellation.
    public func startDownload(_ model: WhisperModelInfo) {
        guard activeDownloads[model.id] == nil else { return }
        guard preflightStorage(for: model) else { return }
        guard let operationID = operationRegistry.reserve(modelID: model.id) else { return }

        modelOperationError = nil
        downloadStates[model.id] = ModelDownloadState(phase: .preparing)

        let task = Task { [weak self] in
            guard let self else { return }
            if model.engine.isParakeet {
                await self.downloadParakeetModel(model, operationID: operationID)
            } else {
                await self.downloadWhisperModel(model, operationID: operationID)
            }
        }
        activeDownloads[model.id] = ActiveDownload(id: operationID, task: task)
    }

    /// Cancel the transport but preserve completed Parakeet files. Retry stays
    /// unavailable until the old task has fully unwound, preventing two tasks
    /// from mutating the same repository directory.
    public func cancelDownload(_ model: WhisperModelInfo) {
        guard let active = activeDownloads[model.id] else { return }
        updateDownloadState(
            modelID: model.id,
            operationID: active.id,
            state: ModelDownloadState(phase: .cancelling)
        )
        active.task.cancel()
        print("[ModelManager] Cancelling download for \(model.name)")
    }

    /// Explicitly downloads the small Silero companion used for Parakeet
    /// keyboard pause detection. It is never fetched from a recording path.
    public func startVoiceActivityDownload() {
        #if os(iOS) || os(macOS)
        let modelID = VoiceActivityModelAsset.id
        guard activeDownloads[modelID] == nil else { return }
        guard let operationID = operationRegistry.reserve(modelID: modelID) else { return }

        modelOperationError = nil
        downloadStates[modelID] = ModelDownloadState(phase: .preparing)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.downloadVoiceActivityModel(operationID: operationID)
        }
        activeDownloads[modelID] = ActiveDownload(id: operationID, task: task)
        #endif
    }

    public func cancelVoiceActivityDownload() {
        #if os(iOS) || os(macOS)
        let modelID = VoiceActivityModelAsset.id
        guard let active = activeDownloads[modelID] else { return }
        updateDownloadState(
            modelID: modelID,
            operationID: active.id,
            state: ModelDownloadState(phase: .cancelling)
        )
        active.task.cancel()
        #endif
    }

    // MARK: - Whisper Download

    private func downloadWhisperModel(
        _ model: WhisperModelInfo,
        operationID: UUID
    ) async {
        guard let modelsDirectory = AppConstants.modelsDirectoryURL,
              let expectedByteCount = model.downloadSizeBytes else {
            finishDownload(
                modelID: model.id,
                operationID: operationID,
                success: false,
                errorMessage: "Could not download \(model.name) because its storage metadata is unavailable."
            )
            return
        }

        let destinationURL = modelsDirectory.appendingPathComponent(model.fileName)
        let stagingURL = modelsDirectory
            .appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent("\(model.id)-\(operationID.uuidString).partial")
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        do {
            updateDownloadState(
                modelID: model.id,
                operationID: operationID,
                state: ModelDownloadState(phase: .transferring)
            )

            var request = URLRequest(url: model.downloadURL, timeoutInterval: 1_800)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let result = try await WhisperModelDownloadTransport.download(
                request: request,
                stagingURL: stagingURL
            ) { [weak self] received, expected in
                let fraction = expected > 0 ? Double(received) / Double(expected) : nil
                Task { @MainActor [weak self] in
                    self?.updateDownloadState(
                        modelID: model.id,
                        operationID: operationID,
                        state: ModelDownloadState(
                            phase: .transferring,
                            fractionCompleted: fraction
                        )
                    )
                }
            }

            try Task.checkCancellation()
            updateDownloadState(
                modelID: model.id,
                operationID: operationID,
                state: ModelDownloadState(phase: .verifying, fractionCompleted: 1)
            )
            try Task.checkCancellation()
            try WhisperModelInstaller.validateAndInstall(
                response: result.response,
                stagingURL: result.fileURL,
                destinationURL: destinationURL,
                expectedByteCount: expectedByteCount
            )

            print("[ModelManager] Downloaded \(model.name) successfully")
            finishDownload(
                modelID: model.id,
                operationID: operationID,
                success: true
            )
        } catch is CancellationError {
            print("[ModelManager] Download cancelled for \(model.name)")
            finishDownload(
                modelID: model.id,
                operationID: operationID,
                success: false
            )
        } catch {
            print("[ModelManager] Download failed for \(model.name): \(error)")
            finishDownload(
                modelID: model.id,
                operationID: operationID,
                success: false,
                errorMessage: Task.isCancelled
                    ? nil
                    : "Could not download \(model.name). \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Parakeet Download

    private func downloadParakeetModel(
        _ model: WhisperModelInfo,
        operationID: UUID
    ) async {
        #if os(iOS) || os(macOS)
        guard let modelsDirectory = AppConstants.modelsDirectoryURL else {
            finishDownload(
                modelID: model.id,
                operationID: operationID,
                success: false,
                errorMessage: "Could not download \(model.name) because the model storage location is unavailable."
            )
            return
        }

        let repo: Repo = (model.engine == .parakeetV2) ? .parakeetV2 : .parakeet

        do {
            // FluidAudio 0.13.4 skips paths based on existence alone. Remove
            // known-size mismatches first so a retry can actually repair them.
            try model.removeInvalidExistingParakeetArtifacts(in: modelsDirectory)
            try await DownloadUtils.downloadRepo(repo, to: modelsDirectory) { [weak self] progress in
                let state: ModelDownloadState
                switch progress.phase {
                case .listing:
                    state = ModelDownloadState(phase: .listingFiles)
                case .downloading(let completed, let total):
                    // FluidAudio 0.13.4 cannot deliver live byte callbacks from
                    // its async convenience download. File count is useful context
                    // but must never be presented as a byte percentage.
                    state = ModelDownloadState(
                        phase: .transferring,
                        completedFiles: completed,
                        totalFiles: total
                    )
                case .compiling:
                    state = ModelDownloadState(phase: .verifying)
                }

                Task { @MainActor [weak self] in
                    self?.updateDownloadState(
                        modelID: model.id,
                        operationID: operationID,
                        state: state
                    )
                }
            }

            try Task.checkCancellation()
            updateDownloadState(
                modelID: model.id,
                operationID: operationID,
                state: ModelDownloadState(phase: .verifying)
            )

            guard model.isDownloaded(in: modelsDirectory) else {
                print("[ModelManager] Parakeet download finished but required files are missing for \(model.name)")
                finishDownload(
                    modelID: model.id,
                    operationID: operationID,
                    success: false,
                    errorMessage: "The \(model.name) download finished, but required model files were missing. Please try again."
                )
                return
            }

            print("[ModelManager] Downloaded Parakeet \(model.name) successfully")
            finishDownload(
                modelID: model.id,
                operationID: operationID,
                success: true
            )
        } catch is CancellationError {
            print("[ModelManager] Parakeet download cancelled for \(model.name)")
            finishDownload(
                modelID: model.id,
                operationID: operationID,
                success: false
            )
        } catch {
            print("[ModelManager] Parakeet download failed for \(model.name): \(error)")
            finishDownload(
                modelID: model.id,
                operationID: operationID,
                success: false,
                errorMessage: Task.isCancelled
                    ? nil
                    : "Could not download \(model.name). \(error.localizedDescription)"
            )
        }
        #else
        print("[ModelManager] Parakeet downloads are not available on this platform")
        finishDownload(
            modelID: model.id,
            operationID: operationID,
            success: false,
            errorMessage: "Parakeet downloads are not available on this platform."
        )
        #endif
    }

    // MARK: - Voice Activity Download

    private func downloadVoiceActivityModel(operationID: UUID) async {
        #if os(iOS) || os(macOS)
        let modelID = VoiceActivityModelAsset.id
        guard let modelsDirectory = AppConstants.modelsDirectoryURL else {
            finishDownload(
                modelID: modelID,
                operationID: operationID,
                success: false,
                errorMessage: "Could not download voice pause detection because the model storage location is unavailable."
            )
            return
        }

        do {
            try await DownloadUtils.downloadRepo(.vad, to: modelsDirectory) { [weak self] progress in
                let state: ModelDownloadState
                switch progress.phase {
                case .listing:
                    state = ModelDownloadState(phase: .listingFiles)
                case .downloading(let completed, let total):
                    state = ModelDownloadState(
                        phase: .transferring,
                        completedFiles: completed,
                        totalFiles: total
                    )
                case .compiling:
                    state = ModelDownloadState(phase: .verifying)
                }
                Task { @MainActor [weak self] in
                    self?.updateDownloadState(
                        modelID: modelID,
                        operationID: operationID,
                        state: state
                    )
                }
            }
            try Task.checkCancellation()

            guard VoiceActivityModelAsset.isInstalled(in: modelsDirectory) else {
                finishDownload(
                    modelID: modelID,
                    operationID: operationID,
                    success: false,
                    errorMessage: "The voice pause detection download finished, but required model files were missing. Please try again."
                )
                return
            }

            print("[ModelManager] Downloaded voice pause detection successfully")
            finishDownload(
                modelID: modelID,
                operationID: operationID,
                success: true
            )
        } catch is CancellationError {
            print("[ModelManager] Voice pause detection download cancelled")
            finishDownload(
                modelID: modelID,
                operationID: operationID,
                success: false
            )
        } catch {
            print("[ModelManager] Voice pause detection download failed: \(error)")
            finishDownload(
                modelID: modelID,
                operationID: operationID,
                success: false,
                errorMessage: Task.isCancelled
                    ? nil
                    : "Could not download voice pause detection. \(error.localizedDescription)"
            )
        }
        #endif
    }

    // MARK: - Helpers

    #if os(macOS)
    private func updateDownloadSleepPrevention() {
        if hasActiveDownloads {
            guard downloadSleepActivity == nil else { return }
            downloadSleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                reason: "Downloading an on-device transcription model"
            )
        } else if let downloadSleepActivity {
            ProcessInfo.processInfo.endActivity(downloadSleepActivity)
            self.downloadSleepActivity = nil
        }
    }
    #endif

    private func updateDownloadState(
        modelID: String,
        operationID: UUID,
        state: ModelDownloadState
    ) {
        guard operationRegistry.owns(modelID: modelID, operationID: operationID) else { return }
        downloadStates[modelID] = downloadStates[modelID]?.accepting(state) ?? state
    }

    private func finishDownload(
        modelID: String,
        operationID: UUID,
        success: Bool,
        errorMessage: String? = nil
    ) {
        guard operationRegistry.release(modelID: modelID, operationID: operationID) else { return }
        activeDownloads[modelID] = nil
        downloadStates[modelID] = nil

        if success {
            installedModelsRevision &+= 1
        } else if let errorMessage {
            modelOperationError = errorMessage
        }
    }

    private func preflightStorage(for model: WhisperModelInfo) -> Bool {
        guard let modelsDirectory = AppConstants.modelsDirectoryURL else {
            modelOperationError = "Could not download \(model.name) because the model storage location is unavailable."
            return false
        }
        guard let downloadSize = model.downloadSizeBytes,
              let availableCapacity = ModelDownloadStorage.availableCapacity(at: modelsDirectory) else {
            return true
        }

        let requiredCapacity = ModelDownloadStorage.requiredCapacity(
            forDownloadSize: downloadSize
        )
        guard availableCapacity >= requiredCapacity else {
            let requiredText = ByteCountFormatter.string(
                fromByteCount: requiredCapacity,
                countStyle: .file
            )
            let availableText = ByteCountFormatter.string(
                fromByteCount: availableCapacity,
                countStyle: .file
            )
            modelOperationError = "\(model.name) needs about \(requiredText) of free space. This device currently has \(availableText) available."
            return false
        }
        return true
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
            settingsDefaults?.removeObject(forKey: AppConstants.selectedFallbackModelKey)
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
