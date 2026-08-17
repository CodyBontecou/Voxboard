import Foundation

public enum OnDeviceTranscriptionError: Error, LocalizedError, Equatable, Sendable {
    case modelUnavailable
    case systemBackendUnavailable
    case systemBackendFailed(String)
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
        case .systemBackendFailed(let reason):
            return "Apple Speech could not start: \(reason)"
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
    /// Retains external security-scoped access for the full lifetime of the
    /// cached inference context.
    private var cachedModelAccess: InstalledModelAccess?
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

        var systemFailure: OnDeviceTranscriptionError?
        if let systemBackend,
           await systemBackend.availability(language: language) != .unavailable {
            do {
                try await systemBackend.prepare(language: language)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as OnDeviceTranscriptionError {
                systemFailure = error
            } catch {
                systemFailure = .systemBackendFailed(error.localizedDescription)
            }
        }

        guard let fallback = resolvedFallbackModel(preferredID: fallbackModelID) else {
            throw systemFailure ?? OnDeviceTranscriptionError.noAvailableBackend
        }
        try await prepareLocalModel(fallback)
    }

    /// Starts live transcription only for Automatic when the injected Apple
    /// Speech backend is ready or can install its system-managed language asset.
    /// Explicit Whisper and Parakeet selections intentionally remain batch-only.
    public func startLiveTranscription(
        modelID: String,
        language: String = "auto",
        onUpdate: @escaping @concurrent @Sendable (SystemTranscriptionUpdate) async -> Void
    ) async throws -> (any SystemLiveTranscriptionSession)? {
        guard modelID == TranscriptionBackendID.automatic,
              let systemBackend else {
            return nil
        }

        // Do not gate a user-initiated live session on the cached/read-only
        // availability result. Apple Speech can report unavailable before its
        // permission prompt or first asset allocation; starting the backend is
        // what resolves those states and produces an actionable error if needed.
        return try await systemBackend.startLiveTranscription(
            language: language,
            onUpdate: onUpdate
        )
    }

    public func transcribe(
        audioURL: URL,
        modelID: String,
        language: String = "auto",
        onProgress: TranscriptionProgressHandler? = nil
    ) async throws -> String {
        try await transcribeResult(
            audioURL: audioURL,
            modelID: modelID,
            language: language,
            onProgress: onProgress
        ).text
    }

    public func transcribeResult(
        audioURL: URL,
        modelID: String,
        fallbackModelID: String? = nil,
        language: String = "auto",
        onProgress: TranscriptionProgressHandler? = nil
    ) async throws -> OnDeviceTranscriptionResult {
        // Conversion and model loading remain indeterminate. Local backends
        // switch to exact source-audio coverage only when inference begins;
        // Apple Speech exposes no verified processing cursor and stays active
        // without a fabricated completion estimate.
        onProgress?(.preparing)

        if modelID != TranscriptionBackendID.automatic {
            guard let model = localModel(id: modelID), model.isDownloaded else {
                throw OnDeviceTranscriptionError.modelUnavailable
            }
            return try await transcribeLocally(
                audioURL: audioURL,
                model: model,
                language: language,
                onProgress: onProgress
            )
        }

        var systemFailure: OnDeviceTranscriptionError?
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
                    language: output.language,
                    segments: output.segments
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch OnDeviceTranscriptionError.noSpeechDetected {
                // Do not run a second recognizer over genuine silence.
                throw OnDeviceTranscriptionError.noSpeechDetected
            } catch let error as OnDeviceTranscriptionError {
                systemFailure = error
            } catch {
                // Operational and asset failures may fall back to a model the
                // user explicitly downloaded. No local download is initiated.
                systemFailure = .systemBackendFailed(error.localizedDescription)
            }
        }

        guard let fallback = resolvedFallbackModel(preferredID: fallbackModelID) else {
            throw systemFailure ?? OnDeviceTranscriptionError.noAvailableBackend
        }
        return try await transcribeLocally(
            audioURL: audioURL,
            model: fallback,
            language: language,
            onProgress: onProgress
        )
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
        guard let modelAccess = model.installedModelAccess(
            defaults: AppConstants.sharedDefaults
        ) else {
            throw OnDeviceTranscriptionError.modelUnavailable
        }

        if cachedLocalModelID == model.id,
           cachedModelAccess?.source == modelAccess.source,
           cachedModelAccess?.url.standardizedFileURL == modelAccess.url.standardizedFileURL,
           cachedWhisperContext != nil || cachedParakeetContext != nil {
            return
        }

        if model.engine.isParakeet {
            guard let context = await ParakeetContext.load(
                repositoryDirectory: modelAccess.url,
                engine: model.engine,
                allowsAutomaticRecovery: modelAccess.source == .appManaged
            ) else {
                throw OnDeviceTranscriptionError.modelLoadFailed
            }
            cachedParakeetContext = context
            cachedWhisperContext = nil
        } else {
            #if os(macOS)
            let useGPU = true
            #else
            let useGPU = false
            #endif
            guard let context = WhisperContext(
                modelPath: modelAccess.url.path,
                useGPU: useGPU
            ) else {
                throw OnDeviceTranscriptionError.modelLoadFailed
            }
            cachedWhisperContext = context
            cachedParakeetContext = nil
        }
        cachedModelAccess = modelAccess
        cachedLocalModelID = model.id
        #else
        throw OnDeviceTranscriptionError.modelUnavailable
        #endif
    }

    private func transcribeLocally(
        audioURL: URL,
        model: WhisperModelInfo,
        language: String,
        onProgress: TranscriptionProgressHandler?
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

        let text: String
        let segments: [TimedTranscriptionSegment]
        if model.engine.isParakeet {
            guard let output = try await cachedParakeetContext?.transcribeResult(
                audioURL: workingURL,
                onProgress: onProgress
            ) else {
                throw OnDeviceTranscriptionError.noSpeechDetected
            }
            text = output.text
            segments = output.segments
        } else {
            try Task.checkCancellation()
            let output = cachedWhisperContext?.transcribeResult(
                audioURL: workingURL,
                language: language,
                onProgress: onProgress
            )
            // `whisper_full` is synchronous and cannot currently be interrupted;
            // never accept its eventual result after the calling task was cancelled.
            try Task.checkCancellation()
            guard let output else {
                throw OnDeviceTranscriptionError.noSpeechDetected
            }
            text = output.text
            segments = output.segments
        }

        try Task.checkCancellation()
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw OnDeviceTranscriptionError.noSpeechDetected
        }
        // Both local engines report source coverage, but only Vox.md knows that
        // the final recognition result is nonempty and usable.
        onProgress?(.exactAudioCoverage(1))
        return OnDeviceTranscriptionResult(
            text: trimmedText,
            backendID: model.id,
            backendName: model.name,
            backendKind: model.engine.isParakeet ? .parakeet : .whisper,
            language: model.engine.isParakeet ? "auto" : language,
            segments: segments
        )
        #else
        throw OnDeviceTranscriptionError.modelUnavailable
        #endif
    }
}
