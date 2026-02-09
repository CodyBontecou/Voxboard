import AVFoundation
import Foundation
import UIKit
import VoxVaultShared

private let log = KeyboardDebugLog.shared

/// Always-on audio recorder that captures microphone input into a circular buffer.
///
/// The keyboard extension controls transcription segments via IPC commands:
/// - `startSegment`: marks the beginning of a transcription segment
/// - `stopSegment`: extracts audio from the marked start to now, transcribes it
///
/// The app only needs to be opened once to start listening. After that, the user
/// never leaves their current app — everything is controlled from the keyboard.
@Observable
final class PersistentRecorder {

    // MARK: - Public State

    var isListening: Bool = false
    var isSegmentActive: Bool = false
    var isTranscribing: Bool = false
    var segmentDuration: TimeInterval = 0
    var lastError: String?

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?

    /// Circular buffer: 10 minutes at 16 kHz mono = 9,600,000 samples ≈ 38 MB
    private let circularBuffer = CircularAudioBuffer(capacity: 16_000 * 60 * 10)

    /// Target sample rate for whisper.cpp
    private let whisperSampleRate: Double = 16_000

    // MARK: - Segment Tracking

    /// Absolute sample index where the current segment starts (in the circular buffer).
    private var segmentStartIndex: Int64 = 0
    private var segmentRequestId: String?
    private var segmentModelId: String?
    private var segmentLanguage: String?
    private var segmentStartedAt: TimeInterval = 0

    /// Pre-roll: capture this many seconds before the user tapped Start.
    private let preRollSeconds: TimeInterval = 2.0

    // MARK: - Timers

    private var durationTimer: Timer?

    /// Shared transcript store — injected so saved transcripts appear in the UI immediately.
    private let transcriptStore: TranscriptStore

    // MARK: - Init

    init(transcriptStore: TranscriptStore) {
        self.transcriptStore = transcriptStore
        ensureRecordingsDirectory()
    }

    deinit {
        stopListening()
        unregisterCommandObserver()
    }

    // MARK: - Start / Stop Listening

    /// Start the always-on microphone capture. Call once from the main app.
    @discardableResult
    func startListening() -> Bool {
        guard !isListening else {
            log.log("[PersistentRecorder] Already listening")
            return true
        }

        let session = AVAudioSession.sharedInstance()

        // Check permission
        let perm = session.recordPermission
        log.log("[PersistentRecorder] startListening — permission=\(perm == .granted ? "granted" : "other"), inputAvailable=\(session.isInputAvailable)")

        guard perm == .granted else {
            log.log("[PersistentRecorder] ❌ Mic permission not granted")
            lastError = "Microphone permission required"
            return false
        }

        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setActive(true)
            log.log("[PersistentRecorder] Audio session active")
        } catch {
            log.log("[PersistentRecorder] ❌ Session setup failed: \(error)")
            lastError = "Audio session error"
            return false
        }

        // Set up AVAudioEngine
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        log.log("[PersistentRecorder] Input format: \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount) ch")

        // Create converter if needed (hardware format → 16kHz mono)
        let needsConversion = hwFormat.sampleRate != whisperSampleRate || hwFormat.channelCount != 1

        var converter: AVAudioConverter?
        var targetFormat: AVAudioFormat?

        if needsConversion {
            targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: whisperSampleRate,
                channels: 1,
                interleaved: false
            )
            if let tf = targetFormat {
                converter = AVAudioConverter(from: hwFormat, to: tf)
                log.log("[PersistentRecorder] Converter created: \(hwFormat.sampleRate)Hz → \(whisperSampleRate)Hz")
            }
        }

        // Reset buffer
        circularBuffer.reset()

        // Install tap — capture audio and write to circular buffer
        let bufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }

            if let converter, let targetFormat {
                // Convert to 16kHz mono
                let ratio = self.whisperSampleRate / hwFormat.sampleRate
                let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrames) else { return }

                var consumed = false
                converter.convert(to: outputBuffer, error: nil) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }

                if let floatData = outputBuffer.floatChannelData?[0], outputBuffer.frameLength > 0 {
                    let ptr = UnsafeBufferPointer(start: floatData, count: Int(outputBuffer.frameLength))
                    self.circularBuffer.append(ptr)
                }
            } else {
                // Already 16kHz mono — direct append
                if let floatData = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                    let ptr = UnsafeBufferPointer(start: floatData, count: Int(buffer.frameLength))
                    self.circularBuffer.append(ptr)
                }
            }
        }

        do {
            try engine.start()
            log.log("[PersistentRecorder] ✅ AVAudioEngine started — always-on listening active")
        } catch {
            log.log("[PersistentRecorder] ❌ Engine start failed: \(error)")
            inputNode.removeTap(onBus: 0)
            lastError = "Microphone error"
            return false
        }

        audioEngine = engine
        isListening = true
        lastError = nil

        // Write listening state for the keyboard to read
        TranscriptionIPC.writeListeningState(ListeningState(
            isListening: true,
            startedAt: Date().timeIntervalSince1970
        ))
        TranscriptionIPC.postListeningStateNotification()

        // Start listening for commands from the keyboard
        registerCommandObserver()

        // Persist preference
        AppConstants.sharedDefaults?.set(true, forKey: "autoListenEnabled")

        log.log("[PersistentRecorder] ✅ Listening started, waiting for keyboard commands")
        return true
    }

    /// Stop the always-on capture.
    func stopListening() {
        guard isListening else { return }

        log.log("[PersistentRecorder] Stopping listening…")

        // Cancel any active segment
        if isSegmentActive {
            cancelSegment()
        }

        // Stop engine
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        isListening = false

        // Deactivate audio session
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        // Update IPC
        TranscriptionIPC.writeListeningState(ListeningState(isListening: false))
        TranscriptionIPC.postListeningStateNotification()

        unregisterCommandObserver()

        log.log("[PersistentRecorder] ✅ Listening stopped")
    }

    // MARK: - Segment Control

    /// Mark the start of a transcription segment.
    private func handleStartSegment(_ command: RecordingCommand) {
        guard isListening else {
            log.log("[PersistentRecorder] ❌ startSegment but not listening")
            return
        }

        guard !isSegmentActive else {
            log.log("[PersistentRecorder] ⚠️ startSegment but segment already active")
            return
        }

        log.log("[PersistentRecorder] 🎙 Starting segment: \(command.requestId)")

        // Calculate start index with pre-roll
        let preRollSamples = Int64(preRollSeconds * whisperSampleRate)
        let currentIndex = circularBuffer.totalSamplesWritten
        let earliest = circularBuffer.earliestAvailableIndex
        segmentStartIndex = max(currentIndex - preRollSamples, earliest)

        segmentRequestId = command.requestId
        segmentModelId = command.modelId
        segmentLanguage = command.language
        segmentStartedAt = Date().timeIntervalSince1970
        isSegmentActive = true
        segmentDuration = 0

        // Start duration timer
        startDurationTimer()

        // Write status for keyboard
        TranscriptionIPC.writeStatus(RecordingStatus(
            requestId: command.requestId,
            phase: .recording,
            recordingStartedAt: segmentStartedAt
        ))

        log.log("[PersistentRecorder] ✅ Segment started at buffer index \(segmentStartIndex) (pre-roll: \(preRollSamples) samples)")
    }

    /// Mark the end of a segment — extract audio and transcribe.
    private func handleStopSegment(_ command: RecordingCommand) {
        guard isSegmentActive else {
            log.log("[PersistentRecorder] ⚠️ stopSegment but no active segment")
            return
        }

        let requestId = segmentRequestId ?? command.requestId
        log.log("[PersistentRecorder] ⏹ Stopping segment: \(requestId)")

        stopDurationTimer()
        isSegmentActive = false

        // Extract audio from the circular buffer
        let endIndex = circularBuffer.totalSamplesWritten
        guard let samples = circularBuffer.extract(from: segmentStartIndex, to: endIndex) else {
            log.log("[PersistentRecorder] ❌ Could not extract audio — data was overwritten")
            writeErrorResponse(requestId: requestId, message: "Audio buffer overwritten — try a shorter recording")
            return
        }

        let durationSec = Float(samples.count) / Float(whisperSampleRate)
        log.log("[PersistentRecorder] Extracted \(samples.count) samples (\(String(format: "%.1f", durationSec))s)")

        guard samples.count > Int(whisperSampleRate * 0.3) else {
            log.log("[PersistentRecorder] ⚠️ Segment too short (<0.3s)")
            writeErrorResponse(requestId: requestId, message: "Recording too short")
            return
        }

        // Check audio isn't silent
        let maxAmp = samples.map { abs($0) }.max() ?? 0
        log.log("[PersistentRecorder] Audio maxAmp=\(String(format: "%.4f", maxAmp))")
        if maxAmp < 0.005 {
            log.log("[PersistentRecorder] ⚠️ Audio appears silent")
            writeErrorResponse(requestId: requestId, message: "No speech detected")
            return
        }

        // Write WAV file
        guard let wavURL = writeWAV(samples: samples) else {
            writeErrorResponse(requestId: requestId, message: "Failed to save audio")
            return
        }

        log.log("[PersistentRecorder] WAV written: \(wavURL.lastPathComponent)")

        // Update status to transcribing
        isTranscribing = true
        TranscriptionIPC.writeStatus(RecordingStatus(
            requestId: requestId,
            phase: .transcribing
        ))

        // Transcribe
        let modelId = segmentModelId ?? command.modelId ?? AppConstants.defaultModelName
        let language = segmentLanguage ?? command.language ?? "auto"
        let duration = TimeInterval(durationSec)

        // Request background time
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask {
            log.log("[PersistentRecorder] ⚠️ Background task expired")
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.transcribe(
                audioURL: wavURL,
                modelId: modelId,
                language: language,
                requestId: requestId,
                duration: duration
            )

            await MainActor.run {
                self?.isTranscribing = false
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                }
            }
        }

        // Clear segment state
        segmentRequestId = nil
        segmentModelId = nil
        segmentLanguage = nil
    }

    /// Cancel an active segment without transcribing.
    func cancelSegment() {
        guard isSegmentActive else { return }
        log.log("[PersistentRecorder] Cancelling segment")

        stopDurationTimer()
        isSegmentActive = false
        segmentRequestId = nil
        segmentModelId = nil
        segmentLanguage = nil
        segmentDuration = 0

        TranscriptionIPC.clearStatus()
    }

    // MARK: - Transcription

    private func transcribe(audioURL: URL, modelId: String, language: String, requestId: String, duration: TimeInterval) async {
        // Resolve model
        guard let model = WhisperModelInfo.availableModels.first(where: { $0.id == modelId }),
              let modelPath = model.localURL?.path,
              FileManager.default.fileExists(atPath: modelPath) else {
            log.log("[PersistentRecorder] ❌ Model not found: \(modelId)")
            await MainActor.run { writeErrorResponse(requestId: requestId, message: "Model not found") }
            return
        }

        log.log("[PersistentRecorder] Loading model: \(model.name) (CPU-only)…")

        // Always CPU — app may be backgrounded when keyboard triggers this
        guard let ctx = WhisperContext(modelPath: modelPath, useGPU: false) else {
            log.log("[PersistentRecorder] ❌ Model load failed")
            await MainActor.run { writeErrorResponse(requestId: requestId, message: "Model load failed") }
            return
        }

        log.log("[PersistentRecorder] Transcribing…")
        let text = ctx.transcribe(audioURL: audioURL, language: language)
        log.log("[PersistentRecorder] Result: \(text?.count ?? 0) chars")

        await MainActor.run {
            if let text, !text.isEmpty {
                let response = TranscriptionResponse(requestId: requestId, text: text)
                try? TranscriptionIPC.writeResponse(response)
                TranscriptionIPC.postResponseNotification()

                TranscriptionIPC.writeStatus(RecordingStatus(
                    requestId: requestId,
                    phase: .done
                ))

                // Save to history (uses shared store so UI updates immediately)
                let transcript = Transcript(
                    text: text,
                    duration: duration,
                    modelUsed: model.name,
                    language: language
                )
                self.transcriptStore.add(transcript)

                log.log("[PersistentRecorder] ✅ Transcription complete: \(text.count) chars")
            } else {
                writeErrorResponse(requestId: requestId, message: "No speech detected")
            }
        }

        // Clean up WAV file
        try? FileManager.default.removeItem(at: audioURL)
    }

    // MARK: - WAV Writing

    private func writeWAV(samples: [Float]) -> URL? {
        guard let dir = AppConstants.recordingsDirectoryURL else { return nil }
        let url = dir.appendingPathComponent("segment_\(UUID().uuidString).wav")

        // Convert Float32 → Int16
        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * 32767.0)
        }

        let dataSize = int16Samples.count * 2
        let fileSize = 36 + dataSize
        let sampleRate = UInt32(whisperSampleRate)

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.appendUInt32LE(UInt32(fileSize))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.appendUInt32LE(16)                    // fmt chunk size
        header.appendUInt16LE(1)                     // PCM format
        header.appendUInt16LE(1)                     // mono
        header.appendUInt32LE(sampleRate)            // sample rate
        header.appendUInt32LE(sampleRate * 2)        // byte rate
        header.appendUInt16LE(2)                     // block align
        header.appendUInt16LE(16)                    // bits per sample
        header.append(contentsOf: "data".utf8)
        header.appendUInt32LE(UInt32(dataSize))

        var fileData = header
        int16Samples.withUnsafeBufferPointer { buffer in
            fileData.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UInt8.self),
                count: dataSize
            ))
        }

        do {
            try fileData.write(to: url, options: .atomic)
            return url
        } catch {
            log.log("[PersistentRecorder] ❌ WAV write failed: \(error)")
            return nil
        }
    }

    // MARK: - IPC Command Listener

    private func registerCommandObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        // Listen for new-style commands (startSegment, stopSegment)
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let recorder = Unmanaged<PersistentRecorder>
                    .fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { recorder.handleCommandIfNeeded() }
            },
            TranscriptionIPC.commandNotificationName,
            nil,
            .deliverImmediately
        )

        // Also listen for legacy stop commands (backward compat)
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let recorder = Unmanaged<PersistentRecorder>
                    .fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { recorder.handleCommandIfNeeded() }
            },
            TranscriptionIPC.stopCommandNotificationName,
            nil,
            .deliverImmediately
        )

        log.log("[PersistentRecorder] Registered command observers")
    }

    private func unregisterCommandObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterRemoveObserver(
            center, observer,
            CFNotificationName(TranscriptionIPC.commandNotificationName),
            nil
        )
        CFNotificationCenterRemoveObserver(
            center, observer,
            CFNotificationName(TranscriptionIPC.stopCommandNotificationName),
            nil
        )
    }

    @MainActor
    private func handleCommandIfNeeded() {
        guard let command = TranscriptionIPC.readCommand() else { return }

        log.log("[PersistentRecorder] Received command: \(command.action.rawValue) (requestId=\(command.requestId))")
        TranscriptionIPC.clearCommand()

        switch command.action {
        case .startSegment:
            handleStartSegment(command)

        case .stopSegment, .stop:
            handleStopSegment(command)
        }
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        stopDurationTimer()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = Optional(self.segmentStartedAt), self.isSegmentActive else { return }
                self.segmentDuration = Date().timeIntervalSince1970 - startedAt
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // MARK: - Helpers

    private func writeErrorResponse(requestId: String, message: String) {
        log.log("[PersistentRecorder] ❌ \(message)")
        let response = TranscriptionResponse(requestId: requestId, error: message)
        try? TranscriptionIPC.writeResponse(response)
        TranscriptionIPC.postResponseNotification()
        TranscriptionIPC.writeStatus(RecordingStatus(
            requestId: requestId,
            phase: .error,
            message: message
        ))
    }

    private func ensureRecordingsDirectory() {
        guard let dir = AppConstants.recordingsDirectoryURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

// MARK: - Data Helpers for WAV Writing

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
