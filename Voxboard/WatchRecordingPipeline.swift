import Foundation
import Observation
import os.log
import UIKit
import UserNotifications
import VoxboardShared

private let watchPipelineBackgroundLog = Logger(
    subsystem: "bontecou.Voxboard",
    category: "WatchRecordingBackground"
)

private struct WatchTranscriptionOutput: Sendable {
    let result: OnDeviceTranscriptionResult
    let text: String
    let speakerTurns: [TranscriptSpeakerTurn]?
}

@MainActor
@Observable
final class WatchRecordingPipeline {
    private(set) var items: [WatchRecordingInboxItem] = []
    private(set) var isProcessing = false
    private(set) var activeRecordingID: String?
    private(set) var lastDeliveredRecordingID: String?

    private let inbox: WatchRecordingInbox
    private let transcriptStore: TranscriptStore
    private let usageTracker: UsageTracker
    private let transcriptionService: OnDeviceTranscriptionService
    private let speakerDiarizationService: SpeakerDiarizationService
    private let transcriptEnricher: TranscriptEnricher?
    private let backgroundTaskService: any WatchRecordingBackgroundTaskServicing
    private weak var recorder: PersistentRecorder?
    private var processingTask: Task<Void, Never>?
    private var activeBackgroundLease: WatchRecordingBackgroundLease?
    private var pendingBackgroundLease: WatchRecordingBackgroundLease?
    private var isStoppingAfterExpiration = false
    private var inboxObserver: NSObjectProtocol?

    init(
        inbox: WatchRecordingInbox = .shared,
        transcriptStore: TranscriptStore,
        usageTracker: UsageTracker,
        transcriptionService: OnDeviceTranscriptionService,
        speakerDiarizationService: SpeakerDiarizationService = SpeakerDiarizationService(),
        transcriptEnricher: TranscriptEnricher?,
        backgroundTaskService: (any WatchRecordingBackgroundTaskServicing)? = nil
    ) {
        self.inbox = inbox
        self.transcriptStore = transcriptStore
        self.usageTracker = usageTracker
        self.transcriptionService = transcriptionService
        self.speakerDiarizationService = speakerDiarizationService
        self.transcriptEnricher = transcriptEnricher
        self.backgroundTaskService = backgroundTaskService
            ?? WatchRecordingBackgroundTaskClient.live()
        items = inbox.load()

        inboxObserver = NotificationCenter.default.addObserver(
            forName: WatchRecordingInbox.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // WCSession arrivals hand their already-acquired background
                // lease to `recordingDidArrive`. Starting from this observer can
                // race that handoff and create an unnecessary second assertion.
                self?.refresh()
            }
        }
    }

    var activeItems: [WatchRecordingInboxItem] {
        items.filter { !$0.phase.isTerminal }
    }

    var failedItems: [WatchRecordingInboxItem] {
        items.filter { $0.phase == .failed }
    }

    var hasVisibleItems: Bool {
        !activeItems.isEmpty
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
    }

    func configure(recorder: PersistentRecorder) {
        self.recorder = recorder
    }

    func recordingDidArrive(
        recordingID: String,
        backgroundLease: WatchRecordingBackgroundLease
    ) {
        watchPipelineBackgroundLog.notice(
            "Adopting received recording token=\(backgroundLease.token.uuidString, privacy: .public) recording=\(recordingID, privacy: .public)"
        )
        resume(backgroundLease: backgroundLease)
    }

    func backgroundLeaseDidExpire(_ token: UUID) {
        if activeBackgroundLease?.token == token {
            isStoppingAfterExpiration = true
            activeRecordingID = nil
            watchPipelineBackgroundLog.error(
                "Cancelling Watch delivery after lease expiration token=\(token.uuidString, privacy: .public)"
            )
            processingTask?.cancel()
        } else if pendingBackgroundLease?.token == token {
            pendingBackgroundLease = nil
        }
    }

    func refresh() {
        items = inbox.load()
    }

    func resume() {
        resume(backgroundLease: nil)
    }

    private func resume(backgroundLease incomingLease: WatchRecordingBackgroundLease?) {
        refresh()
        if processingTask != nil {
            if let incomingLease {
                adoptLeaseWhileProcessing(incomingLease)
            }
            return
        }

        if let orphanedLease = activeBackgroundLease {
            activeBackgroundLease = nil
            orphanedLease.end(.completed)
        }

        recoverInterruptedItems()
        let recorderIsBusy = recorder?.isSegmentActive == true || recorder?.isTranscribing == true
        let processableItems = items.filter {
            $0.phase == .queued && (!recorderIsBusy || canRunWhileRecorderIsBusy($0))
        }
        guard !processableItems.isEmpty else {
            incomingLease?.end(.noProcessableWork)
            reconcileDeliveredCaptureRequests()
            return
        }
        if usageTracker.isAtLimit && !processableItems.contains(where: canRunWithoutTranscriptionUsage) {
            incomingLease?.end(.noProcessableWork)
            markQueuedItemsWaitingForUnlock()
            return
        }

        isStoppingAfterExpiration = false
        let lease = incomingLease ?? makeBackgroundLease(
            recordingID: processableItems.first?.id
        )
        guard WatchRecordingBackgroundExecutionPolicy.shouldStart(
            leaseIsActive: lease.isActive,
            applicationIsActive: UIApplication.shared.applicationState == .active
        ) else {
            // The assertion may have expired before WCSession's MainActor
            // handoff, or UIKit may have declined it. Keep the durable inbox
            // item queued rather than starting work that iOS can immediately
            // suspend. A foreground launch or later Watch event will retry it.
            watchPipelineBackgroundLog.error(
                "Deferring Watch queue drain without background execution token=\(lease.token.uuidString, privacy: .public)"
            )
            lease.end(.noProcessableWork)
            return
        }
        activeBackgroundLease = lease
        watchPipelineBackgroundLog.notice(
            "Starting Watch queue drain token=\(lease.token.uuidString, privacy: .public) active=\(lease.isActive, privacy: .public)"
        )
        processingTask = Task { @MainActor [weak self] in
            await self?.drainQueue()
        }
    }

    private func adoptLeaseWhileProcessing(_ incomingLease: WatchRecordingBackgroundLease) {
        guard incomingLease.isActive else {
            incomingLease.end(.coalesced)
            return
        }

        if isStoppingAfterExpiration {
            pendingBackgroundLease?.end(.coalesced)
            pendingBackgroundLease = incomingLease
            watchPipelineBackgroundLog.notice(
                "Queued replacement background lease token=\(incomingLease.token.uuidString, privacy: .public)"
            )
            return
        }

        if activeBackgroundLease?.isActive == true {
            incomingLease.end(.coalesced)
            return
        }

        activeBackgroundLease?.end(.coalesced)
        activeBackgroundLease = incomingLease
        watchPipelineBackgroundLog.notice(
            "Replaced inactive background lease token=\(incomingLease.token.uuidString, privacy: .public)"
        )
    }

    private func makeBackgroundLease(recordingID: String?) -> WatchRecordingBackgroundLease {
        WatchRecordingBackgroundLease.begin(
            recordingID: recordingID,
            service: backgroundTaskService
        ) { [weak self] token in
            self?.backgroundLeaseDidExpire(token)
        }
    }

    func retry(_ item: WatchRecordingInboxItem) {
        guard activeRecordingID != item.id,
              let latest = inbox.load().first(where: { $0.id == item.id }),
              latest.phase == .failed,
              !latest.requiresPresetSelection else { return }

        if var snapshot = latest.flowSnapshot,
           snapshot.watchOutputMode == .recordingOnly,
           let current = CapturePresetStore.flow(id: snapshot.id),
           current.watchOutputMode == .recordingOnly {
            // Once a filename is reserved, keep it bound to the frozen folder
            // snapshot so a retry can reconcile an already-finished copy.
            // Choosing another preset explicitly clears that reservation.
            if latest.reservedOutputFilename == nil {
                snapshot.watchRecordingSettings = current.watchRecordingSettings
            }
            _ = inbox.update(id: latest.id) { updated in
                updated.flowSnapshot = snapshot
                updated.flowSnapshotPayload = try? JSONEncoder().encode(snapshot)
                updated.phase = .queued
                updated.failureStage = nil
                updated.statusMessage = String(localized: "Queued to retry Files delivery")
            }
        } else {
            _ = inbox.transition(
                id: item.id,
                to: .queued,
                message: String(localized: "Queued to retry on iPhone")
            )
        }
        refresh()
        resume()
    }

    func captureRecordingWithoutTranscript(_ item: WatchRecordingInboxItem) {
        guard activeRecordingID != item.id,
              let latest = inbox.load().first(where: { $0.id == item.id }),
              latest.phase == .failed,
              latest.failureStage == .transcription,
              latest.flowSnapshot?.watchOutputMode != .recordingOnly,
              latest.hasAudio else { return }

        _ = inbox.update(id: latest.id) { updated in
            updated.capturesRecordingWithoutTranscript = true
            updated.phase = .queued
            updated.failureStage = nil
            updated.statusMessage = String(localized: "Queued to capture the recording without a transcript")
        }
        refresh()
        resume()
    }

    func choosePreset(_ preset: CapturePreset, for item: WatchRecordingInboxItem) {
        guard preset.isEnabled,
              activeRecordingID != item.id,
              let latest = inbox.load().first(where: { $0.id == item.id }),
              latest.phase == .failed || latest.phase == .queued else { return }
        let isRecordingOnlyRetarget = latest.phase == .failed
            && latest.flowSnapshot?.watchOutputMode == .recordingOnly
            && preset.watchOutputMode == .recordingOnly
        guard latest.requiresPresetSelection || isRecordingOnlyRetarget else { return }
        _ = inbox.update(id: item.id) { updated in
            updated.flowSnapshot = preset
            updated.flowSnapshotPayload = try? JSONEncoder().encode(preset)
            updated.requiresPresetSelection = false
            updated.reservedOutputFilename = nil
            updated.reservedOutputFolderBookmark = nil
            updated.phase = .queued
            updated.failureStage = nil
            updated.statusMessage = String(localized: "Recovered with \(preset.displayName); queued to retry")
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

            if latest.flowSnapshot?.watchOutputMode != .recordingOnly,
               let captureRootURL = AppConstants.captureDirectoryURL {
                let captureInbox = CaptureInbox(rootDirectoryURL: captureRootURL)
                let state: CaptureInboxState?
                do {
                    state = try await captureInbox.state(of: latest.requestID)
                } catch {
                    _ = self.inbox.transition(
                        id: latest.id,
                        to: latest.phase,
                        failureStage: latest.failureStage,
                        message: String(localized: "Could not verify Capture delivery. Try discarding again.")
                    )
                    self.refresh()
                    return
                }
                if state == .completed {
                    let message = latest.capturesRecordingWithoutTranscript
                        ? String(localized: "Recording captured without a transcript")
                        : String(localized: "Saved to Capture")
                    _ = self.inbox.markDelivered(id: latest.id, message: message)
                    self.refresh()
                    WatchRecordingController.shared.publishState()
                    return
                }
                if state == .processing {
                    _ = self.inbox.transition(
                        id: latest.id,
                        to: latest.phase,
                        failureStage: latest.failureStage,
                        message: String(localized: "Capture delivery is active. Wait a moment before discarding.")
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
        defer {
            let completedLease = activeBackgroundLease
            let replacementLease = pendingBackgroundLease
            activeBackgroundLease = nil
            pendingBackgroundLease = nil
            activeRecordingID = nil
            isProcessing = false
            processingTask = nil
            isStoppingAfterExpiration = false
            refresh()
            WatchRecordingController.shared.publishState()
            completedLease?.end(.completed)
            if let replacementLease {
                resume(backgroundLease: replacementLease)
            }
        }

        while !Task.isCancelled {
            refresh()
            let recorderIsBusy = recorder?.isSegmentActive == true || recorder?.isTranscribing == true
            let processableItems = items.filter {
                $0.phase == .queued && (!recorderIsBusy || canRunWhileRecorderIsBusy($0))
            }
            let item: WatchRecordingInboxItem?
            if usageTracker.isAtLimit {
                item = processableItems.first(where: canRunWithoutTranscriptionUsage)
                if item == nil {
                    markQueuedItemsWaitingForUnlock()
                    return
                }
            } else {
                item = processableItems.first
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
                if isRecordingOnly(item) {
                    notifyRecordingOnlyDeliveryFailure(recordingID: item.id)
                }
            } catch {
                _ = inbox.transition(
                    id: item.id,
                    to: .failed,
                    failureStage: .delivery,
                    message: error.localizedDescription
                )
                if isRecordingOnly(item) {
                    notifyRecordingOnlyDeliveryFailure(recordingID: item.id)
                }
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
                    ? String(localized: "Choose a Capture Preset for this recovered recording.")
                    : item.flowSnapshotPayload == nil
                        ? String(localized: "Choose a Capture Preset on iPhone, then retry.")
                        : String(localized: "Update Vox.md on iPhone to use this recording's Capture Preset.")
            )
        }
        if flow.watchOutputMode == .recordingOnly {
            try await deliverRecordingOnly(item, flow: flow)
            return
        }
        if item.capturesRecordingWithoutTranscript {
            try await deliverCaptureRecording(item, flow: flow)
            return
        }

        guard item.hasAudio || transcriptStore.transcripts.contains(where: { $0.id == item.requestID }) else {
            throw WatchRecordingPipelineError(
                stage: .storage,
                message: String(localized: "The Watch audio is missing. Record again on Apple Watch.")
            )
        }

        let transcript: Transcript
        if let existing = transcriptStore.transcripts.first(where: { $0.id == item.requestID }) {
            transcript = existing
        } else {
            _ = inbox.transition(
                id: item.id,
                to: .transcribing,
                message: String(localized: "Transcribing on iPhone")
            )
            refresh()
            WatchRecordingController.shared.publishState()

            let output = try await transcribe(item, flow: flow)
            try ensureProcessingIsActive(for: item.id)
            guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WatchRecordingPipelineError(
                    stage: .transcription,
                    message: String(localized: "No recognizable speech was found. The recording is kept for retry.")
                )
            }

            let raw = Transcript(
                id: item.requestID,
                text: output.text,
                date: item.createdAt,
                duration: item.duration ?? AudioFileConverter.duration(of: item.fileURL) ?? 0,
                modelUsed: output.result.backendName,
                language: output.result.language,
                speakerTurns: output.speakerTurns
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
                message: String(localized: "Shared Capture storage is unavailable.")
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
                message: String(localized: "Capture delivery is still in progress. Try again shortly.")
            )
        }

        guard let destinationID = await ConfiguredTranscriptCaptureDestinationExporter
            .resolvedDestinationID(flow: flow) else {
            throw WatchRecordingPipelineError(
                stage: .delivery,
                message: String(localized: "Set a destination for \(flow.displayName) on iPhone, then retry.")
            )
        }

        try ensureProcessingIsActive(for: item.id)
        do {
            _ = try await ConfiguredTranscriptCaptureDestinationExporter.export(
                transcript: latestTranscript,
                flow: flow,
                destinationID: destinationID,
                audioSourceURL: flow.audioSaveMode == .off ? nil : item.fileURL,
                source: .watch
            )
            try ensureProcessingIsActive(for: item.id)
            lastDeliveredRecordingID = item.id
            complete(item)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WatchRecordingPipelineError(
                stage: .delivery,
                message: String(localized: "Capture could not be delivered. The transcript and audio are saved for retry.")
            )
        }
    }

    private func deliverCaptureRecording(
        _ item: WatchRecordingInboxItem,
        flow: CapturePreset
    ) async throws {
        guard item.hasAudio else {
            throw WatchRecordingPipelineError(
                stage: .storage,
                message: String(localized: "The retained Apple Watch recording is missing.")
            )
        }

        _ = inbox.transition(
            id: item.id,
            to: .delivering,
            message: String(localized: "Capturing the recording without a transcript")
        )
        refresh()
        WatchRecordingController.shared.publishState()
        try ensureProcessingIsActive(for: item.id)

        guard let captureRootURL = AppConstants.captureDirectoryURL else {
            throw WatchRecordingPipelineError(
                stage: .storage,
                message: String(localized: "Shared Capture storage is unavailable.")
            )
        }
        let captureInbox = CaptureInbox(rootDirectoryURL: captureRootURL)
        _ = try? await captureInbox.recoverStaleProcessing(olderThan: 5 * 60)
        let existingState = try await captureInbox.state(of: item.requestID)
        if existingState == .completed {
            recordCompletedRecording(item)
            complete(item, message: String(localized: "Recording captured without a transcript"))
            return
        }
        if existingState == .failed {
            _ = try await captureInbox.retryFailed(requestID: item.requestID)
        }
        if existingState == .processing {
            throw WatchRecordingPipelineError(
                stage: .delivery,
                message: String(localized: "Capture delivery is still in progress. Try again shortly.")
            )
        }

        guard let destinationID = await ConfiguredTranscriptCaptureDestinationExporter
            .resolvedDestinationID(flow: flow) else {
            throw WatchRecordingPipelineError(
                stage: .delivery,
                message: String(localized: "Set a destination for \(flow.displayName) on iPhone, then retry.")
            )
        }

        try ensureProcessingIsActive(for: item.id)
        do {
            _ = try await ConfiguredTranscriptCaptureDestinationExporter.exportRecording(
                requestID: item.requestID,
                createdAt: item.createdAt,
                flow: flow,
                destinationID: destinationID,
                audioSourceURL: item.fileURL,
                preferredFilename: item.originalFilename ?? item.filename,
                source: .watch
            )
            try ensureProcessingIsActive(for: item.id)
            recordCompletedRecording(item)
            lastDeliveredRecordingID = item.id
            complete(item, message: String(localized: "Recording captured without a transcript"))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WatchRecordingPipelineError(
                stage: .delivery,
                message: error.localizedDescription
            )
        }
    }

    private func deliverRecordingOnly(
        _ item: WatchRecordingInboxItem,
        flow: CapturePreset
    ) async throws {
        guard item.hasAudio else {
            throw WatchRecordingPipelineError(
                stage: .storage,
                message: String(localized: "The retained Apple Watch recording is missing.")
            )
        }

        _ = inbox.transition(
            id: item.id,
            to: .delivering,
            message: String(localized: "Saving recording to Files")
        )
        refresh()
        WatchRecordingController.shared.publishState()
        try ensureProcessingIsActive(for: item.id)

        let exporter = RecordingOnlyFileExporter()
        let settings = flow.watchRecordingSettings
        let context = RecordingOnlyFileExportContext(
            recordingID: item.id,
            createdAt: item.createdAt,
            presetName: flow.displayName,
            originalFilename: item.originalFilename ?? item.filename
        )
        var reservation = item.reservedOutputFilename
        var reservationFolderBookmark = item.reservedOutputFolderBookmark
        if reservation != nil,
           let reservationFolderBookmark,
           reservationFolderBookmark != settings.folderBookmark {
            throw WatchRecordingPipelineError(
                stage: .storage,
                message: String(localized: "The reserved filename belongs to another Files folder. Choose a recording-only preset to retarget it explicitly.")
            )
        }

        for _ in 0..<3 {
            let reservedFilename: String
            let existingReservation = reservation
            do {
                let reservationTask = Task.detached(priority: .utility) {
                    try exporter.reserveFilename(
                        context: context,
                        settings: settings,
                        existingReservation: existingReservation
                    )
                }
                reservedFilename = try await withTaskCancellationHandler {
                    try await reservationTask.value
                } onCancel: {
                    reservationTask.cancel()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw recordingOnlyPipelineError(error)
            }
            try ensureProcessingIsActive(for: item.id)

            if reservation != reservedFilename
                || reservationFolderBookmark != settings.folderBookmark {
                guard inbox.update(id: item.id, { updated in
                    updated.reservedOutputFilename = reservedFilename
                    updated.reservedOutputFolderBookmark = settings.folderBookmark
                    updated.statusMessage = String(localized: "Saving \(reservedFilename) to Files")
                }) != nil else {
                    throw WatchRecordingPipelineError(
                        stage: .storage,
                        message: String(localized: "The recording filename could not be saved for retry.")
                    )
                }
                reservation = reservedFilename
                reservationFolderBookmark = settings.folderBookmark
            }

            do {
                let copyTask = Task.detached(priority: .utility) {
                    try exporter.copy(
                        sourceURL: item.fileURL,
                        reservedFilename: reservedFilename,
                        settings: settings
                    )
                }
                let receipt = try await withTaskCancellationHandler {
                    try await copyTask.value
                } onCancel: {
                    copyTask.cancel()
                }
                watchPipelineBackgroundLog.notice(
                    "Files delivery verified recording=\(item.id, privacy: .public) reconciled=\(receipt.wasAlreadyDelivered, privacy: .public)"
                )
                try ensureProcessingIsActive(for: item.id)
                guard inbox.markDelivered(
                    id: item.id,
                    message: String(localized: "Saved \(receipt.filename) to Files")
                ) != nil else {
                    throw WatchRecordingPipelineError(
                        stage: .storage,
                        message: String(localized: "The Files copy succeeded, but delivery state could not be saved. Retry is safe.")
                    )
                }
                recordCompletedRecording(item)
                lastDeliveredRecordingID = item.id
                refresh()
                WatchRecordingController.shared.publishState()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch RecordingOnlyFileExportError.filenameConflict {
                guard inbox.update(id: item.id, { updated in
                    updated.reservedOutputFilename = nil
                    updated.reservedOutputFolderBookmark = nil
                    updated.statusMessage = String(localized: "Choosing another Files filename")
                }) != nil else {
                    throw WatchRecordingPipelineError(
                        stage: .storage,
                        message: String(localized: "The recording filename conflict could not be saved for retry.")
                    )
                }
                reservation = nil
                reservationFolderBookmark = nil
            } catch {
                throw recordingOnlyPipelineError(error)
            }
        }

        throw WatchRecordingPipelineError(
            stage: .delivery,
            message: RecordingOnlyFileExportError.filenameConflict.localizedDescription
        )
    }

    private func recordCompletedRecording(_ item: WatchRecordingInboxItem) {
        guard let statsURL = AppConstants.activityStatsURL else { return }
        let duration = item.duration ?? AudioFileConverter.duration(of: item.fileURL) ?? 0
        _ = try? ActivityStatsStore(fileURL: statsURL).record(RecordingActivityEvent(
            id: item.requestID,
            date: item.createdAt,
            duration: duration
        ))
    }

    private func recordingOnlyPipelineError(_ error: Error) -> WatchRecordingPipelineError {
        return WatchRecordingPipelineError(
            stage: .delivery,
            message: error.localizedDescription
        )
    }

    private func transcribe(
        _ item: WatchRecordingInboxItem,
        flow: CapturePreset
    ) async throws -> WatchTranscriptionOutput {
        let sourceURL = item.fileURL
        let workingURL = (AppConstants.recordingsDirectoryURL ?? WatchRecordingInbox.inboxDirectory)
            .appendingPathComponent("watch-transcription-\(item.requestID.uuidString.lowercased())")
            .appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: workingURL)
        defer { try? FileManager.default.removeItem(at: workingURL) }

        let convertedURL: URL
        do {
            let conversionTask = Task.detached(priority: .userInitiated) {
                try AudioFileConverter.convertToWhisperWAV(
                    inputURL: sourceURL,
                    outputURL: workingURL
                )
            }
            convertedURL = try await withTaskCancellationHandler {
                try await conversionTask.value
            } onCancel: {
                conversionTask.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            watchPipelineBackgroundLog.error(
                "Watch audio preparation failed recording=\(item.id, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            throw WatchRecordingPipelineError(
                stage: .transcription,
                message: WatchRecordingTranscriptionFailureMessage.audioPreparation(for: error)
            )
        }

        try Task.checkCancellation()
        let modelID = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedModelKey)
            ?? AppConstants.defaultTranscriptionBackendID
        let language = AppConstants.sharedDefaults?.string(forKey: AppConstants.selectedLanguageKey)
            ?? "auto"
        do {
            let result = try await transcriptionService.transcribeResult(
                audioURL: convertedURL,
                modelID: modelID,
                fallbackModelID: AppConstants.sharedDefaults?.string(
                    forKey: AppConstants.selectedFallbackModelKey
                ),
                language: language
            )
            try Task.checkCancellation()

            guard flow.speakerDiarizationEnabled else {
                return WatchTranscriptionOutput(
                    result: result,
                    text: result.text,
                    speakerTurns: nil
                )
            }
            do {
                let diarization = try await speakerDiarizationService.diarize(
                    audioURL: convertedURL,
                    transcriptText: result.text,
                    transcriptionSegments: result.segments
                )
                return WatchTranscriptionOutput(
                    result: result,
                    text: diarization.renderedText,
                    speakerTurns: diarization.turns
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                watchPipelineBackgroundLog.warning(
                    "Watch speaker identification skipped recording=\(item.id, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                )
                return WatchTranscriptionOutput(
                    result: result,
                    text: result.text,
                    speakerTurns: nil
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            watchPipelineBackgroundLog.error(
                "Watch transcription failed recording=\(item.id, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            throw WatchRecordingPipelineError(
                stage: .transcription,
                message: WatchRecordingTranscriptionFailureMessage.recognition(for: error)
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

    private func complete(
        _ item: WatchRecordingInboxItem,
        message: String = String(localized: "Saved to Capture")
    ) {
        _ = inbox.markDelivered(id: item.id, message: message)
        refresh()
        WatchRecordingController.shared.publishState()
    }

    private func recoverInterruptedItems() {
        let interruptedItems = items.filter {
            $0.phase == .transcribing || $0.phase == .delivering
        }
        if !interruptedItems.isEmpty {
            watchPipelineBackgroundLog.notice(
                "Recovering interrupted Watch deliveries count=\(interruptedItems.count, privacy: .public)"
            )
        }
        for item in interruptedItems {
            let message: String
            if isRecordingOnly(item) {
                message = String(localized: "Resuming Files delivery")
            } else if item.capturesRecordingWithoutTranscript {
                message = String(localized: "Resuming recording capture")
            } else if transcriptStore.transcripts.contains(where: { $0.id == item.requestID }) {
                message = String(localized: "Resuming Capture delivery")
            } else {
                message = String(localized: "Resuming Watch transcription")
            }
            _ = inbox.transition(id: item.id, to: .queued, message: message)
        }
        refresh()
    }

    private func reconcileDeliveredCaptureRequests() {
        guard let captureRootURL = AppConstants.captureDirectoryURL else { return }
        let candidates = items.filter {
            ($0.phase == .failed || $0.phase == .delivering) && !isRecordingOnly($0)
        }
        guard !candidates.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let captureInbox = CaptureInbox(rootDirectoryURL: captureRootURL)
            for item in candidates {
                if (try? await captureInbox.state(of: item.requestID)) == .completed {
                    let message = item.capturesRecordingWithoutTranscript
                        ? String(localized: "Recording captured without a transcript")
                        : String(localized: "Saved to Capture")
                    self.complete(item, message: message)
                }
            }
        }
    }

    private func isDeliveryOnlyRetry(_ item: WatchRecordingInboxItem) -> Bool {
        item.phase == .queued
            && transcriptStore.transcripts.contains(where: { $0.id == item.requestID })
    }

    private func isRecordingOnly(_ item: WatchRecordingInboxItem) -> Bool {
        item.flowSnapshot?.watchOutputMode == .recordingOnly
    }

    private func canRunWhileRecorderIsBusy(_ item: WatchRecordingInboxItem) -> Bool {
        isRecordingOnly(item) || item.capturesRecordingWithoutTranscript
    }

    private func canRunWithoutTranscriptionUsage(_ item: WatchRecordingInboxItem) -> Bool {
        (item.phase == .queued
            && (isRecordingOnly(item) || item.capturesRecordingWithoutTranscript))
            || isDeliveryOnlyRetry(item)
    }

    private func markQueuedItemsWaitingForUnlock() {
        for item in items where item.phase == .queued
            && !isRecordingOnly(item)
            && !item.capturesRecordingWithoutTranscript
            && !isDeliveryOnlyRetry(item)
            && item.statusMessage != WatchRecordingStatusMessage.transcriptionLimitReached {
            _ = inbox.transition(
                id: item.id,
                to: .queued,
                message: WatchRecordingStatusMessage.transcriptionLimitReached
            )
        }
        refresh()
        WatchRecordingController.shared.publishState()
    }

    private func notifyRecordingOnlyDeliveryFailure(recordingID: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                    || settings.authorizationStatus == .ephemeral else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Watch recording needs attention")
            // Folder names and provider errors can be sensitive. Keep lock-screen
            // previews generic; the authenticated in-app queue retains details.
            content.body = String(localized: "Open Vox.md to review a Watch recording delivery problem.")
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "watch-recording-files-failed-\(recordingID)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}

enum WatchRecordingTranscriptionFailureMessage {
    private static var retainedRecording: String {
        String(localized: "The Watch recording is saved for retry.")
    }

    static func audioPreparation(for error: Error) -> String {
        let reason: String
        switch error as? AudioFileConverter.ConversionError {
        case .couldNotOpenInput:
            reason = String(localized: "Transcription failed because the Watch audio file could not be opened.")
        case .noAudioSamples:
            reason = String(localized: "Transcription failed because the Watch recording contains no readable audio.")
        case .couldNotCreateFormat, .couldNotCreateConverter, .couldNotCreateBuffer:
            reason = String(localized: "Transcription failed because the Watch audio could not be converted to the required format.")
        case nil:
            reason = String(localized: "Transcription failed because the Watch audio could not be prepared for speech recognition.")
        }
        return "\(reason) \(retainedRecording)"
    }

    static func recognition(for error: Error) -> String {
        if let transcriptionError = error as? OnDeviceTranscriptionError,
           transcriptionError == .noSpeechDetected {
            return String(localized: "No recognizable speech was found. \(retainedRecording)")
        }

        let rawReason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = rawReason.isEmpty
            ? String(localized: "The transcription service did not provide a reason.")
            : sentence(from: rawReason)
        return String(localized: "Transcription failed: \(reason) \(retainedRecording)")
    }

    private static func sentence(from text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return "\(text)."
    }
}

private struct WatchRecordingPipelineError: Error, LocalizedError {
    let stage: WatchRecordingFailureStage
    let message: String

    var errorDescription: String? { message }
}
