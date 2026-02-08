import AVFoundation
import Foundation

/// Records audio as 16 kHz mono 16-bit PCM WAV — the format whisper.cpp expects.
/// Works in both the main app and keyboard extension (requires Full Access for extension).
@Observable
public final class AudioRecorder: NSObject {
    public var isRecording = false
    public var recordingDuration: TimeInterval = 0

    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    private var startTime: Date?

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
        guard let url = recordingURL else { return false }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("[AudioRecorder] Session setup failed: \(error)")
            return false
        }

        // whisper.cpp requires 16 kHz, mono, 16-bit PCM
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.record()
            isRecording = true
            startTime = Date()

            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let start = self.startTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
            return true
        } catch {
            print("[AudioRecorder] Recording failed: \(error)")
            return false
        }
    }

    @discardableResult
    public func stopRecording() -> URL? {
        audioRecorder?.stop()
        audioRecorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false

        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        return recordingURL
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
