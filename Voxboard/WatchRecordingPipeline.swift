import Foundation
import Observation
import UIKit
import VoxboardShared

@MainActor
@Observable
final class WatchRecordingPipeline {
    private(set) var items: [WatchRecordingInboxItem] = []
    private(set) var isProcessing = false
    private(set) var activeRecordingID: String?
    private(set) var lastDeliveredURL: URL?

    private let inbox: WatchRecordingInbox
    private let transcriptStore: TranscriptStore
    private let usageTracker: UsageTracker
    private let transcriptionService: OnDeviceTranscriptionService
    private let transcriptEnricher: TranscriptEnricher?
    private weak var recorder: PersistentRecorder?
    private var processingTask: Task<Void, Never>?
    private var inboxObserver: NSObjectProtocol?

    init(
        inbox: WatchRecordingInbox = .shared,
        transcriptStore: TranscriptStore,
        usageTracker: UsageTracker,
        transcriptionService: OnDeviceTranscriptionService,
        transcriptEnricher: TranscriptEnricher?
    ) {
        self.inbox = inbox
        self.transcriptStore = transcriptStore
        self.usageTracker = usageTracker
        self.transcriptionService = transcriptionService
        self.transcriptEnricher = transcriptEnricher
        items = inbox.load()

        inboxObserver = NotificationCenter.default.addObserver(
            forName: WatchRecordingInbox.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.resume()
            }
        }
    }

    var activeItems: [WatchRecordingInboxItem] {
        items.filter { !$0.phase.isTerminal }
    }

    var failedItems: [WatchRecordingInboxItem] {
        items.filter { $0.phase == .failed }
    }

    var recentDeliveredItems: [WatchRecordingInboxItem] {
        items.filter { $0.phase == .delivered && $0.acknowledgedAt == nil }
    }

    var hasVisibleItems: Bool {
        items.contains { item in
            item.phase != .discarded
                && !(item.phase.isTerminal && item.acknowledgedAt != nil)
        }
    }

    var currentItem: WatchRecordingInboxItem? {
        if let activeRecordingID,
           let active = items.first(where: { $0.id == activeRecordingID }) {
            return active
        }
        return activeItems.first(where: { $0.phase == .delivering })
            ?? activeItems.first(where: { $0.phase == .transcribing })
            ?? activeItems.first(where: { $0.phase == .queued })
            ?? activeItems.first(where: { $0.phase == .failed })
            ?? recentDeliveredItems.last
    }

    func configure(recorder: PersistentRecorder) {
        self.recorder = recorder
    }

    func recordingDidArrive() {
        refresh()
        resume()
    }

    func refresh() {
        items = inbox.load()
    }

    func resume() {
        refresh()
        guard processingTask == nil else { return }
        guard recorder?.isSegmentActive != true, recorder?.isTranscribing != true else { return }

        recoverInterruptedItems()
        guard items.contains(where: { $0.phase == .queued }) else {
            reconcileDeliveredCaptureRequests()
            return
        }
        if usageTracker.isAtLimit && !items.contains(where: isDeliveryOnlyRetry) {
            markQueuedItemsWaitingForUnlock()
            return
        }

        processingTask = Task { @MainActor [weak self] in
            await self?.drainQueue()
        }
    }

    func retry(_ item: WatchRecordingInboxItem) {
        guard activeRecordingID != item.id,
              let latest = inbox.load().first(where: { $0.id == item.id }),
              latest.phase == .failed,
              !latest.requiresPresetSelection else { return }
        _ = inbox.transition(
            id: item.id,
            to: .queued,
            message: "Queued to retry on iPhone"
        )
        refresh()
        resume()
    }

    func choosePreset(_ preset: CapturePreset, for item: WatchRecordingInboxItem) {
        guard preset.isEnabled,
              activeRecordingID != item.id,
              let latest = inbox.load().first(where: { $0.id == item.id }),
              latest.requiresPresetSelection,
              latest.phase == .failed || latest.phase == .queued else { return }
        _ = inbox.update(id: item.id) { updated in
            updated.flowSnapshot = preset
            updated.flowSnapshotPayload = try? JSONEncoder().encode(preset)
            updated.requiresPresetSelection = false
            updated.phase = .queued
            updated.failureStage = nil
            updated.statusMessage = "Recovered with \(preset.displayName); queued to retry"
        }
        refresh()
        resume()
    }

    func discard(_ item: WatchRecordingInboxItem) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.activeRecordingID != item.id,
                  let latest = self.inbox.load().first(where: { $0.id == item.id }),
                  latest.phase == .queued || latest.phase == .failed else {
                self?.refresh()
                return
            }

            if let captureRootURL = AppConstants.captureDirectoryURL {
                let captureInbox = CaptureInbox(rootDirectoryURL: captureRootURL)
                let state: CaptureInboxState?
                do {
                    state = try await captureInbox.state(of: latest.requestID)
                } catch {
                    _ = self.inbox.transition(
                        id: latest.id,
                        to: latest.phase,
                        failureStage: latest.failureStage,
                        message: "Could not verify Capture delivery. Try discarding again."
                    )
                    self.refresh()
                    return
                }
                if state == .completed {
                    _ = self.inbox.markDelivered(id: latest.id)
                    self.refresh()
                    WatchRecordingController.shared.publishState()
                    return
                }
                if state == .processing {
                    _ = self.inbox.transition(
                        id: latest.id,
                        to: latest.phase,
                        failureStage: latest.failureStage,
                        message: "Capture delivery is active. Wait a moment before discarding."
                    )
                    self.refresh()
                    WatchRecordingController.shared.publishState()
                    return
                }
                if state == .pending || state == .failed {
                    let didDiscard = (try? await captureInbox.discard(requestID: latest.requestID)) == true
                    guard didDiscard else {
                        self.refresh()
                        return
                    }
                }
            }
            self.transcriptStore.delete(ids: [latest.requestID])
            _ = self.inbox.discard(id: latest.id)
            self.refresh()
            WatchRecordingController.shared.publishState()
        }
    }

    private func drainQueue() async {
        isProcessing = true
        var backgroundTask = beginBackgroundTaskIfNeeded()
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
            activeRecordingID = nil
            isProcessing = false
            processingTask = nil
            refresh()
            WatchRecordingController.shared.publishState()
        }

        while !Task.isCancelled {
            refresh()
            guard recorder?.isSegmentActive != true, recorder?.isTranscribing != true else { return }
            let item: WatchRecordingInboxItem?
            if usageTracker.isAtLimit {
                item = items.first(where: isDeliveryOnlyRetry)
                if item == nil {
                    markQueuedItemsWaitingForUnlock()
                    return
                }
            } else {
                item = items.first(where: { $0.phase == .queued })
            }
            guard let item else { return }

            activeRecordingID = item.id
            do {
                try await process(item)
            } catch is CancellationError {
                _ = inbox.transition(id: item.id, to: .queued, message: "Waiting for iPhone")
                return
            } catch let error as WatchRecordingPipelineError {
                _ = inbox.transition(
                    id: item.id,
                    to: .failed,
                    failureStage: error.stage,
                    message: error.localizedDescription
                )
            } catch {
                _ = inbox.transition(
                    id: item.id,
                    to: .failed,
                    failureStage: .delivery,
                    message: error.localizedDescription
                )
            }
            refresh()
            WatchRecordingController.shared.publishState()
        }
    }

    private func process(_ originalItem: WatchRecordingInboxItem) async throws {
        try ensureProcessingIsActive(for: originalItem.id)
        let item = originalItem.flowSnapshot == nil
            ? (inbox.ensureFlowSnapshot(id: originalItem.id) ?? originalItem)
            : originalItem
        guard let flow = item.flowSnapshot else {
            throw WatchRecordingPipelineError(
                stage: .storage,
                message: item.requiresPresetSelection
                    ? "Choose a Capture Preset for this recovered recording."
                    : item.flowSnapshotPayload == nil
                        ? "Choose a Capture Preset on iPhone, then retry."
                        : "Update Vox.md on iPhone to use this recording's Capture Preset."
            )
        }
        guard item.hasAudio || transcriptStore.transcripts.contains(where: { $0.id == item.requestID }) else {
            throw WatchRecordingPipelineError(
                stage: .storage,
                message: "The Watch audio is missing. Record again on Apple Watch."
            )
        }

        let transcript: Transcript
        if let existing = transcriptStore.transcripts.first(where: { $0.id == item.requestID }) {
            transcript = existing
        } else {
            _ = inbox.transition(
                id: item.id,
                to: .transcribing,
                message: "Transcribing on iPhone"
            )
            refresh()
            WatchRecordingController.shared.publishState()

            let result = try await transcribe(item)
            try ensureProcessingIsActive(for: item.id)
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WatchRecordingPipelineError(
                    stage: .transcription,
                    message: "No recognizable speech was found. The recording is kept for retry."
                )
            }

            let raw = Transcript(
                id: item.requestID,
                text: result.text,
                date: item.createdAt,
                duration: item.duration ?? AudioFileConverter.duration(of: item.fileURL) ?? 0,
                modelUsed: result.backendName,
                language: result.language
            )
            let formatted = TranscriptFlowFormatter.apply(flow: flow, to: raw)
            transcriptStore.add(formatted)
            usageTracker.addUsage(seconds: formatted.duration)
            transcript = formatted
        }

        _ = inbox.transition(
            id: item.id,
            to: .delivering,
            message: "Saving with \(flow.displayName)"
        )
        refresh()
        WatchRecordingController.shared.publishState()

        let latestTranscript: Transcript
        if let transcriptEnricher, flow.usesAIEnrichment {
            await transcriptEnricher.enrichAndUpdate(
                transcript: transcript,
                flow: flow,
                into: transcriptStore
            )
            latestTranscript = transcriptStore.transcripts.first(where: { $0.id == transcript.id }) ?? transcript
        } else {
            latestTranscript = transcript
        }
        try ensureProcessingIsActive(for: item.id)

        guard let captureRootURL = AppConstants.captureDirectoryURL else {
            throw WatchRecordingPipelineError(
                stage: .storage,
                message: "Shared Capture storage is unavailable."
            )
        }
        let captureInbox = CaptureInbox(rootDirectoryURL: captureRootURL)
        _ = try? await captureInbox.recoverStaleProcessing(olderThan: 5 * 60)
        let existingState = try await captureInbox.state(of: item.requestID)
        if existingState == .completed {
            complete(item)
            return
        }
        if existingState == .failed {
            _ = try await captureInbox.retryFailed(requestID: item.requestID)
        }
        if existingState == .processing {
            throw WatchRecordingPipelineError(
                stage: .delivery,
                message: "Capture delivery is still in progress. Try again shortly."
            )
        }

        guard let destinationID = await ConfiguredTranscriptCaptureDestinationExporter
            .resolvedDestinationID(flow: flow) else {
            throw WatchRecordingPipelineError(
                stage: .delivery,
                message: "Set a destination for \(flow.displayName) on iPhone, then retry."
            )
        }

        try ensureProcessingIsActive(for: item.id)
        do {
            let receipt = try await ConfiguredTranscriptCaptureDestinationExporter.export(
                transcript: latestTranscript,
                flow: flow,
                destinationID: destinationID,
                audioSourceURL: flow.audioSaveMode == .off ? nil : item.fileURL,
                source: .watch
            )
            try ensureProcessingIsActive(for: item.id)
            lastDeliveredURL = receipt.noteURL
            complete(item)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WatchRecordingPipelineError(
                stage: .delivery,
                message: "Capture could not be delivered. The transcript and audio are saved for retry."
            )
        }
    }

    private func transcribe(_ item: WatchRecordingInboxItem) async throws -> OnDeviceTranscriptionResult {
        let sourceURL = item.fileURL
        let workingURL = (AppConstants.recordingsDirectoryURL ?? WatchRecordingInbox.inboxDirectory)
            .appendingPathComponent("watch-transcription-\(item.requestID.uuidString.lowercased())")
            .appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: workingURL)
        defer { try? FileManager.default.removeItem(at: workingURL) }

        do {
            let conversionTask = Task.detached(priority: .userInitiated) {
                try AudioFileConverter.convertToWhisperWAV(
                    inputURL: sourceURL,
                    outputURL: workingURL
                )
            }
            let convertedURL = try await withTaskCancellationHandler {
                try await conversionTask.value
            } onCancel: {
                conversionTask.cancel()
            }
            try Task.checkCancellation()
            let modelID = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
                ?? AppConstants.defaultTranscriptionBackendID
            let language = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey)
                ?? "auto"
            let result = try await transcriptionService.transcribeResult(
                audioURL: convertedURL,
                modelID: modelID,
                fallbackModelID: AppConstants.sharedDefaults?.string(
                    forKey: AppConstants.selectedFallbackModelKey
                ),
                language: language
            )
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WatchRecordingPipelineError(
                stage: .transcription,
                message: "Transcription failed. The Watch recording is saved for retry."
            )
        }
    }

    private func ensureProcessingIsActive(for id: String) throws {
        try Task.checkCancellation()
        guard activeRecordingID == id,
              let latest = inbox.load().first(where: { $0.id == id }),
              !latest.phase.isTerminal else {
            throw CancellationError()
        }
    }

    private func complete(_ item: WatchRecordingInboxItem) {
        _ = inbox.markDelivered(id: item.id)
        refresh()
        WatchRecordingController.shared.publishState()
    }

    private func recoverInterruptedItems() {
        for item in items where item.phase == .transcribing || item.phase == .delivering {
            _ = inbox.transition(
                id: item.id,
                to: .queued,
                message: transcriptStore.transcripts.contains(where: { $0.id == item.requestID })
                    ? "Resuming Capture delivery"
                    : "Resuming Watch transcription"
            )
        }
        refresh()
    }

    private func reconcileDeliveredCaptureRequests() {
        guard let captureRootURL = AppConstants.captureDirectoryURL else { return }
        let candidates = items.filter { $0.phase == .failed || $0.phase == .delivering }
        guard !candidates.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let captureInbox = CaptureInbox(rootDirectoryURL: captureRootURL)
            for item in candidates {
                if (try? await captureInbox.state(of: item.requestID)) == .completed {
                    self.complete(item)
                }
            }
        }
    }

    private func isDeliveryOnlyRetry(_ item: WatchRecordingInboxItem) -> Bool {
        item.phase == .queued
            && transcriptStore.transcripts.contains(where: { $0.id == item.requestID })
    }

    private func markQueuedItemsWaitingForUnlock() {
        for item in items where item.phase == .queued
            && !isDeliveryOnlyRetry(item)
            && item.statusMessage != "Unlock Vox.md on iPhone to transcribe" {
            _ = inbox.transition(
                id: item.id,
                to: .queued,
                message: "Unlock Vox.md on iPhone to transcribe"
            )
        }
        refresh()
        WatchRecordingController.shared.publishState()
    }

    private func beginBackgroundTaskIfNeeded() -> UIBackgroundTaskIdentifier {
        // Begin while foregrounded too; this protection remains valid if the
        // user backgrounds the app during transcription or Capture delivery.
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: "WatchRecordingPipeline") { [weak self] in
            Task { @MainActor [weak self] in
                self?.processingTask?.cancel()
            }
        }
        return identifier
    }
}

private struct WatchRecordingPipelineError: Error, LocalizedError {
    let stage: WatchRecordingFailureStage
    let message: String

    var errorDescription: String? { message }
}
