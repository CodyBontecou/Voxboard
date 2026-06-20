import SwiftUI
import WidgetKit

private enum WatchWidgetBrutal {
    static let error = Color(red: 1.0, green: 0.271, blue: 0.227)

    static func label(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

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
        completion(VoxboardWatchRecordEntry(date: .now, snapshot: currentSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VoxboardWatchRecordEntry>) -> Void) {
        let entry = VoxboardWatchRecordEntry(date: .now, snapshot: currentSnapshot())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }

    private func currentSnapshot() -> WatchRecordingSnapshot {
        WatchLocalSnapshotStore.load() ?? WatchPhoneBridge.cachedSnapshot()
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
                Image(systemName: stateSymbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(stateColor)
                    .widgetAccentable()
            }
        }
        .buttonStyle(.plain)
    }

    private var rectangular: some View {
        RecordIntentButton {
            HStack(spacing: 8) {
                appIcon(size: 24, cornerRadius: 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(stateColor)
                            .frame(width: 4, height: 4)
                            .widgetAccentable()
                        Text("VOXBOARD")
                            .font(WatchWidgetBrutal.label(11, weight: .bold))
                            .widgetAccentable()
                    }
                    subtitleText
                        .font(WatchWidgetBrutal.label(10, weight: .regular))
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
                if entry.snapshot.shouldShowTimer, let started = entry.snapshot.recordingStartedAt {
                    Text(Date(timeIntervalSince1970: started), style: .timer)
                } else {
                    Text(inlineTitle)
                }
            } icon: {
                Image(systemName: stateSymbolName)
            }
        }
        .buttonStyle(.plain)
    }

    private var corner: some View {
        RecordIntentButton {
            Image(systemName: stateSymbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(stateColor)
                .widgetAccentable()
        }
        .buttonStyle(.plain)
        .widgetLabel {
            Text(cornerLabel)
        }
    }

    @ViewBuilder
    private var subtitleText: some View {
        if entry.snapshot.shouldShowTimer, let started = entry.snapshot.recordingStartedAt {
            Text(Date(timeIntervalSince1970: started), style: .timer)
                .monospacedDigit()
        } else {
            Text(entry.snapshot.subtitle)
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

    private var stateSymbolName: String {
        entry.snapshot.actionSymbol
    }

    private var stateColor: Color {
        switch entry.snapshot.phase {
        case .recording, .error, .unavailable:
            return WatchWidgetBrutal.error
        default:
            return .primary
        }
    }

    private var inlineTitle: String {
        switch entry.snapshot.phase {
        case .recording:
            return "Recording"
        case .syncing:
            return "Syncing"
        case .transcribing:
            return "Processing"
        case .pending:
            return "Synced"
        case .error:
            return "Check Voxboard"
        case .unavailable:
            return "Open iPhone"
        case .idle, .listening:
            return entry.snapshot.queuedCount > 0 ? entry.snapshot.subtitle : "Record to Voxboard"
        }
    }

    private var cornerLabel: String {
        switch entry.snapshot.phase {
        case .recording:
            return "Stop"
        case .syncing:
            return "Sync"
        case .transcribing:
            return "Work"
        case .pending:
            return "Sent"
        case .error, .unavailable:
            return "Open"
        default:
            return entry.snapshot.queuedCount > 0 ? "Sync" : "Record"
        }
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
