import Foundation
import FluidAudio

private let log = KeyboardDebugLog.shared

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

    private init(manager: AsrManager) {
        self.manager = manager
    }

    // MARK: - Factory

    /// Load a Parakeet model.
    ///
    /// - Parameters:
    ///   - modelsDirectory:  The shared App Group models directory
    ///                       (``AppConstants.modelsDirectoryURL``).  The CoreML repo folder
    ///                       (`parakeet-tdt-0.6b-v?-coreml`) must already exist inside it.
    ///   - engine:           `.parakeetV2` or `.parakeetV3`
    /// - Returns: A ready-to-use `ParakeetContext`, or `nil` if models are missing / corrupt.
    public static func load(
        modelsDirectory: URL,
        engine: ModelEngine
    ) async -> ParakeetContext? {
        guard engine.isParakeet,
              let folderName = engine.parakeetRepoFolderName else {
            log.log("[ParakeetContext] ❌ Invalid engine: \(engine.rawValue)")
            return nil
        }

        let version: AsrModelVersion = (engine == .parakeetV2) ? .v2 : .v3
        let repoDir = modelsDirectory.appendingPathComponent(folderName)

        log.log("[ParakeetContext] Loading \(folderName)…")
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            // AsrModels.load(from:) takes the repo directory; it derives the parent
            // automatically and calls DownloadUtils.loadModels (which skips downloads
            // when all .mlmodelc files are already present).
            let models = try await AsrModels.load(
                from: repoDir,
                version: version
            )

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

    // MARK: - Transcription

    /// Transcribe audio from a 16 kHz mono WAV file.
    /// - Returns: The transcribed text, or `nil` if the audio is silent / transcription fails.
    public func transcribe(audioURL: URL) async -> String? {
        log.log("[ParakeetContext] transcribe() — \(audioURL.lastPathComponent)")
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let result = try await manager.transcribe(audioURL, source: .microphone)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            log.log("[ParakeetContext] ✅ Done in \(String(format: "%.2f", elapsed))s — \"\(text.prefix(60))\"")
            return text.isEmpty ? nil : text
        } catch {
            log.log("[ParakeetContext] ❌ Transcription failed: \(error)")
            return nil
        }
    }
}
