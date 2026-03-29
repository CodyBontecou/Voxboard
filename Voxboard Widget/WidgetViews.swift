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
            Image(systemName: entry.isListening ? "mic.fill" : "mic")
                .font(.system(size: 22, weight: .semibold))
                .widgetAccentable()
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
                Text(entry.isListening ? "Listening" : "Tap to record")
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
                        .fill(entry.isListening ? Color.white : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(entry.isListening ? "LISTENING" : "OFF")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(entry.isListening ? .white : .gray)
                    Spacer()
                }
                Spacer()
                Image(systemName: "mic.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("TAP TO RECORD")
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
    VoxboardWidgetEntry(date: .now, isListening: false)
    VoxboardWidgetEntry(date: .now, isListening: true)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    VoxboardRecordWidget()
} timeline: {
    VoxboardWidgetEntry(date: .now, isListening: false)
    VoxboardWidgetEntry(date: .now, isListening: true)
}

#Preview("Small", as: .systemSmall) {
    VoxboardRecordWidget()
} timeline: {
    VoxboardWidgetEntry(date: .now, isListening: false)
    VoxboardWidgetEntry(date: .now, isListening: true)
}
