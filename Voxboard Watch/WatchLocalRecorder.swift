import AVFoundation
import CoreLocation
import Foundation
import VoxboardCaptureCore
import WidgetKit

@MainActor
final class WatchLocalRecorder: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case paused
        case locating
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
        /// Privacy-adjusted Watch-origin result captured exactly once when the
        /// recording stopped. Sync retries transfer this same durable value.
        var locationOutcome: CaptureLocationOutcome?

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
            presetSnapshot: Data? = nil,
            locationOutcome: CaptureLocationOutcome? = nil
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
            self.locationOutcome = locationOutcome
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
            case locationOutcome
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
                presetSnapshot: try container.decodeIfPresent(Data.self, forKey: .presetSnapshot),
                locationOutcome: try container.decodeIfPresent(CaptureLocationOutcome.self, forKey: .locationOutcome)
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

    /// Whether a recording session is active, including while audio capture is paused.
    var isRecording: Bool {
        switch phase {
        case .recording, .paused:
            return true
        default:
            return false
        }
    }

    var isPaused: Bool {
        if case .paused = phase { return true }
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
            return queuedCount > 0 ? String(localized: "Saved") : "Vox.md"
        case .recording:
            return String(localized: "Recording")
        case .paused:
            return String(localized: "Paused")
        case .locating:
            return String(localized: "Adding Location")
        case .transferring:
            return String(localized: "Syncing")
        case .waitingForPhone:
            return String(localized: "On iPhone")
        case .transcribing:
            return String(localized: "Transcribing")
        case .delivering:
            return String(localized: "Saving")
        case .transferred:
            return String(localized: "Saved")
        case .error:
            return queuedCount > 0 ? String(localized: "Saved") : String(localized: "Needs attention")
        }
    }

    var subtitle: String {
        if let message, !message.isEmpty { return message }
        switch phase {
        case .idle:
            if queuedCount > 0 {
                return queueSummary + " " + String(localized: "Tap Sync Queue when your iPhone is nearby.")
            }
            return String(localized: "Record on this Watch. Syncs to iPhone later.")
        case .recording:
            return String(localized: "Pause when you need a break, or stop when your thought is captured.")
        case .paused:
            return String(localized: "Recording paused. Resume when you're ready, or stop to save it.")
        case .locating:
            return String(localized: "Getting this Watch’s location once before saving.")
        case .transferring:
            return String(localized: "Sending Watch recordings to the iPhone queue.")
        case .waitingForPhone:
            return String(localized: "Safely queued on iPhone and waiting to process.")
        case .transcribing:
            return String(localized: "Your iPhone is transcribing this recording on device.")
        case .delivering:
            return String(localized: "Your iPhone is saving this recording.")
        case .transferred:
            return String(localized: "Saved on iPhone. You can record another.")
        case .error(let error):
            return error
        }
    }

    var actionTitle: String {
        isRecording ? String(localized: "Stop") : String(localized: "Record")
    }

    var actionSymbol: String {
        isRecording ? "stop.fill" : "mic.fill"
    }

    var syncTitle: String {
        if hasUnuploadedRecordings { return String(localized: "Sync Queue (\(queuedCount))") }
        return queuedCount > 0 ? String(localized: "Refresh Status") : String(localized: "Sync Status")
    }

    var queueSummary: String {
        let saved = queuedCount == 1
            ? String(localized: "1 recording saved on Watch.")
            : String(localized: "\(queuedCount) recordings saved on Watch.")
        let unavailable = queuedRecordings.filter {
            if case .unavailable = $0.locationOutcome { return true }
            return false
        }
        guard !unavailable.isEmpty else { return saved }
        let behaviors = unavailable.map(locationUnavailableBehavior)
        var details: [String] = []
        let askCount = behaviors.filter { $0 == .ask }.count
        let sendCount = behaviors.filter { $0 == .sendWithoutLocation }.count
        let cancelCount = behaviors.filter { $0 == .cancel }.count
        if askCount > 0 {
            details.append(askCount == 1
                ? String(localized: "iPhone will ask about 1 unavailable location.")
                : String(localized: "iPhone will ask about \(askCount) unavailable locations."))
        }
        if sendCount > 0 {
            details.append(sendCount == 1
                ? String(localized: "1 recording will send without location.")
                : String(localized: "\(sendCount) recordings will send without location."))
        }
        if cancelCount > 0 {
            details.append(cancelCount == 1
                ? String(localized: "1 recording will be canceled because location is required.")
                : String(localized: "\(cancelCount) recordings will be canceled because location is required."))
        }
        return saved + " " + details.joined(separator: " ")
    }

    private func locationUnavailableBehavior(
        for item: QueuedRecording
    ) -> CaptureLocationUnavailableBehavior {
        guard let data = item.presetSnapshot,
              let profile = try? JSONDecoder().decode(CapturePresetProfile.self, from: data) else {
            return .ask
        }
        return profile.locationPolicy.unavailableBehavior
    }

    private var widgetPhase: WatchRecordingPhase {
        switch phase {
        case .idle:
            return .idle
        case .recording:
            return .recording
        case .paused:
            return .paused
        case .locating:
            return .pending
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
        let widgetTimerStartedAt = phase == .recording
            ? Date().addingTimeInterval(-duration).timeIntervalSince1970
            : nil
        let snapshot = WatchRecordingSnapshot(
            phase: widgetPhase,
            isQuickRecordEnabled: true,
            recordingStartedAt: widgetTimerStartedAt,
            recordingDuration: isRecording ? duration : nil,
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

    func togglePause() {
        if isPaused {
            resumeRecording()
        } else {
            pauseRecording()
        }
    }

    func pauseRecording() {
        guard case .recording = phase, let recorder else { return }
        recorder.pause()
        duration = max(duration, recorder.currentTime)
        stopTimer()
        message = nil
        phase = .paused
    }

    func resumeRecording() {
        guard case .paused = phase, let recorder else { return }
        guard recorder.record() else {
            message = String(localized: "Could not resume this recording. Stop to save what was captured.")
            return
        }

        duration = max(duration, recorder.currentTime)
        message = nil
        phase = .recording
        startTimer()
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
                setError(String(localized: "Enable a Capture Preset in Vox.md on iPhone before recording."))
                return
            }
        }

        let hasPermission = await requestMicrophonePermission()
        guard hasPermission else {
            setError(String(localized: "Microphone permission required on Apple Watch."))
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
                setError(String(localized: "Could not safely journal this Watch recording."))
                return
            }
            guard recorder.record() else {
                Self.clearActiveRecording()
                try? FileManager.default.removeItem(at: url)
                setError(String(localized: "Could not start Watch recording."))
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
            setError(String(localized: "Watch microphone error: \(error.localizedDescription)"))
        }
    }

    func cancelRecording() {
        guard let recorder else { return }
        cancelTransientSuccessReset()

        let url = recorder.url
        recorder.stop()
        _ = recorder.deleteRecording()
        self.recorder = nil
        currentRecordingID = nil
        currentPresetID = nil
        currentPresetName = nil
        currentPresetSnapshot = nil
        startedAt = nil
        duration = 0
        stopTimer()
        try? AVAudioSession.sharedInstance().setActive(false)
        Self.clearActiveRecording()

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                phase = .error(String(localized: "Could not delete the canceled recording."))
                message = String(localized: "Recording stopped, but its file could not be deleted from this Watch.")
                return
            }
        }

        phase = .idle
        message = String(localized: "Recording canceled and deleted.")
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
            setError(String(localized: "Watch recording file was not saved."))
            return
        }

        let profile = presetSnapshot.flatMap {
            try? JSONDecoder().decode(CapturePresetProfile.self, from: $0)
        }
        let enabledLocationPolicy = CaptureWatchLocationAcquisitionPolicy
            .shouldAcquire(presetSnapshot: presetSnapshot)
            ? profile?.locationPolicy
            : nil
        let stoppedAt = Date()
        var item = QueuedRecording(
            id: id,
            filename: url.lastPathComponent,
            createdAt: createdAt,
            duration: recordedDuration,
            presetID: presetID,
            presetName: presetName,
            presetSnapshot: presetSnapshot,
            // Journal an origin-time placeholder synchronously after stop. If
            // watchOS terminates during permission or location work, recovery
            // retains a meaningful unavailable result rather than nil.
            locationOutcome: enabledLocationPolicy.map {
                _ in .unavailable(.unavailable, attemptedAt: stoppedAt)
            }
        )
        do {
            try Self.saveActiveRecording(item)
        } catch {
            phase = .error(String(localized: "The recording is safe, but its stop state could not be journaled."))
            message = String(localized: "Recording retained on Watch. Reopen Vox.md to recover it.")
            return
        }

        if let enabledLocationPolicy {
            phase = .locating
            message = String(localized: "Recording saved. Getting this Watch’s location once…")
            item.locationOutcome = await WatchCaptureLocationProvider().resolve(
                policy: enabledLocationPolicy,
                attemptedAt: stoppedAt
            )
            do {
                // Atomic replacement closes the crash window between the
                // placeholder and the final privacy-adjusted outcome.
                try Self.saveActiveRecording(item)
            } catch {
                phase = .error(String(localized: "The recording is safe with its origin-time location status."))
                message = String(localized: "Reopen Vox.md to recover and sync this recording.")
                return
            }
        }

        do {
            try upsertQueuedRecording(item)
            Self.clearActiveRecording()
        } catch {
            phase = .error(String(localized: "The recording is safe, but its queue could not be updated."))
            message = String(localized: "Recording retained on Watch. Reopen Vox.md to recover it.")
            return
        }
        phase = .idle
        message = String(localized: "Saved on Watch. Syncing to iPhone…")
        syncPending(using: bridge)
    }

    func syncPending(using bridge: WatchPhoneBridge) {
        cancelTransientSuccessReset()
        pruneMissingQueuedRecordings()

        guard !queuedRecordings.isEmpty else {
            if !isRecording {
                phase = .idle
                message = String(localized: "No Watch recordings waiting to sync.")
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
                message = queuedCount == 1
                    ? String(localized: "Syncing 1 Watch recording to iPhone…")
                    : String(localized: "Syncing \(queuedCount) Watch recordings to iPhone…")
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
                presetSnapshot: item.presetSnapshot,
                locationOutcome: item.locationOutcome.flatMap { try? JSONEncoder().encode($0) }
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
            message = queuedCount == 1
                ? String(localized: "Syncing 1 Watch recording to iPhone…")
                : String(localized: "Syncing \(queuedCount) Watch recordings to iPhone…")
        } else {
            phase = .error(String(localized: "Saved on Watch, but iPhone sync is unavailable."))
            message = String(localized: "Saved on Watch. Tap Sync Queue after your iPhone is nearby.")
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
                phase = .error(String(localized: "iPhone could not save the transfer."))
                message = String(localized: "Recording is safe on Watch. Tap Sync Queue to retry.")
            } else {
                phase = .waitingForPhone
                message = String(localized: "Safely queued on iPhone. Waiting to process.")
            }
        } else {
            updateQueuedRecording(id: id) { $0.transportState = .local }
            guard !isRecording else { return }
            cancelTransientSuccessReset()
            let errorMessage = notification.userInfo?[WatchRecordingTransferNotificationKey.errorMessage] as? String
            phase = .error(String(localized: "Saved on Watch, sync failed."))
            message = errorMessage.map { String(localized: "Saved on Watch. Sync failed: \($0)") }
                ?? String(localized: "Saved on Watch. Tap Sync Queue after your iPhone is nearby.")
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
            message = String(localized: "Saved on iPhone. You can record another.")
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
            return .error(String(localized: "iPhone could not save the transfer."))
        }
        if queuedRecordings.contains(where: { $0.remotePhase == .failed }) {
            return .error(String(localized: "The recording is saved and needs attention on iPhone."))
        }
        return .waitingForPhone
    }

    private func messageForMostAdvancedRemoteStatus() -> String {
        if queuedRecordings.contains(where: { $0.remotePhase == .delivering }) {
            return remoteMessage(for: .delivering) ?? String(localized: "Saving the recording on iPhone.")
        }
        if queuedRecordings.contains(where: { $0.remotePhase == .transcribing }) {
            return remoteMessage(for: .transcribing)
                ?? String(localized: "Transcribing on iPhone with on-device speech recognition.")
        }
        if queuedRecordings.contains(where: { $0.transportState == .transferring }) {
            return String(localized: "Syncing recording to iPhone…")
        }
        if queuedRecordings.contains(where: { $0.remotePhase == .transportFailed }) {
            return remoteMessage(for: .transportFailed)
                ?? String(localized: "Recording is safe on Watch. Tap Sync Queue to retry.")
        }
        if queuedRecordings.contains(where: { $0.remotePhase == .failed }) {
            return remoteMessage(for: .failed)
                ?? String(localized: "Kept safely. Open Vox.md on iPhone to retry.")
        }
        return remoteMessage(for: .queued)
            ?? String(localized: "Safely queued on iPhone. Waiting to process.")
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
    @discardableResult
    func configureLocalizationScreenshotIfNeeded() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--localization-screenshot"),
              arguments.indices.contains(index + 1) else { return false }

        switch arguments[index + 1] {
        case "01-ready":
            resetDemoState(
                phase: .idle,
                queuedCount: 0,
                message: String(localized: "Record on this Watch. Syncs to iPhone later.")
            )
        case "02-recording":
            resetDemoState(phase: .recording, queuedCount: 0, message: nil)
            startedAt = Date().addingTimeInterval(-42)
            duration = 42
        case "03-synced":
            resetDemoState(
                phase: .transferred,
                queuedCount: 0,
                message: String(localized: "Synced to iPhone queue. You can record another.")
            )
        default:
            return false
        }
        return true
    }

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
            message: String(localized: "Record on this Watch. Syncs to iPhone later.")
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
        message = String(localized: "Saved on Watch. Syncing to iPhone…")
        await sleepForDemo(seconds: 1.8)

        guard !Task.isCancelled else { return }
        phase = .transferring
        message = String(localized: "Sending Watch recording to the iPhone queue.")
        await sleepForDemo(seconds: 1.8)

        guard !Task.isCancelled else { return }
        setDemoQueue(count: 0)
        phase = .transferred
        message = String(localized: "Synced to iPhone queue. You can record another.")
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
        message = String(localized: "Syncing 2 Watch recordings to iPhone…")
        await sleepForDemo(seconds: 3.0)

        guard !Task.isCancelled else { return }
        setDemoQueue(count: 0)
        phase = .transferred
        message = String(localized: "Synced to iPhone queue. You can record another.")
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
            if interrupted.locationOutcome == nil,
               CaptureWatchLocationAcquisitionPolicy.shouldAcquire(
                   presetSnapshot: interrupted.presetSnapshot
               ) {
                // Termination before the normal stop journal cannot safely be
                // replaced by a later fix. Preserve a typed unavailable result.
                interrupted.locationOutcome = .unavailable(
                    .unavailable,
                    attemptedAt: Date()
                )
            }
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
                guard let self, let recorder = self.recorder else { return }
                self.duration = max(self.duration, recorder.currentTime)
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
        duration = 0
        stopTimer()
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

@MainActor
private final class WatchCaptureLocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var requiresFullAccuracy = false

    override init() {
        super.init()
        manager.delegate = self
    }

    func resolve(
        policy: CapturePresetLocationPolicy,
        attemptedAt: Date = Date()
    ) async -> CaptureLocationOutcome {
        requiresFullAccuracy = policy.precision == .exact
        manager.desiredAccuracy = policy.precision == .exact
            ? kCLLocationAccuracyBest
            : kCLLocationAccuracyKilometer
        do {
            let raw = try await requestLocation()
            let adjusted = CaptureLocationSnapshot(
                latitude: raw.coordinate.latitude,
                longitude: raw.coordinate.longitude,
                horizontalAccuracy: raw.horizontalAccuracy >= 0 ? raw.horizontalAccuracy : nil,
                timestamp: raw.timestamp,
                source: .watch,
                precision: policy.precision
            )
            var label: CaptureLocationLabel?
            if policy.requiresLabels {
                // City privacy is applied before any coordinate leaves the
                // process through Apple's reverse-geocoding service.
                let geocodeLocation = CLLocation(
                    coordinate: CLLocationCoordinate2D(
                        latitude: adjusted.latitude,
                        longitude: adjusted.longitude
                    ),
                    altitude: 0,
                    horizontalAccuracy: adjusted.horizontalAccuracy ?? -1,
                    verticalAccuracy: -1,
                    timestamp: adjusted.timestamp
                )
                label = try? await reverseGeocode(geocodeLocation)
            }
            return .available(CaptureLocationSnapshot(
                latitude: adjusted.latitude,
                longitude: adjusted.longitude,
                horizontalAccuracy: adjusted.horizontalAccuracy,
                timestamp: adjusted.timestamp,
                source: .watch,
                precision: adjusted.precision,
                label: label
            ))
        } catch is CancellationError {
            return .unavailable(.cancelled, attemptedAt: attemptedAt)
        } catch let error as CLError where error.code == .denied {
            return .unavailable(.permissionDenied, attemptedAt: attemptedAt)
        } catch let error as WatchLocationError {
            return .unavailable(error.reason, attemptedAt: attemptedAt)
        } catch {
            return .unavailable(.unavailable, attemptedAt: attemptedAt)
        }
    }

    private func requestLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw WatchLocationError(.unavailable)
        }
        guard continuation == nil else { throw WatchLocationError(.unavailable) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                switch manager.authorizationStatus {
                case .authorizedAlways, .authorizedWhenInUse:
                    beginLocationRequest()
                case .notDetermined:
                    startTimeout(.seconds(60))
                    manager.requestWhenInUseAuthorization()
                case .denied:
                    finish(.failure(WatchLocationError(.permissionDenied)))
                case .restricted:
                    finish(.failure(WatchLocationError(.restricted)))
                @unknown default:
                    finish(.failure(WatchLocationError(.unavailable)))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func beginLocationRequest() {
        if requiresFullAccuracy, manager.accuracyAuthorization == .reducedAccuracy {
            finish(.failure(WatchLocationError(.reducedAccuracy)))
            return
        }
        startTimeout(.seconds(15))
        manager.requestLocation()
    }

    private func startTimeout(_ duration: Duration) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(WatchLocationError(.timeout)))
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
        continuation.resume(with: result)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            beginLocationRequest()
        case .denied:
            finish(.failure(WatchLocationError(.permissionDenied)))
        case .restricted:
            finish(.failure(WatchLocationError(.restricted)))
        case .notDetermined:
            break
        @unknown default:
            finish(.failure(WatchLocationError(.unavailable)))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: {
            $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) < 30
        }) else { return }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func reverseGeocode(_ location: CLLocation) async throws -> CaptureLocationLabel? {
        try await withThrowingTaskGroup(of: CaptureLocationLabel?.self) { group in
            group.addTask {
                guard let placemark = try await CLGeocoder().reverseGeocodeLocation(location).first else {
                    return nil
                }
                return CaptureLocationLabel(
                    place: placemark.name,
                    city: placemark.locality ?? placemark.subLocality,
                    region: placemark.administrativeArea,
                    country: placemark.country
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw WatchLocationError(.timeout)
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }
}

private struct WatchLocationError: Error {
    let reason: CaptureLocationUnavailableReason
    init(_ reason: CaptureLocationUnavailableReason) { self.reason = reason }
}
