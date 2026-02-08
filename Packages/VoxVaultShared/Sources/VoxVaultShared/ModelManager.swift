import Foundation

/// Manages whisper model lifecycle: bundled model setup, downloads, selection, and language preference.
/// Stores models in the App Group container so both the app and keyboard extension can access them.
@Observable
public final class ModelManager {
    public var downloadProgress: [String: Double] = [:]
    public var isDownloading: [String: Bool] = [:]

    // MARK: - Settings (stored in shared UserDefaults)

    public var selectedModelId: String {
        get { AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey) ?? AppConstants.defaultModelName }
        set { AppConstants.sharedDefaults?.set(newValue, forKey: AppConstants.selectedModelKey) }
    }

    public var selectedLanguage: String {
        get { AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey) ?? "auto" }
        set { AppConstants.sharedDefaults?.set(newValue, forKey: AppConstants.selectedLanguageKey) }
    }

    public var selectedModel: WhisperModelInfo? {
        WhisperModelInfo.availableModels.first { $0.id == selectedModelId }
    }

    public var downloadedModels: [WhisperModelInfo] {
        WhisperModelInfo.availableModels.filter { $0.isDownloaded }
    }

    // MARK: - Initialization

    public init() {
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

    public func downloadModel(_ model: WhisperModelInfo) async {
        guard let modelsDir = AppConstants.modelsDirectoryURL else { return }
        let destURL = modelsDir.appendingPathComponent(model.fileName)

        isDownloading[model.id] = true
        downloadProgress[model.id] = 0

        do {
            let delegate = DownloadProgressDelegate { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress[model.id] = progress
                }
            }

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let (tempURL, _) = try await session.download(from: model.downloadURL)

            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destURL)

            downloadProgress[model.id] = 1.0
            session.invalidateAndCancel()
            print("[ModelManager] Downloaded \(model.name) successfully")
        } catch {
            print("[ModelManager] Download failed for \(model.name): \(error)")
            downloadProgress[model.id] = 0
        }

        isDownloading[model.id] = false
    }

    // MARK: - Delete

    public func deleteModel(_ model: WhisperModelInfo) {
        guard let url = model.localURL else { return }
        try? FileManager.default.removeItem(at: url)

        if selectedModelId == model.id {
            selectedModelId = AppConstants.defaultModelName
        }
    }

    // MARK: - Helpers

    private func ensureModelsDirectory() {
        guard let dir = AppConstants.modelsDirectoryURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Supported Languages

    public static let supportedLanguages: [(code: String, name: String)] = [
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
}

// MARK: - Download Delegate

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
