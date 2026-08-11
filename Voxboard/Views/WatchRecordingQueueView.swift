import SwiftUI
import VoxboardShared

struct WatchRecordingQueueView: View {
    @Bindable var pipeline: WatchRecordingPipeline
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDiscard: WatchRecordingInboxItem?
    @State private var showsPaywall = false

    var body: some View {
        NavigationStack {
            Group {
                if visibleItems.isEmpty {
                    ContentUnavailableView(
                        "No Watch Recordings",
                        systemImage: "applewatch",
                        description: Text("Record on Apple Watch and it will appear here automatically.")
                    )
                } else {
                    List(visibleItems) { item in
                        recordingRow(item)
                            .listRowBackground(Geist.Palette.background200)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable {
                        pipeline.refresh()
                        pipeline.resume()
                    }
                }
            }
            .background(Geist.Palette.background200)
            .navigationTitle("Watch Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showsPaywall) {
                PaywallView(context: .limit)
            }
            .confirmationDialog(
                "Discard this Watch recording?",
                isPresented: discardConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Discard Recording", role: .destructive) {
                    guard let pendingDiscard else { return }
                    pipeline.discard(pendingDiscard)
                    self.pendingDiscard = nil
                }
                Button("Cancel", role: .cancel) { pendingDiscard = nil }
            } message: {
                Text("This removes the retained audio and any capture that is still queued for delivery.")
            }
        }
    }

    private var visibleItems: [WatchRecordingInboxItem] {
        pipeline.items
            .filter { item in
                item.phase != .discarded
                    && !(item.phase.isTerminal && item.acknowledgedAt != nil)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var discardConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDiscard != nil },
            set: { if !$0 { pendingDiscard = nil } }
        )
    }

    private func recordingRow(_ item: WatchRecordingInboxItem) -> some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            HStack(alignment: .top, spacing: Geist.Spacing.three) {
                Image(systemName: item.watchStatusSymbol)
                    .foregroundStyle(item.phase == .failed ? Geist.error : Geist.text)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                    Text(item.watchStatusTitle)
                        .font(Geist.heading(.headline))
                        .foregroundStyle(Geist.text)
                    Text(item.createdAt, style: .relative)
                        .font(Geist.mono())
                        .foregroundStyle(Geist.muted)
                    Text(item.watchStatusSubtitle)
                        .font(Geist.caption())
                        .foregroundStyle(item.phase == .failed ? Geist.error : Geist.muted)
                }

                Spacer()
                if item.phase == .transcribing || item.phase == .delivering {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: Geist.Spacing.two) {
                Label(item.displayPresetName, systemImage: "waveform.circle")
                if let duration = item.duration {
                    Label(formatDuration(duration), systemImage: "timer")
                }
            }
            .font(Geist.caption(.caption2))
            .foregroundStyle(Geist.faint)

            if item.phase == .failed {
                HStack(spacing: Geist.Spacing.two) {
                    if item.requiresPresetSelection {
                        Menu("Choose Preset") {
                            ForEach(
                                CapturePresetStore.loadFlows().filter(\.isEnabled),
                                id: \.id
                            ) { preset in
                                Button(preset.displayName) {
                                    pipeline.choosePreset(preset, for: item)
                                }
                            }
                        }
                        .buttonStyle(GeistButtonStyle(variant: .primary, size: .small))
                    } else {
                        Button("Retry") { pipeline.retry(item) }
                            .buttonStyle(GeistButtonStyle(variant: .primary, size: .small))
                        if item.flowSnapshot?.watchOutputMode == .recordingOnly {
                            Menu("Change Preset") {
                                ForEach(
                                    CapturePresetStore.loadFlows().filter {
                                        $0.isEnabled && $0.watchOutputMode == .recordingOnly
                                    },
                                    id: \.id
                                ) { preset in
                                    Button(preset.displayName) {
                                        pipeline.choosePreset(preset, for: item)
                                    }
                                }
                            }
                            .buttonStyle(GeistButtonStyle(variant: .secondary, size: .small))
                        }
                    }
                    Button("Discard", role: .destructive) { pendingDiscard = item }
                        .buttonStyle(GeistButtonStyle(variant: .secondary, size: .small))
                }

                if item.canCaptureRecordingWithoutTranscript {
                    Button {
                        pipeline.captureRecordingWithoutTranscript(item)
                    } label: {
                        Label("Capture Recording Without Transcript", systemImage: "waveform")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GeistButtonStyle(variant: .secondary, size: .small))
                    .accessibilityHint("Saves the retained audio to Capture without transcription")
                }
            } else if item.phase == .queued {
                HStack(spacing: Geist.Spacing.two) {
                    if item.isWaitingForTranscriptionUpgrade {
                        Button("Get Unlimited") { showsPaywall = true }
                            .buttonStyle(GeistButtonStyle(variant: .primary, size: .small))
                    }
                    Button("Discard", role: .destructive) { pendingDiscard = item }
                        .buttonStyle(GeistButtonStyle(variant: .secondary, size: .small))
                }
            }
        }
        .padding(.vertical, Geist.Spacing.two)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

extension WatchRecordingInboxItem {
    var isWaitingForTranscriptionUpgrade: Bool {
        phase == .queued
            && statusMessage == WatchRecordingStatusMessage.transcriptionLimitReached
    }

    var watchStatusTitle: String {
        switch phase {
        case .queued:
            return String(localized: "Received from Apple Watch")
        case .transcribing:
            return String(localized: "Transcribing Watch recording")
        case .delivering:
            return isRecordingOnlyWatchOutput
                ? String(localized: "Saving recording to Files")
                : String(localized: "Saving to Capture")
        case .delivered:
            return isRecordingOnlyWatchOutput
                ? String(localized: "Watch recording saved to Files")
                : String(localized: "Watch recording saved")
        case .failed:
            return String(localized: "Watch recording needs attention")
        case .discarded:
            return String(localized: "Watch recording discarded")
        }
    }

    var watchStatusSubtitle: String {
        if let statusMessage, !statusMessage.isEmpty {
            return statusMessage
        }
        switch phase {
        case .queued:
            return String(localized: "Queued on iPhone with \(displayPresetName)")
        case .transcribing:
            return String(localized: "On-device transcription is running")
        case .delivering:
            return isRecordingOnlyWatchOutput
                ? String(localized: "Copying the retained M4A to the selected Files folder")
                : String(localized: "Writing through the Capture pipeline")
        case .delivered:
            return isRecordingOnlyWatchOutput
                ? String(localized: "Saved as a user-visible M4A file")
                : String(localized: "Delivered with \(displayPresetName)")
        case .failed:
            return isRecordingOnlyWatchOutput
                ? String(localized: "The M4A is retained safely for Files retry")
                : String(localized: "The audio and transcript are retained for retry")
        case .discarded:
            return String(localized: "Removed")
        }
    }

    var canCaptureRecordingWithoutTranscript: Bool {
        phase == .failed
            && failureStage == .transcription
            && !isRecordingOnlyWatchOutput
            && hasAudio
    }

    private var isRecordingOnlyWatchOutput: Bool {
        flowSnapshot?.watchOutputMode == .recordingOnly
    }

    var watchStatusSymbol: String {
        switch phase {
        case .queued:
            return "applewatch.radiowaves.left.and.right"
        case .transcribing:
            return "waveform.badge.magnifyingglass"
        case .delivering:
            return isRecordingOnlyWatchOutput ? "folder.badge.plus" : "arrow.up.doc"
        case .delivered:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .discarded:
            return "trash"
        }
    }
}
