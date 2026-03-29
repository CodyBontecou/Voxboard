#if os(iOS)
import Foundation
import FluidAudio

/// Manages model lifecycle: bundled model setup, downloads, selection, and language preference.
/// Stores models in the App Group container so both the app and keyboard extension can access them.
@Observable
public final class ModelManager {
    public var downloadProgress: [String: Double] = [:]
    public var isDownloading: [String: Bool] = [:]

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
            ensureSelectedLanguageIsSupported()
        }
    }

    public var selectedLanguage: String {
        didSet { AppConstants.sharedDefaults?.set(selectedLanguage, forKey: AppConstants.selectedLanguageKey) }
    }

    public var selectedModel: WhisperModelInfo? {
        WhisperModelInfo.availableModels.first { $0.id == selectedModelId }
    }

    /// Languages shown in the picker for the currently-selected model.
    public var availableLanguages: [LanguageOption] {
        Self.supportedLanguages(for: selectedModel?.engine ?? .whisper)
    }

    public var downloadedModels: [WhisperModelInfo] {
        WhisperModelInfo.availableModels.filter { $0.isDownloaded }
    }

    // MARK: - Initialization

    public init() {
        // Seed from UserDefaults so the persisted selection survives app restarts.
        self.selectedModelId = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
            ?? AppConstants.defaultModelName
        self.selectedLanguage = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey)
            ?? "auto"
        ensureSelectedLanguageIsSupported()
        ensureModelsDirectory()
    }

    /// Copy the bundled base model from the app bundle into the shared App Group container.
    /// Call this from the main app on first launch.
    public func copyBundledModelIfNeeded() {
        guard let modelsDir = AppConstants.modelsDirectoryURL else { return }
        let destURL = modelsDir.appendingPathComponent("ggml-base.bin")

        guard !FileManager.default.fileExists(atPath: destURL.path) else { return }

        if let bundleURL = Bundle.main.url(forResource: "ggml-base", withExtension: "bin") {
            do {
                try FileManager.default.copyItem(at: bundleURL, to: destURL)
                print("[ModelManager] Copied bundled base model to shared container")
            } catch {
                print("[ModelManager] Failed to copy bundled model: \(error)")
            }
        }
    }

    // MARK: - Download

    /// Start downloading a model. No-op if the model is already downloading.
    public func startDownload(_ model: WhisperModelInfo) {
        guard downloadTasks[model.id] == nil else { return }

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

    // MARK: - Whisper Download

    private func downloadWhisperModel(_ model: WhisperModelInfo) async {
        guard let modelsDir = AppConstants.modelsDirectoryURL else {
            await finishDownload(modelId: model.id, success: false)
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
            await finishDownload(modelId: model.id, success: false)
        }
    }

    // MARK: - Parakeet Download

    private func downloadParakeetModel(_ model: WhisperModelInfo) async {
        guard let modelsDir = AppConstants.modelsDirectoryURL else {
            await finishDownload(modelId: model.id, success: false)
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
            print("[ModelManager] Downloaded Parakeet \(model.name) successfully")
            await finishDownload(modelId: model.id, success: true)
        } catch is CancellationError {
            print("[ModelManager] Parakeet download cancelled for \(model.name)")
            await finishDownload(modelId: model.id, success: false)
        } catch {
            print("[ModelManager] Parakeet download failed for \(model.name): \(error)")
            await finishDownload(modelId: model.id, success: false)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func finishDownload(modelId: String, success: Bool) {
        isDownloading[modelId] = false
        if !success {
            downloadProgress[modelId] = 0
        } else {
            downloadProgress[modelId] = 1.0
        }
    }

    private func cleanupPartialDownload(for model: WhisperModelInfo) {
        guard let modelsDir = AppConstants.modelsDirectoryURL else { return }
        if model.engine.isParakeet {
            // Remove the partial repo directory so the next download starts fresh.
            guard let folder = model.engine.parakeetRepoFolderName else { return }
            let repoDir = modelsDir.appendingPathComponent(folder)
            try? FileManager.default.removeItem(at: repoDir)
        } else {
            // Remove any partial .bin file.
            let dest = modelsDir.appendingPathComponent(model.fileName)
            try? FileManager.default.removeItem(at: dest)
        }
    }

    // MARK: - Delete

    public func deleteModel(_ model: WhisperModelInfo) {
        guard let url = model.localURL else { return }
        try? FileManager.default.removeItem(at: url)

        if selectedModelId == model.id {
            selectedModelId = AppConstants.defaultModelName
        }
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
#endif
