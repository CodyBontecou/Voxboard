import AVFoundation
import Foundation
import os.log
import UIKit
import VoxboardShared

private let log = KeyboardDebugLog.shared
private let osLog = Logger(subsystem: "bontecou.Voxboard", category: "PersistentRecorder")

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

    /// Last transcription result from an in-app recording. Observable for UI display.
    var lastTranscriptionResult: String?

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?

    /// Circular buffer: 10 minutes at 16 kHz mono = 9,600,000 samples ≈ 38 MB
    private let circularBuffer = CircularAudioBuffer(capacity: 16_000 * 60 * 10)

    /// Target sample rate for whisper.cpp
    private let whisperSampleRate: Double = 16_000

    // MARK: - Cached Model

    /// Pre-loaded Whisper context — avoids cold model load on the first transcription.
    private var cachedWhisperContext: WhisperContext?
    /// Pre-loaded Parakeet context — avoids cold CoreML load on the first transcription.
    private var cachedParakeetContext: ParakeetContext?
    private var cachedModelId: String?
    private var isPreloadingModel: Bool = false

    // MARK: - Segment Tracking

    /// Absolute sample index where the current segment starts (in the circular buffer).
    private var segmentStartIndex: Int64 = 0
    private var segmentRequestId: String?
    private var segmentModelId: String?
    private var segmentLanguage: String?
    private var segmentStartedAt: TimeInterval = 0

    /// Pre-roll: capture this many seconds before the user tapped Start.
    private let preRollSeconds: TimeInterval = 2.0

    // MARK: - Audio Level Metering

    /// Throttle audio level writes to ~12 times per second max.
    private var lastLevelWriteTime: TimeInterval = 0
    private let levelWriteInterval: TimeInterval = 1.0 / 12.0

    // MARK: - Timers

    private var durationTimer: Timer?

    /// Shared transcript store — injected so saved transcripts appear in the UI immediately.
    private let transcriptStore: TranscriptStore

    /// Tracks cumulative usage for the free-tier paywall.
    private let usageTracker: UsageTracker

    /// Set to true when a transcription is blocked because the user has hit the free limit.
    /// Observed by HomeView to present the PaywallView.
    var needsUnlock: Bool = false

    // MARK: - Init

    init(transcriptStore: TranscriptStore, usageTracker: UsageTracker) {
        self.transcriptStore = transcriptStore
        self.usageTracker = usageTracker
        ensureRecordingsDirectory()

        // Clear any stale listening state left over from a previous session.
        // If the app was killed/crashed while listening, the IPC file still says
        // isListening=true. Clearing it here ensures the keyboard extension won't
        // try to record against a non-existent recorder and time out after 30s.
        TranscriptionIPC.writeListeningState(ListeningState(isListening: false))
        TranscriptionIPC.postListeningStateNotification()
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
                    self.writeAudioLevelIfNeeded(floatData, frameCount: Int(outputBuffer.frameLength))
                }
            } else {
                // Already 16kHz mono — direct append
                if let floatData = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                    let ptr = UnsafeBufferPointer(start: floatData, count: Int(buffer.frameLength))
                    self.circularBuffer.append(ptr)
                    self.writeAudioLevelIfNeeded(floatData, frameCount: Int(buffer.frameLength))
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

        // Pre-load the default whisper model so the first transcription is fast
        preloadModel()

        // Observe audio session interruptions so we can auto-restart the engine
        registerInterruptionObserver()

        log.log("[PersistentRecorder] ✅ Listening started, waiting for keyboard commands")
        return true
    }

    /// Pre-load the selected model in the background so it's ready for the first transcription.
    private func preloadModel() {
        guard !isPreloadingModel else { return }

        let modelId = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
            ?? AppConstants.defaultModelName

        // Skip if already cached with the right model
        if cachedModelId == modelId,
           (cachedWhisperContext != nil || cachedParakeetContext != nil) { return }

        isPreloadingModel = true
        log.log("[PersistentRecorder] Pre-loading model: \(modelId)…")

        Task.detached(priority: .utility) { [weak self] in
            guard let model = WhisperModelInfo.availableModels.first(where: { $0.id == modelId }),
                  let modelURL = model.localURL,
                  model.isDownloaded else {
                log.log("[PersistentRecorder] ⚠️ Pre-load skipped — model not found: \(modelId)")
                await MainActor.run { self?.isPreloadingModel = false }
                return
            }

            if model.engine.isParakeet {
                guard let modelsDir = AppConstants.modelsDirectoryURL else {
                    await MainActor.run { self?.isPreloadingModel = false }
                    return
                }
                let ctx = await ParakeetContext.load(modelsDirectory: modelsDir, engine: model.engine)
                await MainActor.run {
                    self?.isPreloadingModel = false
                    if let ctx {
                        self?.cachedParakeetContext = ctx
                        self?.cachedWhisperContext = nil
                        self?.cachedModelId = modelId
                        log.log("[PersistentRecorder] ✅ Parakeet pre-loaded: \(model.name)")
                    } else {
                        log.log("[PersistentRecorder] ⚠️ Parakeet pre-load failed")
                    }
                }
            } else {
                let ctx = WhisperContext(modelPath: modelURL.path, useGPU: false)
                await MainActor.run {
                    self?.isPreloadingModel = false
                    if let ctx {
                        self?.cachedWhisperContext = ctx
                        self?.cachedParakeetContext = nil
                        self?.cachedModelId = modelId
                        log.log("[PersistentRecorder] ✅ Whisper pre-loaded: \(model.name)")
                    } else {
                        log.log("[PersistentRecorder] ⚠️ Whisper pre-load failed")
                    }
                }
            }
        }
    }

    // MARK: - Audio Interruption Handling

    private func registerInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    private func removeInterruptionObserver() {
        NotificationCenter.default.removeObserver(
            self,
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            log.log("[PersistentRecorder] ⚠️ Audio interruption began")
            if isSegmentActive {
                cancelSegment()
            }

        case .ended:
            log.log("[PersistentRecorder] Audio interruption ended — restarting engine")
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionOptions(rawValue: $0) }

            if options?.contains(.shouldResume) ?? true {
                // Restart the audio engine
                if let engine = audioEngine {
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        try engine.start()
                        log.log("[PersistentRecorder] ✅ Audio engine restarted after interruption")
                    } catch {
                        log.log("[PersistentRecorder] ❌ Engine restart failed: \(error) — full restart")
                        stopListening()
                        startListening()
                    }
                }
            }

        @unknown default:
            break
        }
    }

    /// Stop the always-on capture.
    func stopListening() {
        guard isListening else { return }

        log.log("[PersistentRecorder] Stopping listening…")

        // Cancel any active segment
        if isSegmentActive {
            cancelSegment()
        }

        // Remove interruption observer
        removeInterruptionObserver()

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

    // MARK: - In-App Recording

    /// Start a recording segment directly from the app UI (no IPC needed).
    func startInAppSegment() {
        guard isListening else {
            lastError = "Start listening first"
            log.log("[PersistentRecorder] ❌ startInAppSegment but not listening")
            return
        }
        guard !isSegmentActive, !isTranscribing else {
            log.log("[PersistentRecorder] ⚠️ startInAppSegment skipped — segment active or transcribing")
            return
        }

        lastTranscriptionResult = nil
        lastError = nil

        let modelId = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
            ?? AppConstants.defaultModelName
        let language = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey)
            ?? "auto"
        let requestId = "inapp-\(UUID().uuidString)"

        let command = RecordingCommand(
            requestId: requestId,
            action: .startSegment,
            modelId: modelId,
            language: language
        )

        log.log("[PersistentRecorder] 🎙 In-app segment start: \(requestId)")
        handleStartSegment(command)
    }

    /// Stop the current in-app recording segment and transcribe.
    func stopInAppSegment() {
        guard isSegmentActive else {
            log.log("[PersistentRecorder] ⚠️ stopInAppSegment but no active segment")
            return
        }

        let requestId = segmentRequestId ?? "inapp-\(UUID().uuidString)"
        let command = RecordingCommand(requestId: requestId, action: .stopSegment)

        log.log("[PersistentRecorder] ⏹ In-app segment stop: \(requestId)")
        handleStopSegment(command)
    }

    // MARK: - Segment Control

    /// Fast start segment handler — runs on the high-priority command queue.
    /// Marks the buffer position and writes IPC status immediately, then
    /// dispatches UI state updates to main thread.
    private func handleStartSegmentFast(_ command: RecordingCommand) {
        guard isListening else {
            log.log("[PersistentRecorder] ❌ startSegment but not listening")
            osLog.error("❌ startSegment but not listening!")
            return
        }

        guard !isSegmentActive else {
            log.log("[PersistentRecorder] ⚠️ startSegment but segment already active")
            osLog.warning("⚠️ startSegment but segment already active")
            return
        }

        log.log("[PersistentRecorder] 🎙 Starting segment (fast path): \(command.requestId)")
        osLog.notice("🎙 Starting segment: \(command.requestId)")

        // Paywall check (re-checked on main thread in the dispatch below, but do a quick
        // static check here too so we can bail early on the background queue).
        if UsageTracker.staticIsAtLimit {
            log.log("[PersistentRecorder] 🔒 Fast-path: Free limit reached — blocking segment")
            DispatchQueue.main.async { [weak self] in
                self?.writeErrorResponse(requestId: command.requestId, message: "Free limit reached — open Voxboard to unlock")
                self?.needsUnlock = true
            }
            return
        }

        // CRITICAL: Mark buffer position immediately — this is the time-sensitive part.
        // The circular buffer is thread-safe, so reading indices off-main is safe.
        let preRollSamples = Int64(preRollSeconds * whisperSampleRate)
        let currentIndex = circularBuffer.totalSamplesWritten
        let earliest = circularBuffer.earliestAvailableIndex
        let startIdx = max(currentIndex - preRollSamples, earliest)
        let startedAt = Date().timeIntervalSince1970

        // Write IPC status immediately so the keyboard sees confirmation fast
        TranscriptionIPC.writeStatus(RecordingStatus(
            requestId: command.requestId,
            phase: .recording,
            recordingStartedAt: startedAt
        ))

        // Clear stale audio level and reset throttle
        TranscriptionIPC.clearAudioLevel()
        lastLevelWriteTime = 0

        log.log("[PersistentRecorder] ✅ Buffer position marked at index \(startIdx) (pre-roll: \(preRollSamples) samples)")

        // Update observable state on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.segmentStartIndex = startIdx
            self.segmentRequestId = command.requestId
            self.segmentModelId = command.modelId
            self.segmentLanguage = command.language
            self.segmentStartedAt = startedAt
            self.isSegmentActive = true
            self.segmentDuration = 0
            self.startDurationTimer()
            log.log("[PersistentRecorder] ✅ Segment UI state updated on main thread")
        }
    }

    /// Mark the start of a transcription segment (main-thread path, kept for direct calls).
    private func handleStartSegment(_ command: RecordingCommand) {
        guard isListening else {
            log.log("[PersistentRecorder] ❌ startSegment but not listening")
            return
        }

        guard !isSegmentActive else {
            log.log("[PersistentRecorder] ⚠️ startSegment but segment already active")
            return
        }

        // Paywall check — block if free tier exhausted
        if usageTracker.isAtLimit {
            log.log("[PersistentRecorder] 🔒 Free limit reached — blocking segment")
            writeErrorResponse(requestId: command.requestId, message: "Free limit reached — open Voxboard to unlock")
            needsUnlock = true
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
        osLog.notice("⏹ handleStopSegment called — isSegmentActive=\(self.isSegmentActive) segmentRequestId=\(self.segmentRequestId ?? "nil") command.requestId=\(command.requestId)")
        guard isSegmentActive else {
            log.log("[PersistentRecorder] ⚠️ stopSegment but no active segment")
            osLog.error("❌ stopSegment but isSegmentActive=false! Writing error response.")
            // Write an error response so the keyboard doesn't get stuck in "Transcribing…" forever
            let requestId = segmentRequestId ?? command.requestId
            writeErrorResponse(requestId: requestId, message: "Recording session expired — please try again")
            return
        }

        let requestId = segmentRequestId ?? command.requestId
        log.log("[PersistentRecorder] ⏹ Stopping segment: \(requestId.prefix(8)) (segmentRequestId=\(segmentRequestId?.prefix(8) ?? "nil"), command.requestId=\(command.requestId.prefix(8)))")
        osLog.notice("⏹ Stopping segment: \(requestId)")

        stopDurationTimer()
        isSegmentActive = false
        TranscriptionIPC.clearAudioLevel()

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
        TranscriptionIPC.clearAudioLevel()
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
              model.isDownloaded else {
            log.log("[PersistentRecorder] ❌ Model not found: \(modelId)")
            await MainActor.run { writeErrorResponse(requestId: requestId, message: "Model not found") }
            return
        }

        osLog.notice("🔄 Transcribing audio: \(audioURL.lastPathComponent) model=\(modelId)")
        log.log("[PersistentRecorder] Transcribing with \(model.name)…")

        let text: String?

        if model.engine.isParakeet {
            text = await transcribeWithParakeet(audioURL: audioURL, model: model)
        } else {
            text = await transcribeWithWhisper(audioURL: audioURL, model: model, language: language, modelId: modelId)
        }

        log.log("[PersistentRecorder] Result: \(text?.count ?? 0) chars")
        osLog.notice("✅ Transcription result: \(text?.count ?? 0) chars")

        await MainActor.run {
            if let text, !text.isEmpty {
                let response = TranscriptionResponse(requestId: requestId, text: text)
                do {
                    try TranscriptionIPC.writeResponse(response)
                    log.log("[PersistentRecorder] 📤 Response written (requestId=\(requestId.prefix(8)), chars=\(text.count))")
                } catch {
                    log.log("[PersistentRecorder] ❌ writeResponse FAILED: \(error) — keyboard will not receive transcription!")
                }
                TranscriptionIPC.postResponseNotification()
                osLog.notice("📤 Response written and notification posted for \(requestId)")

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

                // Track usage for the free-tier paywall
                self.usageTracker.addUsage(seconds: duration)

                // Surface result for in-app recording UI
                self.lastTranscriptionResult = text

                log.log("[PersistentRecorder] ✅ Transcription complete: \(text.count) chars")
            } else {
                self.lastTranscriptionResult = nil
                writeErrorResponse(requestId: requestId, message: "No speech detected")
            }
        }

        // Clean up WAV file
        try? FileManager.default.removeItem(at: audioURL)
    }

    // MARK: - Engine-specific transcription helpers

    private func transcribeWithWhisper(
        audioURL: URL,
        model: WhisperModelInfo,
        language: String,
        modelId: String
    ) async -> String? {
        guard let modelPath = model.localURL?.path else { return nil }

        // Use cached context if model matches, otherwise load fresh
        let cachedCtx = await MainActor.run { () -> WhisperContext? in
            if self.cachedModelId == modelId, let c = self.cachedWhisperContext {
                log.log("[PersistentRecorder] ♻️ Reusing cached Whisper: \(model.name)")
                return c
            }
            return nil
        }

        let ctx: WhisperContext
        if let c = cachedCtx {
            ctx = c
        } else {
            log.log("[PersistentRecorder] Loading Whisper model: \(model.name) (CPU-only)…")
            guard let freshCtx = WhisperContext(modelPath: modelPath, useGPU: false) else {
                log.log("[PersistentRecorder] ❌ Whisper model load failed")
                return nil
            }
            ctx = freshCtx
            await MainActor.run {
                self.cachedWhisperContext = freshCtx
                self.cachedParakeetContext = nil
                self.cachedModelId = modelId
            }
        }

        return ctx.transcribe(audioURL: audioURL, language: language)
    }

    private func transcribeWithParakeet(
        audioURL: URL,
        model: WhisperModelInfo
    ) async -> String? {
        guard let modelsDir = AppConstants.modelsDirectoryURL else { return nil }
        let modelId = model.id

        // Use cached context if model matches, otherwise load fresh
        let cachedCtx = await MainActor.run { () -> ParakeetContext? in
            if self.cachedModelId == modelId, let c = self.cachedParakeetContext {
                log.log("[PersistentRecorder] ♻️ Reusing cached Parakeet: \(model.name)")
                return c
            }
            return nil
        }

        let ctx: ParakeetContext
        if let c = cachedCtx {
            ctx = c
        } else {
            log.log("[PersistentRecorder] Loading Parakeet model: \(model.name)…")
            guard let freshCtx = await ParakeetContext.load(
                modelsDirectory: modelsDir,
                engine: model.engine
            ) else {
                log.log("[PersistentRecorder] ❌ Parakeet model load failed")
                return nil
            }
            ctx = freshCtx
            await MainActor.run {
                self.cachedParakeetContext = freshCtx
                self.cachedWhisperContext = nil
                self.cachedModelId = modelId
            }
        }

        return await ctx.transcribe(audioURL: audioURL)
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

    /// High-priority queue for processing IPC commands with minimal latency.
    /// Avoids waiting for the main thread run loop when the app is backgrounded.
    private static let commandQueue = DispatchQueue(label: "com.voxboard.commandProcessing", qos: .userInteractive)

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
                // Use high-priority queue to avoid main thread latency when backgrounded
                PersistentRecorder.commandQueue.async { recorder.handleCommandFromBackground() }
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
                PersistentRecorder.commandQueue.async { recorder.handleCommandFromBackground() }
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

    /// Process command on the high-priority background queue.
    /// Reads the IPC command and marks the buffer position immediately,
    /// then dispatches UI state updates to main thread.
    private func handleCommandFromBackground() {
        guard let command = TranscriptionIPC.readCommand() else {
            osLog.warning("⚠️ Command notification received but no command file found")
            return
        }

        log.log("[PersistentRecorder] Received command: \(command.action.rawValue) (requestId=\(command.requestId))")
        osLog.notice("📩 Received command: \(command.action.rawValue) requestId=\(command.requestId)")
        TranscriptionIPC.clearCommand()

        switch command.action {
        case .startSegment:
            // Dispatch to main so we can safely check & cancel any stale active segment
            // before marking the new buffer position. The 2-second pre-roll makes the
            // extra ~few-ms dispatch latency negligible.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Force-cancel any lingering segment from a previous session.
                // This is the root cause of requestId mismatches: if the keyboard
                // extension was killed mid-session, isSegmentActive stays true and
                // new recordings silently reuse the old segmentRequestId.
                if self.isSegmentActive {
                    let age = Date().timeIntervalSince1970 - self.segmentStartedAt
                    log.log("[PersistentRecorder] ⚠️ Force-cancelling stale segment (age=\(Int(age))s) before new start")
                    self.cancelSegment()
                }
                self.handleStartSegment(command)
            }

        case .stopSegment, .stop:
            // Stop and extract need main thread for UI + transcription kickoff
            DispatchQueue.main.async { [weak self] in
                self?.handleStopSegment(command)
            }
        }
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

    // MARK: - Audio Level Computation

    /// Compute RMS level from raw float samples and write to IPC (throttled).
    /// Called from the audio tap callback — must be fast.
    private func writeAudioLevelIfNeeded(_ samples: UnsafePointer<Float>, frameCount: Int) {
        // Only write levels when a segment is actively recording
        guard isSegmentActive else { return }

        let now = CACurrentMediaTime()
        guard now - lastLevelWriteTime >= levelWriteInterval else { return }
        lastLevelWriteTime = now

        // Compute RMS
        var sumSquares: Float = 0
        let buf = UnsafeBufferPointer(start: samples, count: frameCount)
        for sample in buf {
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameCount))

        // Normalize: typical speech RMS is 0.01–0.15, scale to 0–1 range
        // Use a gentle curve so quiet speech still shows movement
        let normalized = min(1.0, rms * 6.0)

        TranscriptionIPC.writeAudioLevel(normalized)
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
