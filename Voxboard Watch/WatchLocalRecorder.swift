import AVFoundation
import Foundation
import WidgetKit

@MainActor
final class WatchLocalRecorder: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case transferring
        case transferred
        case error(String)
    }

    struct QueuedRecording: Codable, Equatable, Identifiable {
        let id: String
        let filename: String
        let createdAt: Date
        let duration: TimeInterval

        var fileURL: URL {
            WatchLocalRecorder.recordingsDirectoryURL.appendingPathComponent(filename)
        }
    }

    @Published private(set) var phase: Phase = .idle { didSet { publishWidgetSnapshot() } }
    @Published private(set) var startedAt: Date? { didSet { publishWidgetSnapshot() } }
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var message: String? { didSet { publishWidgetSnapshot() } }
    @Published private(set) var queuedRecordings: [QueuedRecording] { didSet { publishWidgetSnapshot() } }

    private var recorder: AVAudioRecorder?
    private var currentRecordingID: String?
    private var timer: Timer?
    private var transferObserver: NSObjectProtocol?
    private var inFlightTransferIDs = Set<String>()
    private var transientSuccessResetTask: Task<Void, Never>?

    #if DEBUG
    private var demoTask: Task<Void, Never>?
    #endif

    init() {
        queuedRecordings = Self.loadQueuedRecordings()
        transferObserver = NotificationCenter.default.addObserver(
            forName: .watchRecordingTransferDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleTransferFinished(notification)
            }
        }
        publishWidgetSnapshot()
    }

    deinit {
        transientSuccessResetTask?.cancel()
        if let transferObserver {
            NotificationCenter.default.removeObserver(transferObserver)
        }
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isTransferring: Bool {
        if case .transferring = phase { return true }
        return false
    }

    var queuedCount: Int {
        queuedRecordings.count
    }

    var title: String {
        switch phase {
        case .idle:
            return queuedCount > 0 ? "Saved" : "Vox.md"
        case .recording:
            return "Recording"
        case .transferring:
            return "Syncing"
        case .transferred:
            return "Saved"
        case .error:
            return queuedCount > 0 ? "Saved" : "Needs attention"
        }
    }

    var subtitle: String {
        if let message, !message.isEmpty { return message }
        switch phase {
        case .idle:
            if queuedCount > 0 {
                return queueSummary + " Tap Sync Queue when your iPhone is nearby."
            }
            return "Record on this Watch. Syncs to iPhone later."
        case .recording:
            return "Tap the status card to stop when your thought is captured."
        case .transferring:
            return "Sending Watch recordings to the iPhone queue."
        case .transferred:
            return "Open Vox.md on iPhone to process. You can record another."
        case .error(let error):
            return error
        }
    }

    var actionTitle: String {
        isRecording ? "Stop" : "Record"
    }

    var actionSymbol: String {
        isRecording ? "stop.fill" : "mic.fill"
    }

    var syncTitle: String {
        queuedCount > 0 ? "Sync Queue (\(queuedCount))" : "Sync Status"
    }

    var queueSummary: String {
        queuedCount == 1 ? "1 recording saved on Watch." : "\(queuedCount) recordings saved on Watch."
    }

    private var widgetPhase: WatchRecordingPhase {
        switch phase {
        case .idle:
            return .idle
        case .recording:
            return .recording
        case .transferring:
            return .syncing
        case .transferred:
            return .pending
        case .error:
            return .error
        }
    }

    private func publishWidgetSnapshot() {
        let snapshot = WatchRecordingSnapshot(
            phase: widgetPhase,
            isQuickRecordEnabled: true,
            recordingStartedAt: startedAt?.timeIntervalSince1970,
            message: message,
            queuedCount: queuedCount
        )
        WatchLocalSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: "VoxboardWatchRecordWidget")
    }

    func toggle(using bridge: WatchPhoneBridge) async {
        if isRecording {
            await stopAndQueue(using: bridge)
        } else {
            await start()
        }
    }

    func handleDeepLink(_ url: URL, using bridge: WatchPhoneBridge) async {
        guard url.scheme == WatchRecordingDeepLink.scheme else { return }

        let action = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch action {
        case WatchRecordingDeepLink.startHost:
            await start()
        case WatchRecordingDeepLink.stopHost:
            await stopAndQueue(using: bridge)
        case WatchRecordingDeepLink.toggleHost:
            await toggle(using: bridge)
        default:
            await start()
        }
    }

    func start() async {
        guard !isRecording else { return }
        cancelTransientSuccessReset()

        let hasPermission = await requestMicrophonePermission()
        guard hasPermission else {
            setError("Microphone permission required on Apple Watch.")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let id = UUID().uuidString
            let url = try makeRecordingURL(id: id)
            let recorder = try AVAudioRecorder(url: url, settings: recordingSettings)
            recorder.isMeteringEnabled = false
            guard recorder.record() else {
                setError("Could not start Watch recording.")
                try? session.setActive(false)
                return
            }

            self.recorder = recorder
            currentRecordingID = id
            startedAt = Date()
            duration = 0
            message = nil
            phase = .recording
            startTimer()
        } catch {
            setError("Watch microphone error: \(error.localizedDescription)")
        }
    }

    func stopAndQueue(using bridge: WatchPhoneBridge) async {
        guard let recorder else { return }
        cancelTransientSuccessReset()

        let url = recorder.url
        let id = currentRecordingID ?? url.deletingPathExtension().lastPathComponent
        let createdAt = startedAt ?? Date()
        let recordedDuration = max(duration, recorder.currentTime)

        recorder.stop()
        self.recorder = nil
        currentRecordingID = nil
        startedAt = nil
        stopTimer()
        try? AVAudioSession.sharedInstance().setActive(false)

        guard FileManager.default.fileExists(atPath: url.path) else {
            setError("Watch recording file was not saved.")
            return
        }

        let item = QueuedRecording(
            id: id,
            filename: url.lastPathComponent,
            createdAt: createdAt,
            duration: recordedDuration
        )
        upsertQueuedRecording(item)
        phase = .idle
        message = "Saved on Watch. Syncing to iPhone…"
        syncPending(using: bridge)
    }

    func syncPending(using bridge: WatchPhoneBridge) {
        cancelTransientSuccessReset()
        pruneMissingQueuedRecordings()

        guard !queuedRecordings.isEmpty else {
            if !isRecording {
                phase = .idle
                message = "No Watch recordings waiting to sync."
            }
            return
        }

        let candidates = queuedRecordings.filter { item in
            FileManager.default.fileExists(atPath: item.fileURL.path) && !inFlightTransferIDs.contains(item.id)
        }

        guard !candidates.isEmpty else {
            phase = .transferring
            message = "Syncing \(queuedCount) Watch recording\(queuedCount == 1 ? "" : "s") to iPhone…"
            return
        }

        var queuedForTransfer = 0
        for item in candidates {
            let didQueue = bridge.transferWatchRecording(
                fileURL: item.fileURL,
                id: item.id,
                createdAt: item.createdAt,
                duration: item.duration
            )

            if didQueue {
                inFlightTransferIDs.insert(item.id)
                queuedForTransfer += 1
            }
        }

        if queuedForTransfer > 0 {
            phase = .transferring
            message = "Syncing \(queuedCount) Watch recording\(queuedCount == 1 ? "" : "s") to iPhone…"
        } else {
            phase = .error("Saved on Watch, but iPhone sync is unavailable.")
            message = "Saved on Watch. Tap Sync Queue after your iPhone is nearby."
        }
    }

    private func handleTransferFinished(_ notification: Notification) {
        guard let id = notification.userInfo?[WatchRecordingTransferNotificationKey.recordingID] as? String else {
            return
        }

        inFlightTransferIDs.remove(id)
        let didSucceed = notification.userInfo?[WatchRecordingTransferNotificationKey.success] as? Bool ?? false

        if didSucceed {
            removeQueuedRecording(id: id, deleteFile: true)
            guard !isRecording else { return }
            if queuedRecordings.isEmpty {
                phase = .transferred
                message = "Synced to iPhone queue. You can record another."
                scheduleTransientSuccessReset()
            } else {
                phase = .idle
                message = queueSummary + " Tap Sync Queue to continue."
            }
        } else {
            guard !isRecording else { return }
            cancelTransientSuccessReset()
            let errorMessage = notification.userInfo?[WatchRecordingTransferNotificationKey.errorMessage] as? String
            phase = .error("Saved on Watch, sync failed.")
            message = errorMessage.map { "Saved on Watch. Sync failed: \($0)" }
                ?? "Saved on Watch. Tap Sync Queue after your iPhone is nearby."
        }
    }

    private func scheduleTransientSuccessReset(after delay: TimeInterval = 3.5) {
        cancelTransientSuccessReset()
        transientSuccessResetTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            guard case .transferred = self.phase else { return }

            self.message = nil
            self.phase = .idle
            self.transientSuccessResetTask = nil
        }
    }

    private func cancelTransientSuccessReset() {
        transientSuccessResetTask?.cancel()
        transientSuccessResetTask = nil
    }

    #if DEBUG
    var isRunningDemoScript: Bool {
        Self.debugDemoMode != nil
    }

    @discardableResult
    func runDemoScriptIfNeeded(using bridge: WatchPhoneBridge) -> Bool {
        guard let mode = Self.debugDemoMode else { return false }

        demoTask?.cancel()
        demoTask = Task { @MainActor in
            switch mode {
            case "record-flow":
                await runDemoRecordFlow()
            case "queue-flow":
                await runDemoQueueFlow()
            default:
                await runDemoRecordFlow()
            }
        }
        return true
    }

    private static var debugDemoMode: String? {
        let arguments = ProcessInfo.processInfo.arguments
        if let inline = arguments.first(where: { $0.hasPrefix("--voxboard-demo=") }) {
            return String(inline.dropFirst("--voxboard-demo=".count))
        }
        if let index = arguments.firstIndex(of: "--voxboard-demo"), arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        if let inline = arguments.first(where: { $0.hasPrefix("--watch-demo=") }) {
            return String(inline.dropFirst("--watch-demo=".count))
        }
        if let index = arguments.firstIndex(of: "--watch-demo"), arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        return nil
    }

    private func runDemoRecordFlow() async {
        resetDemoState(
            phase: .idle,
            queuedCount: 0,
            message: "Record on this Watch. Syncs to iPhone later."
        )
        await sleepForDemo(seconds: 1.15)

        guard !Task.isCancelled else { return }
        startedAt = Date()
        duration = 0
        message = nil
        phase = .recording
        startTimer()
        await sleepForDemo(seconds: 3.8)

        guard !Task.isCancelled else { return }
        startedAt = nil
        duration = 0
        stopTimer()
        setDemoQueue(count: 1)
        phase = .idle
        message = "Saved on Watch. Syncing to iPhone…"
        await sleepForDemo(seconds: 1.8)

        guard !Task.isCancelled else { return }
        phase = .transferring
        message = "Sending Watch recording to the iPhone queue."
        await sleepForDemo(seconds: 1.8)

        guard !Task.isCancelled else { return }
        setDemoQueue(count: 0)
        phase = .transferred
        message = "Synced to iPhone queue. You can record another."
        scheduleTransientSuccessReset()
    }

    private func runDemoQueueFlow() async {
        resetDemoState(
            phase: .idle,
            queuedCount: 2,
            message: nil
        )
        await sleepForDemo(seconds: 2.0)

        guard !Task.isCancelled else { return }
        phase = .transferring
        message = "Syncing 2 Watch recordings to iPhone…"
        await sleepForDemo(seconds: 3.0)

        guard !Task.isCancelled else { return }
        setDemoQueue(count: 0)
        phase = .transferred
        message = "Synced to iPhone queue. You can record another."
        scheduleTransientSuccessReset()
    }

    private func resetDemoState(phase: Phase, queuedCount: Int, message: String?) {
        recorder?.stop()
        recorder = nil
        currentRecordingID = nil
        startedAt = nil
        duration = 0
        stopTimer()
        setDemoQueue(count: queuedCount)
        self.message = message
        self.phase = phase
    }

    private func setDemoQueue(count: Int) {
        queuedRecordings = (0..<count).map { index in
            QueuedRecording(
                id: "demo-watch-recording-\(index + 1)",
                filename: "demo-watch-recording-\(index + 1).m4a",
                createdAt: Date().addingTimeInterval(Double(index - count) * 120),
                duration: 18 + Double(index * 7)
            )
        }
    }

    private func sleepForDemo(seconds: TimeInterval) async {
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
    #endif

    private var recordingSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }

    private func makeRecordingURL(id: String) throws -> URL {
        let directory = try recordingsDirectory()
        let filename = "watch-\(id).m4a"
        return directory.appendingPathComponent(filename)
    }

    nonisolated private static var recordingsDirectoryURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WatchRecordings", isDirectory: true)
    }

    nonisolated private static var queueIndexURL: URL {
        recordingsDirectoryURL.appendingPathComponent("index.json")
    }

    private func recordingsDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: Self.recordingsDirectoryURL, withIntermediateDirectories: true)
        return Self.recordingsDirectoryURL
    }

    private static func loadQueuedRecordings() -> [QueuedRecording] {
        guard let data = try? Data(contentsOf: queueIndexURL),
              let decoded = try? JSONDecoder().decode([QueuedRecording].self, from: data) else {
            return []
        }

        let existing = decoded.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        if existing.count != decoded.count {
            try? saveQueuedRecordings(existing)
        }
        return existing.sorted { $0.createdAt < $1.createdAt }
    }

    private static func saveQueuedRecordings(_ recordings: [QueuedRecording]) throws {
        try FileManager.default.createDirectory(at: recordingsDirectoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(recordings.sorted { $0.createdAt < $1.createdAt })
        try data.write(to: queueIndexURL, options: .atomic)
    }

    private func saveQueuedRecordings() {
        try? Self.saveQueuedRecordings(queuedRecordings)
    }

    private func upsertQueuedRecording(_ item: QueuedRecording) {
        queuedRecordings.removeAll { $0.id == item.id }
        queuedRecordings.append(item)
        queuedRecordings.sort { $0.createdAt < $1.createdAt }
        saveQueuedRecordings()
    }

    private func removeQueuedRecording(id: String, deleteFile: Bool) {
        guard let item = queuedRecordings.first(where: { $0.id == id }) else { return }
        if deleteFile {
            try? FileManager.default.removeItem(at: item.fileURL)
        }
        queuedRecordings.removeAll { $0.id == id }
        saveQueuedRecordings()
    }

    private func pruneMissingQueuedRecordings() {
        let existing = queuedRecordings.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        guard existing.count != queuedRecordings.count else { return }
        queuedRecordings = existing
        saveQueuedRecordings()
    }

    private func requestMicrophonePermission() async -> Bool {
        if #available(watchOS 10.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                return await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            @unknown default:
                return false
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                return await withCheckedContinuation { continuation in
                    session.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            @unknown default:
                return false
            }
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                self.duration = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func setError(_ error: String) {
        cancelTransientSuccessReset()
        phase = .error(error)
        message = error
        recorder = nil
        currentRecordingID = nil
        startedAt = nil
        stopTimer()
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
