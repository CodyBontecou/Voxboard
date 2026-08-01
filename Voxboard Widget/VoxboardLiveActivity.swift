import ActivityKit
import AppIntents
import SwiftUI
import VoxboardShared
import WidgetKit

@available(iOS 17.0, *)
struct VoxboardLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoxboardActivityAttributes.self) { context in
            LockScreenBanner(state: context.state)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: context.state.activitySymbolName(expanded: true))
                            .foregroundStyle(context.state.activityTint)
                            .font(.title2)
                        Text(context.state.activityTitle)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let started = context.state.segmentStartedAt, context.state.isSegmentActive {
                        Text(Date(timeIntervalSince1970: started), style: .timer)
                            .monospacedDigit()
                            .font(.headline)
                            .foregroundStyle(.white)
                    } else {
                        Text(context.state.isTranscribing ? "Working" : "Ready")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RecordButton(state: context.state, compact: false)
                }
            } compactLeading: {
                Image(systemName: context.state.activitySymbolName(expanded: false))
                    .foregroundStyle(context.state.activityTint)
            } compactTrailing: {
                if let started = context.state.segmentStartedAt, context.state.isSegmentActive {
                    Text(Date(timeIntervalSince1970: started), style: .timer)
                        .monospacedDigit()
                        .frame(maxWidth: 44)
                } else if context.state.isTranscribing {
                    Text("…")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Text("Ready").font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
            } minimal: {
                Image(systemName: context.state.activitySymbolName(expanded: false))
                    .foregroundStyle(context.state.activityTint)
            }
        }
    }
}

@available(iOS 17.0, *)
private struct LockScreenBanner: View {
    let state: VoxboardLiveActivityState

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(state.isSegmentActive ? Color.red.opacity(0.2) : Color.white.opacity(0.1))
                    .frame(width: 44, height: 44)
                Image(systemName: state.activitySymbolName(expanded: false))
                    .foregroundStyle(state.activityTint)
                    .font(.title3)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Vox.md")
                    .font(.headline)
                    .foregroundStyle(.white)
                if let started = state.segmentStartedAt, state.isSegmentActive {
                    HStack(spacing: 4) {
                        Text("Recording")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                        Text(Date(timeIntervalSince1970: started), style: .timer)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                } else {
                    Text(state.isTranscribing ? "Processing audio" : "Tap to record")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer(minLength: 8)

            RecordButton(state: state, compact: true)
        }
    }
}

@available(iOS 17.0, *)
private struct RecordButton: View {
    let state: VoxboardLiveActivityState
    let compact: Bool

    var body: some View {
        if state.isSegmentActive {
            Button(intent: StopRecordingLiveActivityIntent(requestId: state.segmentRequestId)) {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .padding(.horizontal, compact ? 14 : 20)
                    .padding(.vertical, compact ? 8 : 12)
                    .background(Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        } else if state.isTranscribing {
            Label("Processing", systemImage: "hourglass")
                .labelStyle(.titleAndIcon)
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .padding(.horizontal, compact ? 14 : 20)
                .padding(.vertical, compact ? 8 : 12)
                .background(Color.white.opacity(0.16), in: Capsule())
                .foregroundStyle(.white)
        } else {
            Button(intent: StartRecordingLiveActivityIntent()) {
                Label("Record", systemImage: "record.circle")
                    .labelStyle(.titleAndIcon)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .padding(.horizontal, compact ? 14 : 20)
                    .padding(.vertical, compact ? 8 : 12)
                    .background(Color.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
    }
}

@available(iOS 17.0, *)
private extension VoxboardLiveActivityState {
    var activityTitle: String {
        if isSegmentActive { return "Recording" }
        if isTranscribing { return "Processing" }
        return "Vox.md"
    }

    var activityTint: Color {
        if isSegmentActive { return .red }
        return .white
    }

    func activitySymbolName(expanded: Bool) -> String {
        if isSegmentActive { return expanded ? "waveform.circle.fill" : "waveform" }
        if isTranscribing { return expanded ? "hourglass.circle" : "hourglass" }
        return expanded ? "mic.circle" : "mic.fill"
    }
}
