import AppIntents
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

struct VoxboardWatchRecordConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Record voice note"
    static let description = IntentDescription("Start a local Watch recording and sync it to Vox.md.")
}

struct VoxboardWatchRecordProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> VoxboardWatchRecordEntry {
        VoxboardWatchRecordEntry(
            date: .now,
            snapshot: WatchRecordingSnapshot(phase: .idle, isQuickRecordEnabled: true)
        )
    }

    func snapshot(
        for configuration: VoxboardWatchRecordConfigurationIntent,
        in context: Context
    ) async -> VoxboardWatchRecordEntry {
        VoxboardWatchRecordEntry(date: .now, snapshot: currentSnapshot())
    }

    func timeline(
        for configuration: VoxboardWatchRecordConfigurationIntent,
        in context: Context
    ) async -> Timeline<VoxboardWatchRecordEntry> {
        let entry = VoxboardWatchRecordEntry(date: .now, snapshot: currentSnapshot())
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60)))
    }

    func recommendations() -> [AppIntentRecommendation<VoxboardWatchRecordConfigurationIntent>] {
        [
            AppIntentRecommendation(
                intent: VoxboardWatchRecordConfigurationIntent(),
                description: Text("Record voice note")
            )
        ]
    }

    private func currentSnapshot() -> WatchRecordingSnapshot {
        WatchLocalSnapshotStore.load() ?? WatchPhoneBridge.cachedSnapshot()
    }
}

struct VoxboardWatchRecordWidget: Widget {
    let kind = "VoxboardWatchRecordWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: VoxboardWatchRecordConfigurationIntent.self,
            provider: VoxboardWatchRecordProvider()
        ) { entry in
            VoxboardWatchRecordWidgetView(entry: entry)
                .containerBackground(.black, for: .widget)
                .widgetURL(WatchRecordingDeepLink.toggleURL)
        }
        .configurationDisplayName("Record voice note")
        .description("Start a voice note from your Apple Watch face and sync it to Vox.md on iPhone.")
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

    // Keep face-facing complication previews vector-drawn; oversized raster assets
    // can fail to render/select on physical Apple Watch hardware.
    private var circular: some View {
        RecordIntentButton {
            GeometryReader { proxy in
                let isWidePickerRow = proxy.size.width > proxy.size.height * 1.35
                let markSize = min(proxy.size.height * 0.58, 31)

                if isWidePickerRow {
                    HStack(spacing: max(proxy.size.height * 0.10, 8)) {
                        ZStack {
                            AccessoryWidgetBackground()
                            VoxboardComplicationMark(phase: entry.snapshot.phase)
                                .frame(width: markSize, height: markSize)
                        }
                        .frame(width: proxy.size.height, height: proxy.size.height)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Record voice note")
                                .font(WatchWidgetBrutal.label(12, weight: .bold))
                                .widgetAccentable()
                                .lineLimit(1)
                                .minimumScaleFactor(0.68)
                            Text("Tap to start")
                                .font(WatchWidgetBrutal.label(10, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.horizontal, max(proxy.size.height * 0.08, 6))
                } else {
                    ZStack {
                        AccessoryWidgetBackground()
                        VoxboardComplicationMark(phase: entry.snapshot.phase)
                            .frame(width: markSize, height: markSize)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .buttonStyle(.plain)
        .widgetLabel {
            Text("Record note")
        }
    }

    private var rectangular: some View {
        RecordIntentButton {
            HStack(spacing: 8) {
                VoxboardComplicationMark(phase: entry.snapshot.phase)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(stateColor)
                            .frame(width: 4, height: 4)
                            .widgetAccentable()
                        Text("VOX.MD")
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
            VoxboardComplicationMark(phase: entry.snapshot.phase)
                .frame(width: 20, height: 20)
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
            return "Check Vox.md"
        case .unavailable:
            return "Open iPhone"
        case .idle, .listening:
            return entry.snapshot.queuedCount > 0 ? entry.snapshot.subtitle : "Record to Vox.md"
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

private struct VoxboardComplicationMark: View {
    let phase: WatchRecordingPhase

    private let barHeights: [CGFloat] = [0.66, 0.48, 0.82, 0.56, 0.72]

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let barWidth = max(side * 0.105, 2)
            let spacing = max(side * 0.055, 1)
            let waveformWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * spacing

            ZStack {
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(barHeights.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                            .fill(.primary)
                            .frame(width: barWidth, height: side * barHeights[index])
                            .widgetAccentable()
                    }
                }
                .frame(width: waveformWidth, height: side * 0.86)
                .position(x: side * 0.5, y: side * 0.58)

                Circle()
                    .fill(dotColor)
                    .frame(width: max(side * 0.16, 4), height: max(side * 0.16, 4))
                    .position(x: side * 0.5, y: side * 0.20)
                    .shadow(color: dotColor.opacity(0.45), radius: side * 0.06)
            }
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var dotColor: Color {
        switch phase {
        case .recording, .error, .unavailable:
            return WatchWidgetBrutal.error
        case .syncing, .transcribing:
            return .cyan
        case .pending:
            return .green
        case .idle, .listening:
            return Color(red: 1.0, green: 0.56, blue: 0.0)
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
