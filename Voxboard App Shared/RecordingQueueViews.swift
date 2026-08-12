import SwiftUI
import VoxboardShared

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct RecordingQueuePreferencesView: View {
    @State private var retentionMode: SourceAudioRetentionMode
    @State private var timedRetentionDays: Int
    @State private var processingPolicy: RecordingJobProcessingPolicy

    init() {
        let configuration = RecordingQueuePreferences.load()
        _retentionMode = State(initialValue: configuration.sourceAudioRetention.mode)
        let interval = configuration.sourceAudioRetention.retentionInterval
            ?? SourceAudioRetentionPolicy.defaultTimedRetention
        _timedRetentionDays = State(initialValue: max(1, Int((interval / 86_400).rounded())))
        _processingPolicy = State(initialValue: configuration.processingPolicy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("After recording")
                    .font(.headline)
                Picker("After recording", selection: $processingPolicy) {
                    Text("Process immediately").tag(RecordingJobProcessingPolicy.immediate)
                    Text("Process when Vox.md is idle").tag(RecordingJobProcessingPolicy.whenIdle)
                    Text("Process manually").tag(RecordingJobProcessingPolicy.manual)
                }
                .labelsHidden()
                Text(processingDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Original audio")
                    .font(.headline)
                Picker("Original audio", selection: $retentionMode) {
                    Text("Delete after successful processing").tag(SourceAudioRetentionMode.deleteAfterSuccess)
                    Text("Keep for a period").tag(SourceAudioRetentionMode.timed)
                    Text("Keep permanently").tag(SourceAudioRetentionMode.permanent)
                }
                .labelsHidden()

                if retentionMode == .timed {
                    Stepper(value: $timedRetentionDays, in: 1...365) {
                        Text("Keep for \(timedRetentionDays) day\(timedRetentionDays == 1 ? "" : "s")")
                    }
                }

                Text("Failed or interrupted recordings are always preserved until you retry or delete them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: retentionMode) { _, _ in save() }
        .onChange(of: timedRetentionDays) { _, _ in save() }
        .onChange(of: processingPolicy) { _, _ in save() }
    }

    private var processingDetail: String {
        switch processingPolicy {
        case .immediate:
            return String(localized: "Recordings enter the durable queue and start as soon as the microphone is free.")
        case .whenIdle:
            #if os(macOS)
            return String(localized: "Queued recordings run while Vox.md is open and no recording is active.")
            #else
            return String(localized: "Queued recordings run when Vox.md is active and idle. iOS background execution is not guaranteed.")
            #endif
        case .manual:
            return String(localized: "Recordings remain queued until you choose Process Now.")
        }
    }

    private func save() {
        let retention: SourceAudioRetentionPolicy
        switch retentionMode {
        case .deleteAfterSuccess:
            retention = .deleteAfterSuccess
        case .timed:
            retention = .timed(TimeInterval(timedRetentionDays) * 86_400)
        case .permanent:
            retention = .permanent
        }
        RecordingQueuePreferences.save(RecordingQueueConfiguration(
            sourceAudioRetention: retention,
            processingPolicy: processingPolicy
        ))
    }
}

@MainActor
private final class RecordingQueueRetryCoordinator: @unchecked Sendable {
    let action: (RecordingJob, RecordingJobDelivery?) async -> Void

    init(action: @escaping (RecordingJob, RecordingJobDelivery?) async -> Void) {
        self.action = action
    }

    func retry(
        _ job: RecordingJob,
        delivery: RecordingJobDelivery? = nil
    ) async {
        await action(job, delivery)
    }
}

struct RecordingQueueView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var queue: RecordingJobQueue
    #if DEBUG
    @State private var runtimeValidationStatus: String?
    #endif
    private let retryCoordinator: RecordingQueueRetryCoordinator?
    private let recoveryPresets: [CapturePreset]

    init(
        queue: RecordingJobQueue,
        recoveryPresets: [CapturePreset] = [],
        retryOverride: (@MainActor (RecordingJob, RecordingJobDelivery?) async -> Void)? = nil
    ) {
        self.queue = queue
        self.recoveryPresets = recoveryPresets.filter(\.isEnabled)
        self.retryCoordinator = retryOverride.map(RecordingQueueRetryCoordinator.init(action:))
    }

    var body: some View {
        Group {
            if queue.actionableJobs.isEmpty {
                ContentUnavailableView(
                    "No Recordings in Queue",
                    systemImage: "waveform.badge.checkmark",
                    description: Text("New recordings are staged here before transcription so they can recover after interruption.")
                )
            } else {
                List {
                    ForEach(queue.actionableJobs) { job in
                        RecordingQueueRow(
                            job: job,
                            queue: queue,
                            retryCoordinator: retryCoordinator,
                            recoveryPresets: recoveryPresets
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Recording Queue")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
        #endif
        .toolbar {
            if !queue.retryAllEligibleJobs.isEmpty {
                ToolbarItem {
                    Button("Retry All", systemImage: "arrow.clockwise") {
                        Task { await retryAllFailedJobs() }
                    }
                }
            }
        }
        .task {
            await queue.refresh(recoverInterrupted: true)
        }
        .task {
            await queue.monitorDurableChanges()
        }
        .refreshable {
            await queue.refresh(recoverInterrupted: true)
        }
        #if DEBUG
        .task {
            let processInfo = ProcessInfo.processInfo
            guard processInfo.arguments.contains("--runtime-queue-validation"),
                  processInfo.arguments.contains("--runtime-queue-activate-actions"),
                  let overridePath = processInfo.environment[
                    AppConstants.debugSharedContainerOverrideEnvironmentKey
                  ],
                  !overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let overrideURL = Optional(
                    URL(fileURLWithPath: overridePath, isDirectory: true)
                        .standardizedFileURL
                  ),
                  overrideURL.path.hasPrefix(
                    URL(
                        fileURLWithPath: "/tmp/VoxQueueRuntimeValidation",
                        isDirectory: true
                    ).standardizedFileURL.path + "/"
                  ),
                  AppConstants.sharedContainerURL?.standardizedFileURL.path
                    == overrideURL.path else { return }
            runtimeValidationStatus = await activateRuntimeValidationActions(
                includeExtendedActions: processInfo.arguments.contains(
                    "--runtime-queue-activate-extended-actions"
                )
            )
        }
        .accessibilityIdentifier("recording-queue-runtime-actions")
        .accessibilityLabel(runtimeValidationStatus ?? "Runtime queue actions pending")
        #endif
        .alert("Recording Queue Error", isPresented: errorPresented) {
            Button("OK") {}
        } message: {
            Text(queue.lastError ?? String(localized: "Unknown error"))
        }
    }

    #if DEBUG
    private func activateRuntimeValidationActions(
        includeExtendedActions: Bool
    ) async -> String {
        if includeExtendedActions {
            return await activateExtendedRuntimeValidationActions()
        }
        for _ in 0..<100 {
            await queue.refresh(clearExistingError: false)
            let hasFailed = queue.actionableJobs.contains {
                $0.phase == .failed && $0.delivery != .recovery
                    && (!includeExtendedActions
                        || $0.originalFilename == "runtime-primary-failed.wav")
            }
            let hasQueued = queue.actionableJobs.contains {
                $0.phase == .queued
                    && (!includeExtendedActions
                        || $0.originalFilename == "runtime-primary-queued.wav")
            }
            let hasCopy = queue.actionableJobs.contains {
                $0.phase == .completed && $0.transcriptText != nil
                    && (!includeExtendedActions
                        || $0.originalFilename == "runtime-primary-copy.wav")
            }
            if hasFailed && hasQueued && hasCopy { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let failed = queue.actionableJobs.first(where: {
            $0.phase == .failed && $0.delivery != .recovery
                && (!includeExtendedActions
                    || $0.originalFilename == "runtime-primary-failed.wav")
        }),
        let queued = queue.actionableJobs.first(where: {
            $0.phase == .queued
                && (!includeExtendedActions
                    || $0.originalFilename == "runtime-primary-queued.wav")
        }),
        let copyReady = queue.actionableJobs.first(where: {
            $0.phase == .completed && $0.transcriptText != nil
                && (!includeExtendedActions
                    || $0.originalFilename == "runtime-primary-copy.wav")
        }) else {
            return "Runtime queue action fixtures missing"
        }

        queue.clearError()
        queue.setCaptureActive(true)
        await queue.retry(failed)
        guard queue.lastError == nil else { return "Retry failed" }
        await queue.processNow(queued)
        guard queue.lastError == nil else { return "Process Now failed" }
        let processedQueuedID = queued.id
        await queue.updateRetention(queued, policy: .permanent)
        guard queue.lastError == nil else { return "Retention failed" }
        await queue.acknowledgeCopiedResult(copyReady)
        guard queue.lastError == nil else { return "Copy acknowledgement failed" }
        let currentQueued = queue.jobs.first(where: { $0.id == queued.id }) ?? queued
        await queue.discard(currentQueued)
        guard queue.lastError == nil else { return "Delete failed" }

        return "Runtime queue actions passed \(processedQueuedID.uuidString.lowercased()) \(failed.id.uuidString.lowercased())"
    }

    private func activateExtendedRuntimeValidationActions() async -> String {
        for _ in 0..<100 {
            await queue.refresh(clearExistingError: false)
            let failedCount = queue.actionableJobs.filter { $0.phase == .failed }.count
            let queuedCount = queue.actionableJobs.filter { $0.phase == .queued }.count
            if failedCount >= 3 && queuedCount >= 1 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        queue.clearError()
        queue.setCaptureActive(true)
        let retryFilenames = Set([
            "runtime-retry-one.wav",
            "runtime-retry-two.wav",
        ])
        let retryAllJobs = queue.retryAllEligibleJobs.filter {
            $0.originalFilename.map(retryFilenames.contains) == true
        }
        guard retryAllJobs.count == retryFilenames.count,
              let timed = queue.jobs.first(where: {
                  $0.originalFilename == "runtime-timed.wav"
              }) else {
            return "Runtime Retry All fixtures missing"
        }
        let retryAllIDs = retryAllJobs.map(\.id)
        for job in retryAllJobs {
            if let retryCoordinator {
                await retryCoordinator.retry(job)
            } else {
                await queue.retry(job)
            }
        }
        guard queue.lastError == nil else { return "Retry All failed" }
        let retryAllSucceeded = retryAllIDs.allSatisfy { id in
            queue.jobs.first(where: { $0.id == id }).map {
                $0.phase == .queued && $0.processingPolicy == .immediate
            } ?? false
        }
        guard retryAllSucceeded else { return "Retry All state failed" }

        guard let deleteAfterSuccess = queue.jobs.first(where: {
            $0.originalFilename == "runtime-delete-after.wav"
        }) else {
            return "Runtime retention fixtures missing"
        }
        await queue.updateRetention(
            timed,
            policy: .timed(SourceAudioRetentionPolicy.defaultTimedRetention)
        )
        await queue.updateRetention(
            deleteAfterSuccess,
            policy: .deleteAfterSuccess
        )
        guard queue.lastError == nil else { return "Extended retention failed" }
        let timedSucceeded = queue.jobs.first(where: { $0.id == timed.id })?
            .retentionPolicy.mode == .timed
        let deleteAfterSucceeded = queue.jobs.first(where: {
            $0.id == deleteAfterSuccess.id
        })?.retentionPolicy.mode == .deleteAfterSuccess
        guard timedSucceeded, deleteAfterSucceeded else {
            return "Extended retention state failed"
        }
        return "Runtime extended queue actions passed \(retryAllIDs.map { $0.uuidString.lowercased() }.joined(separator: ",")) retention \(timed.id.uuidString.lowercased()),\(deleteAfterSuccess.id.uuidString.lowercased())"
    }
    #endif

    private func retryAllFailedJobs() async {
        for job in queue.retryAllEligibleJobs {
            if let retryCoordinator {
                await retryCoordinator.retry(job)
            } else {
                await queue.retry(job)
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { queue.lastError != nil },
            set: { presented in
                if !presented { queue.clearError() }
            }
        )
    }
}

private struct RecordingQueueRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let job: RecordingJob
    @Bindable var queue: RecordingJobQueue
    let retryCoordinator: RecordingQueueRetryCoordinator?
    let recoveryPresets: [CapturePreset]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Label(title, systemImage: symbolName)
                        .font(.headline)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Label(title, systemImage: symbolName)
                        .font(.headline)
                    Spacer()
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }

            Text("\(job.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(formattedDuration(job.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = job.statusMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(job.phase == .failed ? .red : .secondary)
            }

            if queue.activeJobID == job.id,
               let progress = queue.transcriptionProgress,
               let fraction = progress.exactFractionCompleted {
                ProgressView(value: fraction)
            }

            actionArea
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var actionArea: some View {
        #if os(macOS)
        HStack(spacing: 12) {
            applicableActions
            Spacer()
            deleteAction
        }
        #else
        LazyVGrid(
            columns: compactActionColumns,
            alignment: .leading,
            spacing: 10
        ) {
            applicableActions
            deleteAction
        }
        #endif
    }

    #if !os(macOS)
    private var compactActionColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [GridItem(.adaptive(minimum: 135), spacing: 12)]
    }
    #endif

    @ViewBuilder
    private var applicableActions: some View {
        primaryAction

        if let text = job.transcriptText, !text.isEmpty {
            Button("Copy", systemImage: "doc.on.doc") {
                if copy(text) {
                    Task { await queue.acknowledgeCopiedResult(job) }
                }
            }
        }

        if let audioURL = queue.audioURL(for: job) {
            audioAction(audioURL)
        }

        Menu("Keep Audio", systemImage: "externaldrive") {
            Button("Delete after success") {
                Task { await queue.updateRetention(job, policy: .deleteAfterSuccess) }
            }
            Button("Use timed retention") {
                let configured = RecordingQueuePreferences.load().sourceAudioRetention
                let interval = configured.mode == .timed
                    ? configured.retentionInterval ?? SourceAudioRetentionPolicy.defaultTimedRetention
                    : SourceAudioRetentionPolicy.defaultTimedRetention
                Task { await queue.updateRetention(job, policy: .timed(interval)) }
            }
            Button("Keep permanently") {
                Task { await queue.updateRetention(job, policy: .permanent) }
            }
        }
    }

    @ViewBuilder
    private var deleteAction: some View {
        if job.phase != .processing && job.phase != .finalizing {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await queue.discard(job) }
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch job.phase {
        case .queued:
            Button("Process Now", systemImage: "play.fill") {
                Task { await queue.processNow(job) }
            }
        case .failed where job.delivery == .recovery:
            Menu("Choose Preset", systemImage: "arrow.triangle.branch") {
                if recoveryPresets.isEmpty {
                    Text("No enabled Capture Presets")
                } else {
                    ForEach(recoveryPresets) { preset in
                        Button(preset.displayName) {
                            Task {
                                if let retryCoordinator {
                                    await retryCoordinator.retry(
                                        job,
                                        delivery: .preset(preset)
                                    )
                                } else {
                                    await queue.retry(
                                        job,
                                        delivery: .preset(preset)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        case .failed:
            Button("Retry", systemImage: "arrow.clockwise") {
                Task {
                    if let retryCoordinator {
                        await retryCoordinator.retry(job)
                    } else {
                        await queue.retry(job)
                    }
                }
            }
        case .completed where job.transcriptText != nil:
            EmptyView()
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func audioAction(_ url: URL) -> some View {
        #if os(macOS)
        Button("Reveal", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        #else
        ShareLink(item: url) {
            Label("Share Audio", systemImage: "square.and.arrow.up")
        }
        #endif
    }

    private var title: String {
        switch job.delivery {
        case .preset(let preset):
            return preset.displayName
        case .captureDraft:
            return String(localized: "Capture Draft Recording")
        case .clipboard:
            return String(localized: "Clipboard Transcription")
        case .keyboard:
            return String(localized: "Keyboard Transcription")
        case .recovery:
            return String(localized: "Recovered Recording")
        }
    }

    private var symbolName: String {
        switch job.phase {
        case .queued: return "clock"
        case .processing, .finalizing: return "waveform"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .discarded: return "trash"
        }
    }

    private var status: String {
        if job.phase == .completed, job.transcriptText != nil {
            return String(localized: "Ready to copy")
        }
        switch job.phase {
        case .queued: return String(localized: "Queued")
        case .processing: return String(localized: "Transcribing")
        case .finalizing: return String(localized: "Saving")
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Needs attention")
        case .discarded: return String(localized: "Discarded")
        }
    }

    private var statusColor: Color {
        job.phase == .failed ? .red : .secondary
    }

    @discardableResult
    private func copy(_ text: String) -> Bool {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        return UIPasteboard.general.string == text
        #endif
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
