import Foundation
import whisper

/// Swift wrapper around the whisper.cpp C API.
/// Runs transcription on whatever thread it's called from — call from a background thread.
///
/// Usage:
///   let ctx = WhisperContext(modelPath: "/path/to/ggml-base.bin")
///   let text = ctx?.transcribe(audioURL: recordingURL, language: "en")
///
public final class WhisperContext: @unchecked Sendable {
    private var context: OpaquePointer

    /// - Parameters:
    ///   - modelPath: Path to the ggml model file
    ///   - useGPU: Enable Metal acceleration (set `false` in keyboard extensions to reduce memory)
    ///   - flashAttn: Use flash attention (lower memory for attention computation)
    public init?(modelPath: String, useGPU: Bool = true, flashAttn: Bool = false) {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = useGPU
        cparams.flash_attn = flashAttn

        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            print("[WhisperContext] Failed to load model at: \(modelPath)")
            return nil
        }
        self.context = ctx
    }

    deinit {
        whisper_free(context)
    }

    // MARK: - Transcription

    /// Transcribe audio from a 16 kHz mono PCM WAV file.
    /// - Parameters:
    ///   - audioURL: Path to the .wav recording
    ///   - language: ISO 639-1 code ("en", "es", etc.) or "auto" for detection
    ///   - maxThreads: Cap on compute threads (use 2 in extensions to reduce memory)
    /// - Returns: The transcribed text, or nil on failure
    public func transcribe(audioURL: URL, language: String = "auto", maxThreads: Int? = nil) -> String? {
        guard let samples = loadAudioSamples(from: audioURL) else {
            print("[WhisperContext] Failed to load audio from: \(audioURL.path)")
            return nil
        }

        guard !samples.isEmpty else {
            print("[WhisperContext] Audio file is empty")
            return nil
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        let cpuThreads = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        params.n_threads = Int32(min(maxThreads ?? cpuThreads, cpuThreads))
        params.translate = false
        params.no_timestamps = true
        params.single_segment = false
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false

        // Language handling: nil = auto-detect
        let languageCStr: UnsafeMutablePointer<CChar>? = (language == "auto") ? nil : strdup(language)
        defer { languageCStr.map { free($0) } }
        params.language = UnsafePointer(languageCStr)

        let result = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }

        guard result == 0 else {
            print("[WhisperContext] Transcription failed with code: \(result)")
            return nil
        }

        let nSegments = whisper_full_n_segments(context)
        var transcription = ""

        for i in 0..<nSegments {
            if let cText = whisper_full_get_segment_text(context, i) {
                transcription += String(cString: cText)
            }
        }

        let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Audio Loading

    /// Reads a 16-bit PCM WAV file and converts to Float32 samples normalized to [-1, 1].
    private func loadAudioSamples(from url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        // WAV header is 44 bytes for standard PCM
        guard data.count > 44 else { return nil }
        let audioData = data.subdata(in: 44..<data.count)

        let sampleCount = audioData.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)

        audioData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = Float(int16Buffer[i]) / 32768.0
            }
        }

        return samples
    }
}
