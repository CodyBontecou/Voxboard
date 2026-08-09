import AVFoundation
import Foundation
import Observation
import VoxboardShared

@MainActor
@Observable
final class QuickCaptureVoiceSession: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    enum Phase: Equatable {
        case idle
        case recording
        case saving
        case transcribing
        case review
        case error(String)
    }

    private enum TranscriptionTaskResult: Sendable {
        case success(String)
        case failure(String)
    }

    var phase: Phase = .idle
    var elapsed: TimeInterval = 0
    var level: Float = 0
    var generateTranscript: Bool
    var transcript: String?
    var transcriptionMessage: String?
    var transcriptionProgress: TranscriptionProgress?
    var isPlaying = false

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var temporaryAudioURL: URL?
    private var lifecycle = CaptureVoiceLifecycle()
    private var activeGeneration: UInt64?
    private var progressGeneration: UInt64?
    @ObservationIgnored private var activeTranscriptionTask: Task<TranscriptionTaskResult, Never>?
    private(set) var stagedAsset: CaptureAssetReference?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    private let microphoneIsBusy: () -> Bool
    private let transcriptionService: OnDeviceTranscriptionService
    private let stageRecording: (URL, String?) async -> CaptureAssetReference?
    private let updateRecording: (CaptureAssetReference, String?) async -> Bool
    private let removeRecording: (CaptureAssetReference) async -> Bool

    init(
        microphoneIsBusy: @escaping () -> Bool,
        transcriptionService: OnDeviceTranscriptionService? = nil,
        stageRecording: @escaping (URL, String?) async -> CaptureAssetReference? = { _, _ in nil },
        updateRecording: @escaping (CaptureAssetReference, String?) async -> Bool = { _, _ in false },
        removeRecording: @escaping (CaptureAssetReference) async -> Bool = { _ in true }
    ) {
        self.microphoneIsBusy = microphoneIsBusy
        self.transcriptionService = transcriptionService ?? AppTranscriptionServices.shared
        self.stageRecording = stageRecording
        self.updateRecording = updateRecording
        self.removeRecording = removeRecording
        let selectedID = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
            ?? AppConstants.defaultTranscriptionBackendID
        if selectedID == TranscriptionBackendID.automatic {
            // Automatic resolves availability asynchronously when recording opens.
            // Start from the user's default intent to include a transcript, then
            // disable it below only if no on-device backend is actually available.
            self.generateTranscript = true
        } else {
            self.generateTranscript = WhisperModelInfo.availableModels
                .first(where: { $0.id == selectedID })?.isDownloaded == true
        }
        super.init()
    }

    var audioURL: URL? { temporaryAudioURL }
    var duration: TimeInterval {
        if let player { return player.duration }
        return elapsed
    }
    var hasTranscriptionBackend: Bool {
        let selectedID = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
            ?? AppConstants.defaultTranscriptionBackendID
        if selectedID == TranscriptionBackendID.automatic {
            return AppConstants.sharedDefaults?.bool(forKey: AppConstants.automaticBackendReadyKey) == true
                || WhisperModelInfo.availableModels.contains(where: { $0.isDownloaded })
        }
        return WhisperModelInfo.availableModels.first(where: { $0.id == selectedID })?.isDownloaded == true
    }

    func start() async {
        await cancelActiveTranscription()
        cleanupPlayback()
        purgeStaleTemporaryAudio()

        let selectedID = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
            ?? AppConstants.defaultTranscriptionBackendID
        let selectedLanguage = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey) ?? "auto"
        let backendReady = await transcriptionService.canTranscribe(
            modelID: selectedID,
            fallbackModelID: AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedFallbackModelKey),
            language: selectedLanguage
        )
        if selectedID == TranscriptionBackendID.automatic {
            AppConstants.sharedDefaults?.set(backendReady, forKey: AppConstants.automaticBackendReadyKey)
        }
        // Each voice note defaults to including a transcript whenever the selected
        // on-device backend is ready. The recording-screen toggle remains a
        // per-note override after recording starts.
        generateTranscript = backendReady
        transcript = nil
        transcriptionMessage = nil
        transcriptionProgress = nil
        progressGeneration = nil
        stagedAsset = nil
        let generation = lifecycle.beginAttempt()
        activeGeneration = generation

        guard !microphoneIsBusy() else {
            _ = lifecycle.fail(generation: generation, with: .microphoneBusy)
            phase = .error(String(localized: "Stop keyboard listening or finish the current recording before adding a voice attachment."))
            return
        }

        let permission = await requestMicrophonePermission()
        guard lifecycle.generation == generation else { return }
        guard permission else {
            _ = lifecycle.fail(generation: generation, with: .permissionDenied)
            phase = .error(String(localized: "Microphone access is required to attach a voice recording."))
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoxCaptureVoice", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory
                .appendingPathComponent("recording-\(UUID().uuidString.lowercased())")
                .appendingPathExtension("m4a")
            temporaryAudioURL = url
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                throw VoiceSessionError.couldNotStart
            }
            guard lifecycle.recordingStarted(generation: generation) else {
                recorder.stop()
                removeTemporaryAudio()
                deactivateAudioSession()
                return
            }
            self.recorder = recorder
            beginInterruptionObservation(generation: generation, recorder: recorder)
            elapsed = 0
            level = 0
            phase = .recording
            startMeterTimer()
        } catch {
            removeTemporaryAudio()
            deactivateAudioSession()
            if lifecycle.fail(generation: generation, with: .couldNotStart) {
                phase = .error(error.localizedDescription)
            }
        }
    }

    func finishRecording() async {
        guard phase == .recording,
              let recorder,
              let generation = activeGeneration else { return }
        let recordedDuration = max(elapsed, recorder.currentTime)
        stopInterruptionObservation()
        recorder.stop()
        timer?.invalidate()
        timer = nil
        self.recorder = nil
        elapsed = recordedDuration
        deactivateAudioSession()

        let action = lifecycle.finishRecording(
            generation: generation,
            duration: recordedDuration,
            fileExists: temporaryAudioURL.map { FileManager.default.fileExists(atPath: $0.path) } == true,
            fileByteCount: audioFileByteCount,
            wantsTranscript: generateTranscript,
            modelAvailable: hasTranscriptionBackend
        )
        switch action {
        case .ignore:
            return
        case .rejectAudio:
            deactivateAudioSession()
            phase = .error(String(localized: "No usable audio was captured. Try recording again."))
            return
        case .reviewAudio:
            guard await persistCurrentRecording(generation: generation) else { return }
            if generateTranscript, !hasTranscriptionBackend {
                transcriptionMessage = String(localized: "Download the selected local model to generate a transcript. The audio is ready to add.")
            }
        case .transcribeAudio:
            guard await persistCurrentRecording(generation: generation),
                  let url = temporaryAudioURL else { return }
            phase = .transcribing
            let modelID = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
                ?? AppConstants.defaultTranscriptionBackendID
            let language = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey)
                ?? "auto"
            progressGeneration = generation
            let transcriptionTask = Task<TranscriptionTaskResult, Never> { [transcriptionService] in
                do {
                    return .success(try await transcriptionService.transcribe(
                        audioURL: url,
                        modelID: modelID,
                        language: language,
                        onProgress: { [weak self] progress in
                            Task { @MainActor [weak self] in
                                guard let self,
                                      self.progressGeneration == generation else { return }
                                if let current = self.transcriptionProgress?.exactFractionCompleted {
                                    guard let incoming = progress.exactFractionCompleted,
                                          incoming >= current else { return }
                                }
                                self.transcriptionProgress = progress
                            }
                        }
                    ))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }
            activeTranscriptionTask = transcriptionTask
            let result = await transcriptionTask.value
            if progressGeneration == generation {
                activeTranscriptionTask = nil
                progressGeneration = nil
                transcriptionProgress = nil
            }
            guard lifecycle.transcriptionFinished(generation: generation) else { return }
            switch result {
            case .success(let text):
                transcript = text
                if let stagedAsset {
                    let updated = await updateRecording(stagedAsset, text)
                    if !updated {
                        transcriptionMessage = String(localized: "The transcript could not be attached, but the audio recording is safely staged.")
                    }
                }
            case .failure(let message):
                // Audio remains a first-class result even when local inference fails.
                transcriptionMessage = message
            }
        }

        guard lifecycle.generation == generation else { return }
        preparePlayer()
        phase = .review
    }

    func retry() async {
        lifecycle.cancel()
        await cancelActiveTranscription()
        guard await discardStagedRecording() else {
            phase = .error(String(localized: "The previous recording is still safely attached. Remove it from the draft before retrying."))
            return
        }
        cleanup(removeAudio: true)
        activeGeneration = nil
        elapsed = 0
        level = 0
        transcript = nil
        transcriptionMessage = nil
        transcriptionProgress = nil
        progressGeneration = nil
        phase = .idle
        await start()
    }

    func togglePlayback() {
        guard phase == .review else { return }
        if player?.isPlaying == true {
            player?.pause()
            isPlaying = false
            deactivateAudioSession()
        } else {
            if player == nil { preparePlayer() }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                player?.play()
                isPlaying = player?.isPlaying == true
            } catch {
                transcriptionMessage = String(localized: "Playback is unavailable, but the audio remains safely attached.")
            }
        }
    }

    @discardableResult
    func commitStagedRecordingAndCleanup() async -> Bool {
        guard stagedAsset != nil else { return false }
        await cancelActiveTranscription()
        guard stagedAsset != nil else { return false }
        // The durable draft now owns the staged asset. Only the disposable
        // recorder working file should be removed when the recording is added.
        stagedAsset = nil
        cleanup(removeAudio: true)
        lifecycle.inserted()
        activeGeneration = nil
        progressGeneration = nil
        transcriptionProgress = nil
        phase = .idle
        return true
    }

    func cancel() async {
        lifecycle.cancel()
        await cancelActiveTranscription()
        let removed = await discardStagedRecording()
        cleanup(removeAudio: true)
        activeGeneration = nil
        progressGeneration = nil
        transcriptionProgress = nil
        phase = removed
            ? .idle
            : .error(String(localized: "The recording remains safely attached to the draft because it could not be removed."))
    }

    func handleAppBackgrounding() async {
        guard let recorder, let generation = activeGeneration else { return }
        await finalizeInterruptedRecording(
            message: String(localized: "Recording stopped when Vox.md left the foreground. The audio is ready to add."),
            expectedGeneration: generation,
            expectedRecorder: recorder
        )
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.recorder === recorder,
                  let generation = self.activeGeneration else { return }
            self.stopInterruptionObservation()
            self.timer?.invalidate()
            self.timer = nil
            self.recorder = nil
            self.deactivateAudioSession()
            if self.lifecycle.fail(generation: generation, with: .encoding) {
                self.phase = .error(error?.localizedDescription ?? String(localized: "The recording could not be encoded."))
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.isPlaying = false
            self?.deactivateAudioSession()
        }
    }

    private func beginInterruptionObservation(
        generation: UInt64,
        recorder: AVAudioRecorder
    ) {
        stopInterruptionObservation()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak recorder] notification in
            guard let recorder,
                  let rawValue = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
                  AVAudioSession.InterruptionType(rawValue: rawValue) == .began else { return }
            Task { @MainActor [weak self] in
                await self?.finalizeInterruptedRecording(
                    message: String(localized: "Recording stopped because another audio session needed the microphone. The audio is ready to add."),
                    expectedGeneration: generation,
                    expectedRecorder: recorder
                )
            }
        }
    }

    private func stopInterruptionObservation() {
        guard let interruptionObserver else { return }
        NotificationCenter.default.removeObserver(interruptionObserver)
        self.interruptionObserver = nil
    }

    private func finalizeInterruptedRecording(
        message: String,
        expectedGeneration: UInt64,
        expectedRecorder: AVAudioRecorder
    ) async {
        guard phase == .recording,
              activeGeneration == expectedGeneration,
              let recorder,
              recorder === expectedRecorder else { return }
        let recordedDuration = max(elapsed, recorder.currentTime)
        stopInterruptionObservation()
        recorder.stop()
        timer?.invalidate()
        timer = nil
        self.recorder = nil
        elapsed = recordedDuration
        deactivateAudioSession()

        switch lifecycle.backgrounded(
            generation: expectedGeneration,
            duration: recordedDuration,
            fileExists: temporaryAudioURL.map { FileManager.default.fileExists(atPath: $0.path) } == true,
            fileByteCount: audioFileByteCount
        ) {
        case .reviewAudio:
            guard await persistCurrentRecording(generation: expectedGeneration) else { return }
            transcriptionMessage = message
            preparePlayer()
            phase = .review
        case .rejectAudio:
            deactivateAudioSession()
            phase = .error(String(localized: "No usable audio was captured. Try recording again."))
        case .ignore, .transcribeAudio:
            break
        }
    }

    private func persistCurrentRecording(generation: UInt64) async -> Bool {
        guard lifecycle.generation == generation,
              let temporaryAudioURL else { return false }
        if stagedAsset != nil { return true }

        phase = .saving
        guard let asset = await stageRecording(temporaryAudioURL, nil) else {
            guard lifecycle.generation == generation else { return false }
            phase = .error(String(localized: "The recording could not be saved to the durable draft. The temporary audio is still available while this screen remains open."))
            return false
        }
        guard lifecycle.generation == generation else {
            _ = await removeRecording(asset)
            return false
        }
        stagedAsset = asset
        return true
    }

    private func cancelActiveTranscription() async {
        let task = activeTranscriptionTask
        activeTranscriptionTask = nil
        progressGeneration = nil
        transcriptionProgress = nil
        task?.cancel()
        _ = await task?.value
    }

    private func discardStagedRecording() async -> Bool {
        guard let stagedAsset else { return true }
        guard await removeRecording(stagedAsset) else { return false }
        if self.stagedAsset == stagedAsset {
            self.stagedAsset = nil
        }
        return true
    }

    private var audioFileByteCount: Int64 {
        guard let temporaryAudioURL,
              let size = try? temporaryAudioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return 0
        }
        return Int64(size)
    }

    private func purgeStaleTemporaryAudio() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxCaptureVoice", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  values.contentModificationDate.map({ $0 < cutoff }) == true else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    private func startMeterTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                let decibels = recorder.averagePower(forChannel: 0)
                self.level = max(0, min(1, pow(10, decibels / 30)))
            }
        }
    }

    private func preparePlayer() {
        guard let url = temporaryAudioURL else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
        } catch {
            transcriptionMessage = String(localized: "Playback is unavailable, but the audio can still be added.")
        }
    }

    private func cleanupPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    private func cleanup(removeAudio: Bool) {
        stopInterruptionObservation()
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        cleanupPlayback()
        if removeAudio { removeTemporaryAudio() }
        deactivateAudioSession()
    }

    private func removeTemporaryAudio() {
        if let temporaryAudioURL { try? FileManager.default.removeItem(at: temporaryAudioURL) }
        temporaryAudioURL = nil
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private enum VoiceSessionError: Error, LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        String(localized: "The microphone could not start recording.")
    }
}
