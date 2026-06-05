import SwiftUI
import WidgetKit

// MARK: - Entry View (dispatches by family)

struct VoxboardWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: VoxboardWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularWidgetView(entry: entry)
        case .accessoryRectangular:
            RectangularWidgetView(entry: entry)
        case .systemSmall:
            SmallWidgetView(entry: entry)
        default:
            CircularWidgetView(entry: entry)
        }
    }
}

// MARK: - Lock Screen: Circular

struct CircularWidgetView: View {
    let entry: VoxboardWidgetEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: entry.isQuickRecordEnabled ? (entry.isListening ? "mic.fill" : "mic") : "mic.slash")
                .font(.system(size: 22, weight: .semibold))
                .widgetAccentable()
                .foregroundStyle(entry.isQuickRecordEnabled ? .primary : .secondary)
        }
    }
}

// MARK: - Lock Screen: Rectangular

struct RectangularWidgetView: View {
    let entry: VoxboardWidgetEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 2) {
                Text("VOXBOARD")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .widgetAccentable()
                Text(entry.isQuickRecordEnabled ? (entry.isListening ? "Listening" : "Tap to record") : "Disabled")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Home Screen: Small

struct SmallWidgetView: View {
    let entry: VoxboardWidgetEntry

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                HStack {
                    Circle()
                        .fill(entry.isQuickRecordEnabled && entry.isListening ? Color.white : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(entry.isQuickRecordEnabled ? (entry.isListening ? "LISTENING" : "OFF") : "DISABLED")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(entry.isQuickRecordEnabled && entry.isListening ? .white : .gray)
                    Spacer()
                }
                Spacer()
                Image(systemName: "mic.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text(entry.isQuickRecordEnabled ? "TAP TO RECORD" : "OFF IN SETTINGS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.5))
            }
            .padding(16)
        }
    }
}

// MARK: - Previews

#Preview("Circular", as: .accessoryCircular) {
    VoxboardRecordWidget()
} timeline: {
    VoxboardWidgetEntry(date: .now, isListening: false, isQuickRecordEnabled: true)
    VoxboardWidgetEntry(date: .now, isListening: true, isQuickRecordEnabled: true)
    VoxboardWidgetEntry(date: .now, isListening: false, isQuickRecordEnabled: false)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    VoxboardRecordWidget()
} timeline: {
    VoxboardWidgetEntry(date: .now, isListening: false, isQuickRecordEnabled: true)
    VoxboardWidgetEntry(date: .now, isListening: true, isQuickRecordEnabled: true)
    VoxboardWidgetEntry(date: .now, isListening: false, isQuickRecordEnabled: false)
}

#Preview("Small", as: .systemSmall) {
    VoxboardRecordWidget()
} timeline: {
    VoxboardWidgetEntry(date: .now, isListening: false, isQuickRecordEnabled: true)
    VoxboardWidgetEntry(date: .now, isListening: true, isQuickRecordEnabled: true)
    VoxboardWidgetEntry(date: .now, isListening: false, isQuickRecordEnabled: false)
}
