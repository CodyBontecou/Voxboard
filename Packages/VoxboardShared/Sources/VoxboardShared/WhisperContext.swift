#if os(iOS) || os(macOS)
import Foundation
import whisper

private let log = KeyboardDebugLog.shared

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

        log.log("[WhisperContext] Loading model: \(modelPath) (gpu=\(useGPU), flashAttn=\(flashAttn))")
        let startTime = CFAbsoluteTimeGetCurrent()

        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            log.log("[WhisperContext] ❌ Failed to load model at: \(modelPath)")
            print("[WhisperContext] Failed to load model at: \(modelPath)")
            return nil
        }
        self.context = ctx

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        log.log("[WhisperContext] ✅ Model loaded in \(String(format: "%.2f", elapsed))s")
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
        log.log("[WhisperContext] transcribe() — audio=\(audioURL.lastPathComponent), lang=\(language)")

        guard let samples = loadAudioSamples(from: audioURL) else {
            log.log("[WhisperContext] ❌ Failed to load audio from: \(audioURL.path)")
            print("[WhisperContext] Failed to load audio from: \(audioURL.path)")
            return nil
        }

        guard !samples.isEmpty else {
            log.log("[WhisperContext] ❌ Audio file is empty")
            print("[WhisperContext] Audio file is empty")
            return nil
        }

        log.log("[WhisperContext] Loaded \(samples.count) samples (\(String(format: "%.1f", Float(samples.count) / 16000.0))s)")

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

        log.log("[WhisperContext] Starting whisper_full (threads=\(params.n_threads), samples=\(samples.count))…")
        let startTime = CFAbsoluteTimeGetCurrent()

        let result = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        log.log("[WhisperContext] whisper_full completed in \(String(format: "%.2f", elapsed))s — result=\(result)")

        guard result == 0 else {
            log.log("[WhisperContext] ❌ Transcription failed with code: \(result)")
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
        log.log("[WhisperContext] Raw transcription (\(nSegments) segments): \"\(trimmed)\"")
        print("[WhisperContext] Raw transcription (\(nSegments) segments): \"\(trimmed)\"")

        guard !trimmed.isEmpty else { return nil }

        // Filter out common whisper hallucinations on silent/noisy audio
        if Self.isHallucination(trimmed) {
            log.log("[WhisperContext] ⚠️ Filtered hallucination: \"\(trimmed)\"")
            print("[WhisperContext] Filtered hallucination: \"\(trimmed)\"")
            return nil
        }

        log.log("[WhisperContext] ✅ Transcription result: \"\(trimmed)\"")
        return trimmed
    }

    // MARK: - Hallucination Filtering

    /// Whisper commonly hallucinates these phrases when given silent or near-silent audio.
    private static let hallucinationPatterns: [String] = [
        "(silence)",
        "[silence]",
        "(silent)",
        "[silent]",
        "(blank audio)",
        "[blank_audio]",
        "[blank audio]",
        "(no speech)",
        "[no speech]",
        "(music)",
        "[music]",
        "(music playing)",
        "[music playing]",
        "(background noise)",
        "(white noise)",
        "(static)",
        "(inaudible)",
        "[inaudible]",
        "thank you.",
        "thanks for watching.",
        "thanks for watching!",
        "thank you for watching.",
        "thank you for watching!",
        "subscribe",
        "you",
        "...",
    ]

    private static func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Exact match against known hallucinations
        if hallucinationPatterns.contains(lower) { return true }
        // Bracketed/parenthesized text only (e.g., "[Music]", "(Silence)")
        if lower.hasPrefix("(") && lower.hasSuffix(")") && lower.count < 40 { return true }
        if lower.hasPrefix("[") && lower.hasSuffix("]") && lower.count < 40 { return true }
        return false
    }

    // MARK: - Audio Loading

    /// Reads a 16-bit PCM WAV file and converts to Float32 samples normalized to [-1, 1].
    /// Properly parses RIFF/WAV chunks to find the "data" chunk instead of assuming a
    /// fixed header size, since AVAudioRecorder may insert extra chunks (fact, LIST, etc.).
    private func loadAudioSamples(from url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url) else {
            log.log("[WhisperContext] ❌ Could not read file: \(url.path)")
            print("[WhisperContext] Could not read file: \(url.path)")
            return nil
        }

        log.log("[WhisperContext] WAV file size: \(data.count) bytes")
        print("[WhisperContext] WAV file size: \(data.count) bytes")

        // Minimum RIFF header: 12 bytes (RIFF + size + WAVE)
        guard data.count > 12 else {
            print("[WhisperContext] File too small for WAV header")
            return nil
        }

        // Find the "data" chunk by walking RIFF chunks
        guard let dataRange = findDataChunk(in: data) else {
            print("[WhisperContext] Could not find 'data' chunk in WAV — falling back to offset 44")
            // Fallback to legacy behavior
            guard data.count > 44 else { return nil }
            return parsePCMSamples(from: data.subdata(in: 44..<data.count))
        }

        print("[WhisperContext] Found 'data' chunk at offset \(dataRange.lowerBound), length \(dataRange.count) bytes")
        let audioData = data.subdata(in: dataRange)
        return parsePCMSamples(from: audioData)
    }

    /// Walk RIFF/WAV chunks to locate the "data" chunk.
    /// Returns the byte range of the raw PCM data (excluding the chunk header).
    private func findDataChunk(in data: Data) -> Range<Int>? {
        // Verify RIFF header
        guard data.count >= 12,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            return nil
        }

        var offset = 12 // Skip past "RIFF" + size + "WAVE"

        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<offset+4], encoding: .ascii) ?? "????"
            let chunkSize = data.withUnsafeBytes { buf in
                buf.load(fromByteOffset: offset + 4, as: UInt32.self)
            }
            let size = Int(chunkSize)

            print("[WhisperContext] WAV chunk: '\(chunkID)' size=\(size) at offset \(offset)")

            if chunkID == "data" {
                let dataStart = offset + 8
                let dataEnd = min(dataStart + size, data.count)
                return dataStart..<dataEnd
            }

            // Advance to next chunk (chunks are word-aligned)
            offset += 8 + size
            if offset % 2 != 0 { offset += 1 } // pad byte
        }

        return nil
    }

    /// Convert raw 16-bit little-endian PCM bytes to Float32 samples in [-1, 1].
    private func parsePCMSamples(from audioData: Data) -> [Float] {
        let sampleCount = audioData.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)

        audioData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = Float(int16Buffer[i]) / 32768.0
            }
        }

        // Log audio diagnostics
        if !samples.isEmpty {
            let maxAmp = samples.map { abs($0) }.max() ?? 0
            let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
            let durationSec = Float(samples.count) / 16000.0
            print("[WhisperContext] Audio: \(samples.count) samples, \(String(format: "%.1f", durationSec))s, maxAmp=\(String(format: "%.4f", maxAmp)), RMS=\(String(format: "%.4f", rms))")
            if maxAmp < 0.01 {
                print("[WhisperContext] ⚠️ Audio appears SILENT (maxAmp < 0.01) — mic may not be capturing")
            }
        }

        return samples
    }
}
#endif
