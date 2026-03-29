import WidgetKit
import SwiftUI

// MARK: - Entry

struct VoxboardWidgetEntry: TimelineEntry {
    let date: Date
    let isListening: Bool
}

// MARK: - Provider

struct VoxboardWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> VoxboardWidgetEntry {
        VoxboardWidgetEntry(date: .now, isListening: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (VoxboardWidgetEntry) -> Void) {
        completion(VoxboardWidgetEntry(date: .now, isListening: readListeningState()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VoxboardWidgetEntry>) -> Void) {
        let entry = VoxboardWidgetEntry(date: .now, isListening: readListeningState())
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900)))
        completion(timeline)
    }

    // Read listening state directly from App Group (avoids importing VoxboardShared)
    static func readListeningState(containerURL: URL? = nil) -> Bool {
        let container = containerURL ?? FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.bontecou.Voxboard"
        )
        guard let container else { return false }
        let url = container
            .appendingPathComponent("TranscriptionIPC")
            .appendingPathComponent("listening_state.json")
        guard let data = try? Data(contentsOf: url) else { return false }
        struct ListeningState: Decodable { let isListening: Bool }
        return (try? JSONDecoder().decode(ListeningState.self, from: data))?.isListening ?? false
    }

    private func readListeningState() -> Bool {
        Self.readListeningState()
    }
}

// MARK: - Widget

struct VoxboardRecordWidget: Widget {
    let kind: String = "VoxboardRecordWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VoxboardWidgetProvider()) { entry in
            VoxboardWidgetEntryView(entry: entry)
                .containerBackground(.black, for: .widget)
                .widgetURL(URL(string: "voxboard://widget-record")!)
        }
        .configurationDisplayName("Quick Record")
        .description("Tap to open Voxboard and start recording.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .systemSmall])
    }
}
