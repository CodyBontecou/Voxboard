import SwiftUI
import WidgetKit

struct VoxboardWatchRecordEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchRecordingSnapshot
}

struct VoxboardWatchRecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoxboardWatchRecordEntry {
        VoxboardWatchRecordEntry(
            date: .now,
            snapshot: WatchRecordingSnapshot(phase: .idle, isQuickRecordEnabled: true)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (VoxboardWatchRecordEntry) -> Void) {
        completion(VoxboardWatchRecordEntry(date: .now, snapshot: WatchPhoneBridge.cachedSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VoxboardWatchRecordEntry>) -> Void) {
        let entry = VoxboardWatchRecordEntry(date: .now, snapshot: WatchPhoneBridge.cachedSnapshot())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }
}

struct VoxboardWatchRecordWidget: Widget {
    let kind = "VoxboardWatchRecordWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VoxboardWatchRecordProvider()) { entry in
            VoxboardWatchRecordWidgetView(entry: entry)
                .containerBackground(.black, for: .widget)
                .widgetURL(WatchRecordingDeepLink.toggleURL)
        }
        .configurationDisplayName("Record to Voxboard")
        .description("Start a voice note from your Apple Watch face and sync it to Voxboard on iPhone.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct VoxboardWatchRecordWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VoxboardWatchRecordEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            inline
        case .accessoryCorner:
            corner
        default:
            circular
        }
    }

    private var circular: some View {
        RecordIntentButton {
            ZStack {
                AccessoryWidgetBackground()
                appIcon(size: 30, cornerRadius: 7)
            }
        }
        .buttonStyle(.plain)
    }

    private var rectangular: some View {
        RecordIntentButton {
            HStack(spacing: 8) {
                appIcon(size: 24, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text("VOXBOARD")
                        .font(.caption2.weight(.bold))
                        .widgetAccentable()
                    Text("Record to Voxboard")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var inline: some View {
        RecordIntentButton {
            Label {
                Text(inlineTitle)
            } icon: {
                appIcon(size: 14, cornerRadius: 3)
            }
        }
        .buttonStyle(.plain)
    }

    private var corner: some View {
        RecordIntentButton {
            appIcon(size: 26, cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .widgetLabel {
            Text("Record")
        }
    }

    private func appIcon(size: CGFloat, cornerRadius: CGFloat) -> some View {
        Image("VoxboardWidgetIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .unredacted()
    }

    private var inlineTitle: String {
        "Record to Voxboard"
    }
}

private struct RecordIntentButton<LabelView: View>: View {
    @ViewBuilder let label: () -> LabelView

    var body: some View {
        label()
    }
}

#Preview("Circular", as: .accessoryCircular) {
    VoxboardWatchRecordWidget()
} timeline: {
    VoxboardWatchRecordEntry(date: .now, snapshot: WatchRecordingSnapshot(phase: .idle, isQuickRecordEnabled: true))
    VoxboardWatchRecordEntry(date: .now, snapshot: WatchRecordingSnapshot(phase: .recording, isQuickRecordEnabled: true, recordingStartedAt: Date().timeIntervalSince1970))
}

#Preview("Rectangular", as: .accessoryRectangular) {
    VoxboardWatchRecordWidget()
} timeline: {
    VoxboardWatchRecordEntry(date: .now, snapshot: WatchRecordingSnapshot(phase: .idle, isQuickRecordEnabled: true))
    VoxboardWatchRecordEntry(date: .now, snapshot: WatchRecordingSnapshot(phase: .transcribing, isQuickRecordEnabled: true))
}
