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
                        Image(systemName: context.state.isSegmentActive ? "waveform.circle.fill" : "mic.circle")
                            .foregroundStyle(context.state.isSegmentActive ? .red : .white)
                            .font(.title2)
                        Text(context.state.isSegmentActive ? "Recording" : "Voxboard")
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
                        Text("Ready")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RecordButton(isSegmentActive: context.state.isSegmentActive, compact: false)
                }
            } compactLeading: {
                Image(systemName: context.state.isSegmentActive ? "waveform" : "mic")
                    .foregroundStyle(context.state.isSegmentActive ? .red : .white)
            } compactTrailing: {
                if let started = context.state.segmentStartedAt, context.state.isSegmentActive {
                    Text(Date(timeIntervalSince1970: started), style: .timer)
                        .monospacedDigit()
                        .frame(maxWidth: 44)
                } else {
                    Text("Ready").font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
            } minimal: {
                Image(systemName: context.state.isSegmentActive ? "waveform" : "mic")
                    .foregroundStyle(context.state.isSegmentActive ? .red : .white)
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
                Image(systemName: state.isSegmentActive ? "waveform" : "mic.fill")
                    .foregroundStyle(state.isSegmentActive ? .red : .white)
                    .font(.title3)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Voxboard")
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
                    Text("Tap to record")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer(minLength: 8)

            RecordButton(isSegmentActive: state.isSegmentActive, compact: true)
        }
    }
}

@available(iOS 17.0, *)
private struct RecordButton: View {
    let isSegmentActive: Bool
    let compact: Bool

    var body: some View {
        if isSegmentActive {
            Button(intent: StopRecordingLiveActivityIntent()) {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .padding(.horizontal, compact ? 14 : 20)
                    .padding(.vertical, compact ? 8 : 12)
                    .background(Color.red, in: Capsule())
                    .foregroundStyle(.white)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        } else {
            Button(intent: StartRecordingLiveActivityIntent()) {
                Label("Record", systemImage: "record.circle")
                    .labelStyle(.titleAndIcon)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .padding(.horizontal, compact ? 14 : 20)
                    .padding(.vertical, compact ? 8 : 12)
                    .background(Color.white, in: Capsule())
                    .foregroundStyle(.black)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
