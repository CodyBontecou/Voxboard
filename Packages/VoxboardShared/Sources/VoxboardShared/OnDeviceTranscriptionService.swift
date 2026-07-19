import Foundation

public enum OnDeviceTranscriptionError: Error, LocalizedError, Equatable, Sendable {
    case modelUnavailable
    case systemBackendUnavailable
    case noAvailableBackend
    case audioConversionFailed
    case modelLoadFailed
    case noSpeechDetected

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Download the selected transcription model before generating a transcript."
        case .systemBackendUnavailable:
            return "Apple Speech is unavailable for this device or language."
        case .noAvailableBackend:
            return "Apple Speech is unavailable for this device or language. Download a Whisper or Parakeet model as a fallback."
        case .audioConversionFailed:
            return "The voice recording could not be prepared for transcription."
        case .modelLoadFailed:
            return "The selected on-device transcription model could not be loaded."
        case .noSpeechDetected:
            return "No speech was detected. You can still insert the audio recording."
        }
    }
}

/// Central dispatcher for one-shot, on-device transcription. Automatic mode
/// prefers an injected system backend (Apple Speech in the iOS app) and only
/// uses models the user has already downloaded as fallbacks. It never starts a
/// Whisper or Parakeet download itself.
public actor OnDeviceTranscriptionService {
    private let systemBackend: (any SystemTranscriptionBackend)?
    private let usesDownloadedLocalFallbacks: Bool

    #if os(iOS) || os(macOS)
    private var cachedWhisperContext: WhisperContext?
    private var cachedParakeetContext: ParakeetContext?
    private var cachedLocalModelID: String?
    #endif

    public init(
        systemBackend: (any SystemTranscriptionBackend)? = nil,
        usesDownloadedLocalFallbacks: Bool = true
    ) {
        self.systemBackend = systemBackend
        self.usesDownloadedLocalFallbacks = usesDownloadedLocalFallbacks
    }

    public func availability(
        modelID: String,
        language: String = "auto"
    ) async -> SystemTranscriptionAvailability {
        guard modelID == TranscriptionBackendID.automatic else {
            return localModel(id: modelID)?.isDownloaded == true ? .ready : .unavailable
        }
        return await systemBackend?.availability(language: language) ?? .unavailable
    }

    public func canTranscribe(
        modelID: String,
        fallbackModelID: String? = nil,
        language: String = "auto"
    ) async -> Bool {
        if modelID != TranscriptionBackendID.automatic {
            return localModel(id: modelID)?.isDownloaded == true
        }

        if let systemBackend,
           await systemBackend.availability(language: language) == .ready {
            return true
        }
        return resolvedFallbackModel(preferredID: fallbackModelID) != nil
    }

    /// Prepares the selected backend without ever downloading an app-managed
    /// Whisper or Parakeet model. Apple may install its own shared language asset.
    public func prepare(
        modelID: String,
        fallbackModelID: String? = nil,
        language: String = "auto"
    ) async throws {
        if modelID != TranscriptionBackendID.automatic {
            guard let model = localModel(id: modelID), model.isDownloaded else {
                throw OnDeviceTranscriptionError.modelUnavailable
            }
            try await prepareLocalModel(model)
            return
        }

        if let systemBackend,
           await systemBackend.availability(language: language) != .unavailable {
            do {
                try await systemBackend.prepare(language: language)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A previously downloaded model may still keep Automatic usable.
            }
        }

        guard let fallback = resolvedFallbackModel(preferredID: fallbackModelID) else {
            throw OnDeviceTranscriptionError.noAvailableBackend
        }
        try await prepareLocalModel(fallback)
    }

    /// Starts live transcription only for Automatic when the injected Apple
    /// Speech backend is ready or can install its system-managed language asset.
    /// Explicit Whisper and Parakeet selections intentionally remain batch-only.
    public func startLiveTranscription(
        modelID: String,
        language: String = "auto",
        onUpdate: @escaping @Sendable (SystemTranscriptionUpdate) async -> Void
    ) async throws -> (any SystemLiveTranscriptionSession)? {
        guard modelID == TranscriptionBackendID.automatic,
              let systemBackend,
              await systemBackend.availability(language: language) != .unavailable else {
            return nil
        }
        return try await systemBackend.startLiveTranscription(
            language: language,
            onUpdate: onUpdate
        )
    }

    public func transcribe(
        audioURL: URL,
        modelID: String,
        language: String = "auto"
    ) async throws -> String {
        try await transcribeResult(
            audioURL: audioURL,
            modelID: modelID,
            language: language
        ).text
    }

    public func transcribeResult(
        audioURL: URL,
        modelID: String,
        fallbackModelID: String? = nil,
        language: String = "auto"
    ) async throws -> OnDeviceTranscriptionResult {
        if modelID != TranscriptionBackendID.automatic {
            guard let model = localModel(id: modelID), model.isDownloaded else {
                throw OnDeviceTranscriptionError.modelUnavailable
            }
            return try await transcribeLocally(audioURL: audioURL, model: model, language: language)
        }

        if let systemBackend,
           await systemBackend.availability(language: language) != .unavailable {
            do {
                let output = try await systemBackend.transcribe(audioURL: audioURL, language: language)
                let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw OnDeviceTranscriptionError.noSpeechDetected }
                return OnDeviceTranscriptionResult(
                    text: text,
                    backendID: TranscriptionBackendID.appleSpeech,
                    backendName: "Apple Speech",
                    backendKind: .appleSpeech,
                    language: output.language
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch OnDeviceTranscriptionError.noSpeechDetected {
                // Do not run a second recognizer over genuine silence.
                throw OnDeviceTranscriptionError.noSpeechDetected
            } catch {
                // Operational and asset failures may fall back to a model the
                // user explicitly downloaded. No local download is initiated.
            }
        }

        guard let fallback = resolvedFallbackModel(preferredID: fallbackModelID) else {
            throw OnDeviceTranscriptionError.noAvailableBackend
        }
        return try await transcribeLocally(audioURL: audioURL, model: fallback, language: language)
    }

    // MARK: - Local model routing

    private func localModel(id: String) -> WhisperModelInfo? {
        WhisperModelInfo.availableModels.first { $0.id == id }
    }

    private func resolvedFallbackModel(preferredID: String?) -> WhisperModelInfo? {
        guard usesDownloadedLocalFallbacks else { return nil }
        let persistedID = preferredID
            ?? AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedFallbackModelKey)

        if let persistedID,
           let preferred = localModel(id: persistedID),
           preferred.isDownloaded {
            return preferred
        }
        if let base = localModel(id: AppConstants.defaultModelName), base.isDownloaded {
            return base
        }
        return WhisperModelInfo.availableModels.first(where: { $0.isDownloaded })
    }

    private func prepareLocalModel(_ model: WhisperModelInfo) async throws {
        #if os(iOS) || os(macOS)
        if cachedLocalModelID == model.id,
           cachedWhisperContext != nil || cachedParakeetContext != nil {
            return
        }

        guard model.isDownloaded else { throw OnDeviceTranscriptionError.modelUnavailable }
        if model.engine.isParakeet {
            guard let modelsDirectory = AppConstants.modelsDirectoryURL,
                  let context = await ParakeetContext.load(
                    modelsDirectory: modelsDirectory,
                    engine: model.engine
                  ) else {
                throw OnDeviceTranscriptionError.modelLoadFailed
            }
            cachedParakeetContext = context
            cachedWhisperContext = nil
        } else {
            guard let modelURL = model.localURL,
                  let context = WhisperContext(modelPath: modelURL.path, useGPU: false) else {
                throw OnDeviceTranscriptionError.modelLoadFailed
            }
            cachedWhisperContext = context
            cachedParakeetContext = nil
        }
        cachedLocalModelID = model.id
        #else
        throw OnDeviceTranscriptionError.modelUnavailable
        #endif
    }

    private func transcribeLocally(
        audioURL: URL,
        model: WhisperModelInfo,
        language: String
    ) async throws -> OnDeviceTranscriptionResult {
        #if os(iOS) || os(macOS)
        let workingURL: URL
        let shouldRemoveWorkingCopy: Bool
        if audioURL.pathExtension.lowercased() == "wav" {
            workingURL = audioURL
            shouldRemoveWorkingCopy = false
        } else {
            let converted = FileManager.default.temporaryDirectory
                .appendingPathComponent("vox-transcription-\(UUID().uuidString.lowercased())")
                .appendingPathExtension("wav")
            do {
                try AudioFileConverter.convertToWhisperWAV(inputURL: audioURL, outputURL: converted)
            } catch {
                throw OnDeviceTranscriptionError.audioConversionFailed
            }
            workingURL = converted
            shouldRemoveWorkingCopy = true
        }
        defer {
            if shouldRemoveWorkingCopy { try? FileManager.default.removeItem(at: workingURL) }
        }

        try await prepareLocalModel(model)

        let rawText: String?
        if model.engine.isParakeet {
            rawText = await cachedParakeetContext?.transcribe(audioURL: workingURL)
        } else {
            rawText = cachedWhisperContext?.transcribe(audioURL: workingURL, language: language)
        }

        guard let text = rawText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw OnDeviceTranscriptionError.noSpeechDetected
        }
        return OnDeviceTranscriptionResult(
            text: text,
            backendID: model.id,
            backendName: model.name,
            backendKind: model.engine.isParakeet ? .parakeet : .whisper,
            language: model.engine.isParakeet ? "auto" : language
        )
        #else
        throw OnDeviceTranscriptionError.modelUnavailable
        #endif
    }
}
