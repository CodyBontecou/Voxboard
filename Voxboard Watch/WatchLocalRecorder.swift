import AVFoundation
import Foundation
import WidgetKit

@MainActor
final class WatchLocalRecorder: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case transferring
        case waitingForPhone
        case transcribing
        case delivering
        case transferred
        case error(String)
    }

    enum TransportState: String, Codable {
        case local
        case transferring
        case uploaded
    }

    struct QueuedRecording: Codable, Equatable, Identifiable {
        let id: String
        let filename: String
        let createdAt: Date
        var duration: TimeInterval
        var transportState: TransportState
        var remotePhase: WatchRemoteRecordingPhase?
        var remoteRevision: Int
        var remoteMessage: String?
        var presetID: String?
        var presetName: String?
        var presetSnapshot: Data?

        var fileURL: URL {
            WatchLocalRecorder.recordingsDirectoryURL.appendingPathComponent(filename)
        }

        init(
            id: String,
            filename: String,
            createdAt: Date,
            duration: TimeInterval,
            transportState: TransportState = .local,
            remotePhase: WatchRemoteRecordingPhase? = nil,
            remoteRevision: Int = 0,
            remoteMessage: String? = nil,
            presetID: String? = nil,
            presetName: String? = nil,
            presetSnapshot: Data? = nil
        ) {
            self.id = id
            self.filename = filename
            self.createdAt = createdAt
            self.duration = duration
            self.transportState = transportState
            self.remotePhase = remotePhase
            self.remoteRevision = remoteRevision
            self.remoteMessage = remoteMessage
            self.presetID = presetID
            self.presetName = presetName
            self.presetSnapshot = presetSnapshot
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case filename
            case createdAt
            case duration
            case transportState
            case remotePhase
            case remoteRevision
            case remoteMessage
            case presetID
            case presetName
            case presetSnapshot
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                id: try container.decode(String.self, forKey: .id),
                filename: try container.decode(String.self, forKey: .filename),
                createdAt: try container.decode(Date.self, forKey: .createdAt),
                duration: try container.decode(TimeInterval.self, forKey: .duration),
                transportState: try container.decodeIfPresent(TransportState.self, forKey: .transportState) ?? .local,
                remotePhase: try container.decodeIfPresent(WatchRemoteRecordingPhase.self, forKey: .remotePhase),
                remoteRevision: try container.decodeIfPresent(Int.self, forKey: .remoteRevision) ?? 0,
                remoteMessage: try container.decodeIfPresent(String.self, forKey: .remoteMessage),
                presetID: try container.decodeIfPresent(String.self, forKey: .presetID),
                presetName: try container.decodeIfPresent(String.self, forKey: .presetName),
                presetSnapshot: try container.decodeIfPresent(Data.self, forKey: .presetSnapshot)
            )
        }
    }

    @Published private(set) var phase: Phase = .idle { didSet { publishWidgetSnapshot() } }
    @Published private(set) var startedAt: Date? { didSet { publishWidgetSnapshot() } }
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var message: String? { didSet { publishWidgetSnapshot() } }
    @Published private(set) var queuedRecordings: [QueuedRecording] { didSet { publishWidgetSnapshot() } }

    private var recorder: AVAudioRecorder?
    private var currentRecordingID: String?
    private var currentPresetID: String?
    private var currentPresetName: String?
    private var currentPresetSnapshot: Data?
    private var timer: Timer?
    private var transferObserver: NSObjectProtocol?
    private var inFlightTransferIDs = Set<String>()
    private var transientSuccessResetTask: Task<Void, Never>?

    #if DEBUG
    private var demoTask: Task<Void, Never>?
    #endif

    init() {
        queuedRecordings = Self.loadQueuedRecordingsRecoveringInterruptedCapture()
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

    var hasUnuploadedRecordings: Bool {
        queuedRecordings.contains { $0.transportState != .uploaded }
    }

    var recordingPresetName: String? {
        guard isRecording else { return nil }
        return currentPresetName
    }

    var title: String {
        switch phase {
        case .idle:
            return queuedCount > 0 ? "Saved" : "Vox.md"
        case .recording:
            return "Recording"
        case .transferring:
            return "Syncing"
        case .waitingForPhone:
            return "On iPhone"
        case .transcribing:
            return "Transcribing"
        case .delivering:
            return "Saving"
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
        case .waitingForPhone:
            return "Safely queued on iPhone and waiting to process."
        case .transcribing:
            return "Your iPhone is transcribing this recording on device."
        case .delivering:
            return "Your iPhone is saving this recording."
        case .transferred:
            return "Saved on iPhone. You can record another."
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
        if hasUnuploadedRecordings { return "Sync Queue (\(queuedCount))" }
        return queuedCount > 0 ? "Refresh Status" : "Sync Status"
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
        case .waitingForPhone:
            return .pending
        case .transcribing:
            return .transcribing
        case .delivering:
            return .delivering
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
            await start(using: bridge)
        }
    }

    func handleDeepLink(_ url: URL, using bridge: WatchPhoneBridge) async {
        guard url.scheme == WatchRecordingDeepLink.scheme else { return }

        let action = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch action {
        case WatchRecordingDeepLink.startHost:
            await start(using: bridge)
        case WatchRecordingDeepLink.stopHost:
            await stopAndQueue(using: bridge)
        case WatchRecordingDeepLink.toggleHost:
            await toggle(using: bridge)
        default:
            await start(using: bridge)
        }
    }

    func start(using bridge: WatchPhoneBridge) async {
        guard !isRecording else { return }
        cancelTransientSuccessReset()

        if bridge.snapshot.hasPresetSelectionAvailabilityPayload {
            guard bridge.snapshot.presetSelectionIsAvailable,
                  bridge.snapshot.selectedPresetID != nil,
                  bridge.snapshot.selectedPresetName != nil,
                  bridge.snapshot.selectedPresetSnapshot != nil else {
                setError("Enable a Capture Preset in Vox.md on iPhone before recording.")
                return
            }
        }

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

            let recordingStartedAt = Date()
            let activeRecording = QueuedRecording(
                id: id,
                filename: url.lastPathComponent,
                createdAt: recordingStartedAt,
                duration: 0,
                presetID: bridge.snapshot.selectedPresetID,
                presetName: bridge.snapshot.selectedPresetName,
                presetSnapshot: bridge.snapshot.selectedPresetSnapshot
            )
            do {
                try Self.saveActiveRecording(activeRecording)
            } catch {
                recorder.stop()
                try? FileManager.default.removeItem(at: url)
                setError("Could not safely journal this Watch recording.")
                return
            }
            guard recorder.record() else {
                Self.clearActiveRecording()
                try? FileManager.default.removeItem(at: url)
                setError("Could not start Watch recording.")
                try? session.setActive(false)
                return
            }

            self.recorder = recorder
            currentRecordingID = id
            currentPresetID = bridge.snapshot.selectedPresetID
            currentPresetName = bridge.snapshot.selectedPresetName
            currentPresetSnapshot = bridge.snapshot.selectedPresetSnapshot
            startedAt = recordingStartedAt
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
        let presetID = currentPresetID
        let presetName = currentPresetName
        let presetSnapshot = currentPresetSnapshot
        currentPresetID = nil
        currentPresetName = nil
        currentPresetSnapshot = nil
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
            duration: recordedDuration,
            presetID: presetID,
            presetName: presetName,
            presetSnapshot: presetSnapshot
        )
        do {
            try upsertQueuedRecording(item)
            Self.clearActiveRecording()
        } catch {
            phase = .error("The recording is safe, but its queue could not be updated.")
            message = "Recording retained on Watch. Reopen Vox.md to recover it."
            return
        }
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
            FileManager.default.fileExists(atPath: item.fileURL.path)
                && item.transportState != .uploaded
                && !inFlightTransferIDs.contains(item.id)
        }

        guard !candidates.isEmpty else {
            if queuedRecordings.allSatisfy({ $0.transportState == .uploaded }) {
                phase = phaseForMostAdvancedRemoteStatus()
                message = messageForMostAdvancedRemoteStatus()
            } else {
                phase = .transferring
                message = "Syncing \(queuedCount) Watch recording\(queuedCount == 1 ? "" : "s") to iPhone…"
            }
            return
        }

        var queuedForTransfer = 0
        for item in candidates {
            let didQueue = bridge.transferWatchRecording(
                fileURL: item.fileURL,
                id: item.id,
                createdAt: item.createdAt,
                duration: item.duration,
                presetID: item.presetID,
                presetName: item.presetName,
                presetSnapshot: item.presetSnapshot
            )

            if didQueue {
                updateQueuedRecording(id: item.id) {
                    $0.transportState = .transferring
                    $0.remotePhase = nil
                    $0.remoteRevision = 0
                    $0.remoteMessage = nil
                }
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
        guard queuedRecordings.contains(where: { $0.id == id }) else { return }
        let didSucceed = notification.userInfo?[WatchRecordingTransferNotificationKey.success] as? Bool ?? false

        if didSucceed {
            let shouldRetry = queuedRecordings.first(where: { $0.id == id })?.remotePhase == .transportFailed
            updateQueuedRecording(id: id) { item in
                item.transportState = shouldRetry ? .local : .uploaded
                if item.remotePhase == nil { item.remotePhase = .queued }
            }
            guard !isRecording else { return }
            if shouldRetry {
                phase = .error("iPhone could not save the transfer.")
                message = "Recording is safe on Watch. Tap Sync Queue to retry."
            } else {
                phase = .waitingForPhone
                message = "Safely queued on iPhone. Waiting to process."
            }
        } else {
            updateQueuedRecording(id: id) { $0.transportState = .local }
            guard !isRecording else { return }
            cancelTransientSuccessReset()
            let errorMessage = notification.userInfo?[WatchRecordingTransferNotificationKey.errorMessage] as? String
            phase = .error("Saved on Watch, sync failed.")
            message = errorMessage.map { "Saved on Watch. Sync failed: \($0)" }
                ?? "Saved on Watch. Tap Sync Queue after your iPhone is nearby."
        }
    }

    func applyRemoteStatuses(
        _ statuses: [WatchRemoteRecordingStatus],
        using bridge: WatchPhoneBridge
    ) {
        guard !statuses.isEmpty else { return }
        var terminalAcknowledgements: [(String, Int)] = []

        for status in statuses {
            guard let existing = queuedRecordings.first(where: { $0.id == status.recordingID }) else {
                if status.phase == .delivered || status.phase == .discarded {
                    terminalAcknowledgements.append((status.recordingID, status.revision))
                }
                continue
            }
            guard status.revision > existing.remoteRevision else { continue }

            if status.phase == .transportFailed {
                updateQueuedRecording(id: status.recordingID) { item in
                    item.transportState = .local
                    item.remotePhase = .transportFailed
                    item.remoteRevision = status.revision
                    item.remoteMessage = status.message
                }
                continue
            }

            updateQueuedRecording(id: status.recordingID) { item in
                item.transportState = .uploaded
                item.remotePhase = status.phase
                item.remoteRevision = status.revision
                item.remoteMessage = status.message
            }

            if status.phase == .delivered || status.phase == .discarded {
                removeQueuedRecording(id: status.recordingID, deleteFile: true)
                terminalAcknowledgements.append((status.recordingID, status.revision))
            }
        }

        for (recordingID, revision) in terminalAcknowledgements {
            bridge.acknowledge(recordingID: recordingID, revision: revision)
        }

        guard !isRecording else { return }
        if queuedRecordings.isEmpty, !terminalAcknowledgements.isEmpty {
            phase = .transferred
            message = "Saved on iPhone. You can record another."
            scheduleTransientSuccessReset()
        } else if !queuedRecordings.isEmpty {
            phase = phaseForMostAdvancedRemoteStatus()
            message = messageForMostAdvancedRemoteStatus()
        }
    }

    private func phaseForMostAdvancedRemoteStatus() -> Phase {
        if queuedRecordings.contains(where: { $0.remotePhase == .delivering }) { return .delivering }
        if queuedRecordings.contains(where: { $0.remotePhase == .transcribing }) { return .transcribing }
        if queuedRecordings.contains(where: { $0.transportState == .transferring }) { return .transferring }
        if queuedRecordings.contains(where: { $0.remotePhase == .transportFailed }) {
            return .error("iPhone could not save the transfer.")
        }
        if queuedRecordings.contains(where: { $0.remotePhase == .failed }) {
            return .error("The recording is saved and needs attention on iPhone.")
        }
        return .waitingForPhone
    }

    private func messageForMostAdvancedRemoteStatus() -> String {
        if queuedRecordings.contains(where: { $0.remotePhase == .delivering }) {
            return remoteMessage(for: .delivering) ?? "Saving the recording on iPhone."
        }
        if queuedRecordings.contains(where: { $0.remotePhase == .transcribing }) {
            return remoteMessage(for: .transcribing)
                ?? "Transcribing on iPhone with on-device speech recognition."
        }
        if queuedRecordings.contains(where: { $0.transportState == .transferring }) {
            return "Syncing recording to iPhone…"
        }
        if queuedRecordings.contains(where: { $0.remotePhase == .transportFailed }) {
            return remoteMessage(for: .transportFailed)
                ?? "Recording is safe on Watch. Tap Sync Queue to retry."
        }
        if queuedRecordings.contains(where: { $0.remotePhase == .failed }) {
            return remoteMessage(for: .failed)
                ?? "Kept safely. Open Vox.md on iPhone to retry."
        }
        return remoteMessage(for: .queued)
            ?? "Safely queued on iPhone. Waiting to process."
    }

    private func remoteMessage(for phase: WatchRemoteRecordingPhase) -> String? {
        guard let raw = queuedRecordings
            .first(where: { $0.remotePhase == phase })?
            .remoteMessage else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        currentPresetID = nil
        currentPresetName = nil
        currentPresetSnapshot = nil
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

    nonisolated private static var activeRecordingURL: URL {
        recordingsDirectoryURL.appendingPathComponent("active-recording.json")
    }

    private func recordingsDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: Self.recordingsDirectoryURL, withIntermediateDirectories: true)
        return Self.recordingsDirectoryURL
    }

    private static func loadQueuedRecordingsRecoveringInterruptedCapture() -> [QueuedRecording] {
        let indexData = try? Data(contentsOf: queueIndexURL)
        let decoded = indexData.flatMap { try? JSONDecoder().decode([QueuedRecording].self, from: $0) }
        let indexCouldNotDecode = indexData != nil && decoded == nil
        var existing = (decoded ?? []).filter {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
        }

        if let activeData = try? Data(contentsOf: activeRecordingURL),
           var interrupted = try? JSONDecoder().decode(QueuedRecording.self, from: activeData),
           FileManager.default.fileExists(atPath: interrupted.fileURL.path),
           !existing.contains(where: { $0.id == interrupted.id }) {
            interrupted.transportState = .local
            interrupted.duration = max(
                interrupted.duration,
                (try? AVAudioPlayer(contentsOf: interrupted.fileURL).duration) ?? 0
            )
            existing.append(interrupted)
        }

        // Recover every orphaned audio file. This is the last line of defense
        // against a corrupt/incompatible index or termination before indexing.
        let audioFiles = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectoryURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in audioFiles where url.pathExtension.lowercased() == "m4a" {
            guard !existing.contains(where: { $0.filename == url.lastPathComponent }) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let id = stem.hasPrefix("watch-") ? String(stem.dropFirst("watch-".count)) : stem
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            existing.append(QueuedRecording(
                id: id,
                filename: url.lastPathComponent,
                createdAt: values?.creationDate ?? values?.contentModificationDate ?? Date(),
                duration: (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
            ))
        }

        existing.sort { $0.createdAt < $1.createdAt }
        do {
            if indexCouldNotDecode {
                let backup = recordingsDirectoryURL.appendingPathComponent(
                    "index-corrupt-\(Int(Date().timeIntervalSince1970)).json"
                )
                try? FileManager.default.copyItem(at: queueIndexURL, to: backup)
            }
            try saveQueuedRecordings(existing)
            clearActiveRecording()
        } catch {
            // Keep the original index/active manifest so a later launch can retry.
        }
        return existing
    }

    private static func saveQueuedRecordings(_ recordings: [QueuedRecording]) throws {
        try FileManager.default.createDirectory(at: recordingsDirectoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(recordings.sorted { $0.createdAt < $1.createdAt })
        try data.write(to: queueIndexURL, options: .atomic)
    }

    private static func saveActiveRecording(_ recording: QueuedRecording) throws {
        try FileManager.default.createDirectory(at: recordingsDirectoryURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(recording).write(to: activeRecordingURL, options: .atomic)
    }

    private static func clearActiveRecording() {
        try? FileManager.default.removeItem(at: activeRecordingURL)
    }

    private func saveQueuedRecordings() {
        try? Self.saveQueuedRecordings(queuedRecordings)
    }

    private func upsertQueuedRecording(_ item: QueuedRecording) throws {
        let previous = queuedRecordings
        queuedRecordings.removeAll { $0.id == item.id }
        queuedRecordings.append(item)
        queuedRecordings.sort { $0.createdAt < $1.createdAt }
        do {
            try Self.saveQueuedRecordings(queuedRecordings)
        } catch {
            queuedRecordings = previous
            throw error
        }
    }

    private func updateQueuedRecording(
        id: String,
        _ mutation: (inout QueuedRecording) -> Void
    ) {
        guard let index = queuedRecordings.firstIndex(where: { $0.id == id }) else { return }
        mutation(&queuedRecordings[index])
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
        currentPresetID = nil
        currentPresetName = nil
        currentPresetSnapshot = nil
        startedAt = nil
        stopTimer()
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
