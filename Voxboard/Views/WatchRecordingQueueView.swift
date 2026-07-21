import SwiftUI
import VoxboardShared

struct WatchRecordingQueueView: View {
    @Bindable var pipeline: WatchRecordingPipeline
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDiscard: WatchRecordingInboxItem?

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
                    }
                    Button("Discard", role: .destructive) { pendingDiscard = item }
                        .buttonStyle(GeistButtonStyle(variant: .secondary, size: .small))
                }
            } else if item.phase == .queued {
                Button("Discard", role: .destructive) { pendingDiscard = item }
                    .buttonStyle(GeistButtonStyle(variant: .secondary, size: .small))
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
    var watchStatusTitle: String {
        switch phase {
        case .queued:
            return "Received from Apple Watch"
        case .transcribing:
            return "Transcribing Watch recording"
        case .delivering:
            return "Saving to Capture"
        case .delivered:
            return "Watch recording saved"
        case .failed:
            return "Watch recording needs attention"
        case .discarded:
            return "Watch recording discarded"
        }
    }

    var watchStatusSubtitle: String {
        if let statusMessage, !statusMessage.isEmpty {
            return statusMessage
        }
        switch phase {
        case .queued:
            return "Queued on iPhone with \(displayPresetName)"
        case .transcribing:
            return "On-device transcription is running"
        case .delivering:
            return "Writing through the Capture pipeline"
        case .delivered:
            return "Delivered with \(displayPresetName)"
        case .failed:
            return "The audio and transcript are retained for retry"
        case .discarded:
            return "Removed"
        }
    }

    var watchStatusSymbol: String {
        switch phase {
        case .queued:
            return "applewatch.radiowaves.left.and.right"
        case .transcribing:
            return "waveform.badge.magnifyingglass"
        case .delivering:
            return "arrow.up.doc"
        case .delivered:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .discarded:
            return "trash"
        }
    }
}
