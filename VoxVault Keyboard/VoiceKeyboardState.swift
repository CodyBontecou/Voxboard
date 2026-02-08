import Foundation
import VoxVaultShared

/// Manages recording + transcription state for the keyboard extension.
/// Keeps the whisper context alive between transcriptions to avoid re-loading the model.
@Observable
final class VoiceKeyboardState {

    enum Status: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
        case noModel
        case needsFullAccess
    }

    var status: Status = .idle
    var recordingDuration: TimeInterval = 0
    var selectedModelIndex: Int = 0

    private var recorder = AudioRecorder()
    private var whisperContext: WhisperContext?
    private var loadedModelPath: String?
    private var timer: Timer?
    private var recordStartTime: Date?

    // MARK: - Available Models

    /// Only models that have been downloaded (stored in App Group container).
    var downloadedModels: [WhisperModelInfo] {
        WhisperModelInfo.availableModels.filter { $0.isDownloaded }
    }

    var currentModel: WhisperModelInfo? {
        let models = downloadedModels
        guard !models.isEmpty else { return nil }
        let idx = min(selectedModelIndex, models.count - 1)
        return models[max(0, idx)]
    }

    var currentModelName: String {
        currentModel?.name ?? "No Model"
    }

    // MARK: - Model Navigation (< > arrows)

    func previousModel() {
        let count = downloadedModels.count
        guard count > 0 else { return }
        selectedModelIndex = (selectedModelIndex - 1 + count) % count
        whisperContext = nil
        loadedModelPath = nil
    }

    func nextModel() {
        let count = downloadedModels.count
        guard count > 0 else { return }
        selectedModelIndex = (selectedModelIndex + 1) % count
        whisperContext = nil
        loadedModelPath = nil
    }

    // MARK: - Toggle Recording

    func toggleRecording(
        hasFullAccess: Bool,
        onTranscription: @escaping @MainActor (String) -> Void
    ) {
        guard hasFullAccess else {
            status = .needsFullAccess
            return
        }

        guard currentModel != nil else {
            status = .noModel
            return
        }

        switch status {
        case .recording:
            stopAndTranscribe(onTranscription: onTranscription)
        default:
            startRecording()
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard recorder.startRecording() else {
            status = .error("Mic unavailable")
            resetErrorAfterDelay()
            return
        }

        status = .recording
        recordingDuration = 0
        recordStartTime = Date()

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let start = self.recordStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopAndTranscribe(onTranscription: @escaping @MainActor (String) -> Void) {
        timer?.invalidate()
        timer = nil

        guard let audioURL = recorder.stopRecording() else {
            status = .idle
            return
        }

        status = .transcribing
        let duration = recordingDuration

        let modelPath = currentModel?.localURL?.path
        let language = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey) ?? "auto"
        let modelName = currentModel?.name ?? "Unknown"

        Task.detached(priority: .userInitiated) { [weak self] in
            var text: String?

            if let modelPath {
                // Reuse existing context or load model
                let ctx: WhisperContext? = await MainActor.run {
                    if let self, let existing = self.whisperContext, self.loadedModelPath == modelPath {
                        return existing
                    }
                    let newCtx = WhisperContext(modelPath: modelPath)
                    Task { @MainActor in
                        self?.whisperContext = newCtx
                        self?.loadedModelPath = modelPath
                    }
                    return newCtx
                }

                text = ctx?.transcribe(audioURL: audioURL, language: language)
            }

            await MainActor.run { [weak self] in
                if let text, !text.isEmpty {
                    onTranscription(text)

                    // Also save to shared transcript history
                    let transcript = Transcript(
                        text: text,
                        duration: duration,
                        modelUsed: modelName,
                        language: language
                    )
                    let store = TranscriptStore()
                    store.add(transcript)

                    self?.status = .idle
                } else {
                    self?.status = .error("No speech detected")
                    self?.resetErrorAfterDelay()
                }
            }
        }
    }

    // MARK: - Helpers

    private func resetErrorAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if case .error = status { status = .idle }
        }
    }
}
