import AVFoundation
import Foundation

private let log = KeyboardDebugLog.shared

/// Records audio as 16 kHz mono 16-bit PCM WAV — the format whisper.cpp expects.
///
/// Uses `AVAudioEngine` with an input node tap instead of `AVAudioRecorder`,
/// because `AVAudioRecorder.record()` returns `false` in keyboard extensions
/// even when microphone permission is granted and Full Access is enabled.
@Observable
public final class AudioRecorder: NSObject, @unchecked Sendable {
    public var isRecording = false
    public var recordingDuration: TimeInterval = 0

    private var audioEngine: AVAudioEngine?
    private var pcmBuffers: [AVAudioPCMBuffer] = []
    private let bufferLock = NSLock()
    private var timer: Timer?
    private var startTime: Date?

    /// Target format for whisper.cpp: 16 kHz, mono, 16-bit integer PCM.
    private let whisperSampleRate: Double = 16000.0

    public var recordingURL: URL? {
        guard let dir = AppConstants.recordingsDirectoryURL else { return nil }
        return dir.appendingPathComponent("recording.wav")
    }

    public override init() {
        super.init()
        ensureDirectory()
    }

    // MARK: - Recording

    @discardableResult
    public func startRecording() -> Bool {
        guard let url = recordingURL else {
            log.log("[AudioRecorder] No recording URL available")
            return false
        }

        let session = AVAudioSession.sharedInstance()

        // Log permission & input status
        let permStatus = session.recordPermission
        let permString = permStatus == .granted ? "granted" : permStatus == .denied ? "DENIED" : "undetermined"
        log.log("[AudioRecorder] permission=\(permString), inputAvailable=\(session.isInputAvailable)")

        // Request permission if undetermined
        if permStatus == .undetermined {
            log.log("[AudioRecorder] Permission undetermined — requesting…")
            var granted = false
            let semaphore = DispatchSemaphore(value: 0)
            session.requestRecordPermission { result in
                granted = result
                semaphore.signal()
            }
            semaphore.wait()
            log.log("[AudioRecorder] Permission request result: \(granted)")
            if !granted { return false }
        } else if permStatus == .denied {
            log.log("[AudioRecorder] ❌ Mic permission denied")
            return false
        }

        do {
            // Use .playAndRecord so the audio session stays active when the app
            // goes to the background (required for background recording via
            // UIBackgroundModes: audio). The .mixWithOthers option prevents
            // interrupting other audio.
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            log.log("[AudioRecorder] Audio session active (playAndRecord)")
        } catch {
            log.log("[AudioRecorder] ❌ Session setup failed: \(error)")
            return false
        }

        // Delete stale recording file
        try? FileManager.default.removeItem(at: url)

        // Set up AVAudioEngine with input tap
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        log.log("[AudioRecorder] Input node format: \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount) ch")

        // Clear previous buffers
        bufferLock.lock()
        pcmBuffers.removeAll()
        bufferLock.unlock()

        // Install tap — capture audio buffers from the mic
        let bufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.bufferLock.lock()
            self.pcmBuffers.append(buffer)
            self.bufferLock.unlock()
        }

        do {
            try engine.start()
            log.log("[AudioRecorder] ✅ AVAudioEngine started")
        } catch {
            log.log("[AudioRecorder] ❌ Engine start failed: \(error)")
            inputNode.removeTap(onBus: 0)
            return false
        }

        audioEngine = engine
        isRecording = true
        startTime = Date()
        recordingDuration = 0

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let start = self.startTime else { return }
            self.recordingDuration = Date().timeIntervalSince(start)
        }

        return true
    }

    @discardableResult
    public func stopRecording() -> URL? {
        guard let engine = audioEngine else {
            log.log("[AudioRecorder] ⚠️ stopRecording called but no engine")
            return nil
        }

        // Stop engine and remove tap
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil

        timer?.invalidate()
        timer = nil
        isRecording = false

        // Collect captured buffers
        bufferLock.lock()
        let capturedBuffers = pcmBuffers
        pcmBuffers.removeAll()
        bufferLock.unlock()

        let totalFrames = capturedBuffers.reduce(0) { $0 + Int($1.frameLength) }
        log.log("[AudioRecorder] Captured \(capturedBuffers.count) buffers, \(totalFrames) frames, duration=\(String(format: "%.1f", recordingDuration))s")

        guard totalFrames > 0 else {
            log.log("[AudioRecorder] ⚠️ No audio frames captured")
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return nil
        }

        // Convert to 16 kHz mono Int16 and write WAV
        guard let url = recordingURL else { return nil }
        let hwFormat = capturedBuffers[0].format

        let success = writeWAV(
            to: url,
            buffers: capturedBuffers,
            sourceFormat: hwFormat,
            targetSampleRate: whisperSampleRate
        )

        if success {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
            log.log("[AudioRecorder] ✅ WAV written: \(size) bytes")
        } else {
            log.log("[AudioRecorder] ❌ Failed to write WAV")
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        return success ? url : nil
    }

    // MARK: - WAV Writing

    /// Convert captured PCM buffers to 16 kHz mono 16-bit WAV file.
    private func writeWAV(
        to url: URL,
        buffers: [AVAudioPCMBuffer],
        sourceFormat: AVAudioFormat,
        targetSampleRate: Double
    ) -> Bool {
        // Create target format: 16 kHz, mono, Float32 (for the converter)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            log.log("[AudioRecorder] ❌ Could not create target format")
            return false
        }

        // Collect all samples converted to target format
        var allSamples: [Float] = []

        if sourceFormat.sampleRate == targetSampleRate && sourceFormat.channelCount == 1 {
            // No conversion needed — just collect Float32 samples
            for buffer in buffers {
                if let floatData = buffer.floatChannelData?[0] {
                    let count = Int(buffer.frameLength)
                    allSamples.append(contentsOf: UnsafeBufferPointer(start: floatData, count: count))
                }
            }
        } else {
            // Need sample rate / channel conversion
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                log.log("[AudioRecorder] ❌ Could not create audio converter from \(sourceFormat.sampleRate)Hz/\(sourceFormat.channelCount)ch")
                return false
            }

            for buffer in buffers {
                let ratio = targetSampleRate / sourceFormat.sampleRate
                let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrames) else {
                    continue
                }

                var error: NSError?
                var consumed = false
                converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }

                if let error {
                    log.log("[AudioRecorder] ⚠️ Conversion error: \(error)")
                    continue
                }

                if let floatData = outputBuffer.floatChannelData?[0] {
                    let count = Int(outputBuffer.frameLength)
                    allSamples.append(contentsOf: UnsafeBufferPointer(start: floatData, count: count))
                }
            }
        }

        log.log("[AudioRecorder] Converted: \(allSamples.count) samples at \(Int(targetSampleRate)) Hz")

        // Log audio diagnostics
        if !allSamples.isEmpty {
            let maxAmp = allSamples.map { abs($0) }.max() ?? 0
            let rms = sqrt(allSamples.map { $0 * $0 }.reduce(0, +) / Float(allSamples.count))
            log.log("[AudioRecorder] Audio maxAmp=\(String(format: "%.4f", maxAmp)) RMS=\(String(format: "%.4f", rms))")
            if maxAmp < 0.01 {
                log.log("[AudioRecorder] ⚠️ Audio appears SILENT (maxAmp < 0.01)")
            }
        }

        // Convert Float32 → Int16
        let int16Samples = allSamples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * 32767.0)
        }

        // Write WAV file
        let dataSize = int16Samples.count * 2
        let fileSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(uint32LE: UInt32(fileSize))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(uint32LE: 16)                         // fmt chunk size
        header.append(uint16LE: 1)                          // PCM format
        header.append(uint16LE: 1)                          // mono
        header.append(uint32LE: UInt32(targetSampleRate))   // sample rate
        header.append(uint32LE: UInt32(targetSampleRate) * 2) // byte rate
        header.append(uint16LE: 2)                          // block align
        header.append(uint16LE: 16)                         // bits per sample
        header.append(contentsOf: "data".utf8)
        header.append(uint32LE: UInt32(dataSize))

        var fileData = header
        int16Samples.withUnsafeBufferPointer { buffer in
            fileData.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UInt8.self),
                count: dataSize
            ))
        }

        do {
            try fileData.write(to: url, options: .atomic)
            return true
        } catch {
            log.log("[AudioRecorder] ❌ File write failed: \(error)")
            return false
        }
    }

    // MARK: - Microphone Permission

    public static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Helpers

    private func ensureDirectory() {
        guard let dir = AppConstants.recordingsDirectoryURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

// MARK: - Data Helpers for WAV Writing

private extension Data {
    mutating func append(uint16LE value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(uint32LE value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
