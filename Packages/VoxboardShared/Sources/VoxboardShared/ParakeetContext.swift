#if os(iOS) || os(macOS)
import CoreML
import Foundation
import FluidAudio

private let log = KeyboardDebugLog.shared

struct ParakeetTranscriptionOutput: Equatable, Sendable {
    let text: String
    let segments: [TimedTranscriptionSegment]
}

/// Swift wrapper around FluidAudio's `AsrManager` for on-device Parakeet TDT transcription.
///
/// Parakeet uses Apple's CoreML / Neural Engine instead of whisper.cpp, giving much better
/// accuracy on English speech while consuming ~800 MB peak RAM.  Because of the memory
/// footprint it is only suitable for the main app (not the keyboard extension).
///
/// Usage:
///   let ctx = await ParakeetContext.load(modelsDirectory: ..., engine: .parakeetV3)
///   let text = await ctx?.transcribe(audioURL: recordingURL)
///
public final class ParakeetContext: @unchecked Sendable {

    private let manager: AsrManager
    /// FluidAudio exposes one progress stream and shared decoder state per
    /// manager, so the complete inference session must remain exclusive.
    private let sessionGate = AsyncExclusiveGate()

    private init(manager: AsrManager) {
        self.manager = manager
    }

    // MARK: - Factory

    /// Load a Parakeet model.
    ///
    /// - Parameters:
    ///   - modelsDirectory:  The shared App Group models directory
    ///                       (``AppConstants.modelsDirectoryURL``).  The local FluidAudio
    ///                       repo folder (`parakeet-tdt-0.6b-v?`) must already exist inside it.
    ///   - engine:           `.parakeetV2` or `.parakeetV3`
    /// - Returns: A ready-to-use `ParakeetContext`, or `nil` if models are missing / corrupt.
    public static func load(
        modelsDirectory: URL,
        engine: ModelEngine
    ) async -> ParakeetContext? {
        guard let folderName = engine.parakeetRepoFolderName else {
            log.log("[ParakeetContext] ❌ Invalid engine: \(engine.rawValue)")
            return nil
        }
        return await load(
            repositoryDirectory: modelsDirectory.appendingPathComponent(folderName),
            engine: engine,
            allowsAutomaticRecovery: true
        )
    }

    /// Loads from an exact Parakeet repository. External user-owned folders use
    /// a read-only path that never invokes FluidAudio's cache recovery, because
    /// that recovery deletes a failed repository before downloading a new copy.
    static func load(
        repositoryDirectory: URL,
        engine: ModelEngine,
        allowsAutomaticRecovery: Bool
    ) async -> ParakeetContext? {
        guard engine.isParakeet else {
            log.log("[ParakeetContext] ❌ Invalid engine: \(engine.rawValue)")
            return nil
        }

        let version: AsrModelVersion = (engine == .parakeetV2) ? .v2 : .v3
        log.log("[ParakeetContext] Loading \(repositoryDirectory.lastPathComponent)…")
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let models: AsrModels
            if allowsAutomaticRecovery {
                // App-managed caches retain FluidAudio's repair-and-redownload behavior.
                models = try await AsrModels.load(
                    from: repositoryDirectory,
                    version: version
                )
            } else {
                models = try loadExternalModels(
                    from: repositoryDirectory,
                    version: version
                )
            }

            let manager = AsrManager()
            try await manager.initialize(models: models)

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            log.log("[ParakeetContext] ✅ Loaded in \(String(format: "%.2f", elapsed))s")
            return ParakeetContext(manager: manager)
        } catch {
            log.log("[ParakeetContext] ❌ Load failed: \(error)")
            return nil
        }
    }

    /// Constructs FluidAudio's model bundle directly from already-compiled
    /// assets. This is intentionally non-repairing and therefore safe for a
    /// security-scoped folder that Vox.md does not own.
    private static func loadExternalModels(
        from repositoryDirectory: URL,
        version: AsrModelVersion
    ) throws -> AsrModels {
        let defaultConfiguration = AsrModels.defaultConfiguration()
        let preprocessorConfiguration = MLModelConfiguration()
        preprocessorConfiguration.computeUnits = .cpuOnly

        let preprocessor = try MLModel(
            contentsOf: repositoryDirectory.appendingPathComponent("Preprocessor.mlmodelc"),
            configuration: preprocessorConfiguration
        )
        let encoder = try MLModel(
            contentsOf: repositoryDirectory.appendingPathComponent("Encoder.mlmodelc"),
            configuration: defaultConfiguration
        )
        let decoder = try MLModel(
            contentsOf: repositoryDirectory.appendingPathComponent("Decoder.mlmodelc"),
            configuration: defaultConfiguration
        )
        let joint = try MLModel(
            contentsOf: repositoryDirectory.appendingPathComponent("JointDecision.mlmodelc"),
            configuration: defaultConfiguration
        )

        let vocabularyURL = repositoryDirectory.appendingPathComponent(
            ModelEngine.parakeetVocabularyFile
        )
        let data = try Data(contentsOf: vocabularyURL)
        let rawVocabulary = try JSONDecoder().decode([String: String].self, from: data)
        let vocabulary = Dictionary(uniqueKeysWithValues: rawVocabulary.compactMap { key, value in
            Int(key).map { ($0, value) }
        })
        guard !vocabulary.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return AsrModels(
            encoder: encoder,
            preprocessor: preprocessor,
            decoder: decoder,
            joint: joint,
            configuration: defaultConfiguration,
            vocabulary: vocabulary,
            version: version
        )
    }

    // MARK: - Transcription

    /// Transcribe audio from a 16 kHz mono WAV file.
    /// - Returns: The transcribed text, or `nil` if the audio is silent / transcription fails.
    public func transcribe(
        audioURL: URL,
        onProgress: TranscriptionProgressHandler? = nil
    ) async -> String? {
        do {
            return try await transcribeResult(
                audioURL: audioURL,
                onProgress: onProgress
            )?.text
        } catch {
            return nil
        }
    }

    func transcribeResult(
        audioURL: URL,
        onProgress: TranscriptionProgressHandler? = nil
    ) async throws -> ParakeetTranscriptionOutput? {
        try await sessionGate.withExclusiveAccess { [self] in
            try await transcribeResultExclusively(
                audioURL: audioURL,
                onProgress: onProgress
            )
        }
    }

    private func transcribeResultExclusively(
        audioURL: URL,
        onProgress: TranscriptionProgressHandler?
    ) async throws -> ParakeetTranscriptionOutput? {
        log.log("[ParakeetContext] transcribeResult() — \(audioURL.lastPathComponent)")
        let startTime = CFAbsoluteTimeGetCurrent()

        let audioDuration = AudioFileConverter.duration(of: audioURL)
        let shouldObserveProgress = onProgress != nil
            && ParakeetProgressObservationPolicy.shouldObserve(audioDuration: audioDuration)
        let progressTask: Task<Void, Never>?
        if shouldObserveProgress, let onProgress {
            // FluidAudio 0.13.4 finishes or fails this cached stream only for
            // input strictly longer than 240,000 samples. The service has
            // normalized this WAV to 16 kHz, so never subscribe at or below 15s
            // (or when duration cannot be verified).
            let stream = await manager.transcriptionProgressStream
            progressTask = Task {
                var relay = MonotonicAudioCoverageProgressRelay()
                do {
                    for try await fraction in stream {
                        // FluidAudio emits 1.0 before returning the recognition
                        // result. Reserve exact completion for the service after
                        // it has verified that nonempty text was produced.
                        guard let progress = relay.accept(fraction) else { continue }
                        onProgress(progress)
                    }
                } catch {
                    // The long-input manager path owns stream failure. Its
                    // transcription error is handled by the request below.
                }
            }
        } else {
            progressTask = nil
        }

        func drainProgressObserver() async {
            // For an observed long request, FluidAudio naturally finishes or
            // fails the stream before `transcribe` returns or throws. Draining
            // avoids late callbacks without cancelling and poisoning its cached
            // stream storage.
            _ = await progressTask?.value
        }

        do {
            let result = try await manager.transcribe(audioURL, source: .microphone)
            await drainProgressObserver()
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            log.log("[ParakeetContext] ✅ Done in \(String(format: "%.2f", elapsed))s — \(text.count) chars")
            guard !text.isEmpty else { return nil }
            return ParakeetTranscriptionOutput(
                text: text,
                segments: Self.timedWords(from: result.tokenTimings ?? [])
            )
        } catch is CancellationError {
            await drainProgressObserver()
            throw CancellationError()
        } catch {
            await drainProgressObserver()
            log.log("[ParakeetContext] ❌ Transcription failed: \(error)")
            return nil
        }
    }

    private static func timedWords(from timings: [TokenTiming]) -> [TimedTranscriptionSegment] {
        var words: [TimedTranscriptionSegment] = []
        var text = ""
        var start = 0.0
        var end = 0.0

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            words.append(TimedTranscriptionSegment(
                text: trimmed,
                startTime: max(0, start),
                endTime: max(end, start + 0.01)
            ))
        }

        for timing in timings {
            let token = timing.token
            guard !token.isEmpty, token != "<blank>", token != "<pad>" else { continue }
            let startsWord = token.hasPrefix("▁") || token.first?.isWhitespace == true
            if startsWord, !text.isEmpty {
                flush()
                text = ""
            }
            let clean = token
                .trimmingCharacters(in: CharacterSet(charactersIn: "▁"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            if text.isEmpty { start = timing.startTime }
            text += clean
            end = timing.endTime
        }
        flush()
        return words
    }
}
#endif
