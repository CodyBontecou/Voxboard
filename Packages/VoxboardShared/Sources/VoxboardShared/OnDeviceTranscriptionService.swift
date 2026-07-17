import Foundation

public enum OnDeviceTranscriptionError: Error, LocalizedError, Equatable, Sendable {
    case modelUnavailable
    case audioConversionFailed
    case modelLoadFailed
    case noSpeechDetected

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Download the selected transcription model before generating a transcript."
        case .audioConversionFailed:
            return "The voice recording could not be prepared for transcription."
        case .modelLoadFailed:
            return "The selected on-device transcription model could not be loaded."
        case .noSpeechDetected:
            return "No speech was detected. You can still insert the audio recording."
        }
    }
}

/// Stateless facade for one-shot, on-device transcription. It deliberately
/// returns text only to the caller and never writes transcript content to logs.
public actor OnDeviceTranscriptionService {
    public init() {}

    public func transcribe(
        audioURL: URL,
        modelID: String,
        language: String = "auto"
    ) async throws -> String {
        guard let model = WhisperModelInfo.availableModels.first(where: { $0.id == modelID }),
              model.isDownloaded else {
            throw OnDeviceTranscriptionError.modelUnavailable
        }

        let workingURL: URL
        let shouldRemoveWorkingCopy: Bool
        if audioURL.pathExtension.lowercased() == "wav" {
            workingURL = audioURL
            shouldRemoveWorkingCopy = false
        } else {
            let converted = FileManager.default.temporaryDirectory
                .appendingPathComponent("vox-capture-transcription-\(UUID().uuidString.lowercased())")
                .appendingPathExtension("wav")
            do {
                try AudioFileConverter.convertToWhisperWAV(inputURL: audioURL, outputURL: converted)
            } catch {
                throw OnDeviceTranscriptionError.audioConversionFailed
            }
            workingURL = converted
            shouldRemoveWorkingCopy = true
        }
        defer { if shouldRemoveWorkingCopy { try? FileManager.default.removeItem(at: workingURL) } }

        let text: String?
        if model.engine.isParakeet {
            guard let modelsDirectory = AppConstants.modelsDirectoryURL,
                  let context = await ParakeetContext.load(
                    modelsDirectory: modelsDirectory,
                    engine: model.engine
                  ) else {
                throw OnDeviceTranscriptionError.modelLoadFailed
            }
            text = await context.transcribe(audioURL: workingURL)
        } else {
            guard let modelURL = model.localURL else {
                throw OnDeviceTranscriptionError.modelUnavailable
            }
            text = await Task.detached(priority: .userInitiated) {
                guard let context = WhisperContext(modelPath: modelURL.path, useGPU: false) else {
                    return nil
                }
                return context.transcribe(audioURL: workingURL, language: language)
            }.value
        }

        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw OnDeviceTranscriptionError.noSpeechDetected
        }
        return text
    }
}
