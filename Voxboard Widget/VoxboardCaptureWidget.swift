import SwiftUI
import VoxboardShared
import WidgetKit

private struct VoxboardCaptureEntry: TimelineEntry {
    let date: Date
}

private struct VoxboardCaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoxboardCaptureEntry { VoxboardCaptureEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (VoxboardCaptureEntry) -> Void) {
        completion(VoxboardCaptureEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VoxboardCaptureEntry>) -> Void) {
        completion(Timeline(entries: [VoxboardCaptureEntry(date: .now)], policy: .never))
    }
}

struct VoxboardCaptureWidget: Widget {
    let kind = "VoxboardCaptureWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VoxboardCaptureProvider()) { _ in
            VoxboardCaptureWidgetView()
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Quick Capture")
        .description("Open Vox.md directly to a durable Markdown capture draft.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .systemSmall,
            .systemMedium,
            .systemLarge,
        ])
    }
}

private struct VoxboardCaptureWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Link(destination: captureURL()) {
                Image(systemName: "square.and.pencil")
                    .font(.title2.bold())
                    .widgetAccentable()
            }
            .accessibilityLabel("Quick Capture")
        case .accessoryRectangular:
            Link(destination: captureURL()) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .widgetAccentable()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Capture").font(.caption.bold())
                        Text("Markdown note").font(.caption2)
                    }
                }
            }
        case .systemMedium:
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick Capture").font(.caption.bold())
                HStack(spacing: 8) {
                    action("Note", icon: "square.and.pencil", url: captureURL())
                    action("Photo", icon: "photo", url: captureURL(action: "photos"))
                    action("Scan", icon: "doc.viewfinder", url: captureURL(action: "scan"))
                    action("Sketch", icon: "pencil.tip", url: captureURL(action: "sketch"))
                    action("Voice", icon: "mic.fill", url: captureURL(action: "voice"))
                }
            }
        case .systemLarge:
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick Capture").font(.headline.bold())
                Text("Local drafts → precise Markdown routes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 10) {
                    action("Note", icon: "square.and.pencil", url: captureURL())
                    action("Photo", icon: "photo", url: captureURL(action: "photos"))
                    action("Screenshot", icon: "rectangle.inset.filled.and.person.filled", url: captureURL(action: "screenshots"))
                    action("Camera", icon: "camera", url: captureURL(action: "camera"))
                    action("File", icon: "doc.badge.plus", url: captureURL(action: "files"))
                    action("Link", icon: "link", url: captureURL(action: "link"))
                    action("Scan", icon: "doc.viewfinder", url: captureURL(action: "scan"))
                    action("Sketch", icon: "pencil.tip", url: captureURL(action: "sketch"))
                    action("Voice", icon: "mic.fill", url: captureURL(action: "voice"))
                }
            }
        default:
            Link(destination: captureURL()) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "square.and.pencil")
                        .font(.title.bold())
                        .widgetAccentable()
                    Spacer()
                    Text("Quick Capture")
                        .font(.caption.bold())
                    Text("Text, links & files")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    private func action(_ title: String, icon: String, url: URL) -> some View {
        Link(destination: url) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.title3.bold())
                    .widgetAccentable()
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel(title + " capture")
    }

    private func captureURL(action: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "voxboard"
        components.host = "capture"
        var queryItems = [URLQueryItem(name: "source", value: "widget")]
        if let action {
            queryItems.append(URLQueryItem(name: "action", value: action))
        }
        if let voxID = CapturePresetProfileStore.selectedProfileID(defaults: AppConstants.sharedDefaults) {
            queryItems.append(URLQueryItem(name: "preset", value: voxID))
        }
        components.queryItems = queryItems
        return components.url!
    }
}
