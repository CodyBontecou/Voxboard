import SwiftUI
import VoxboardShared

struct CaptureHistoryView: View {
    @Bindable var viewModel: QuickCaptureViewModel
    @State private var confirmsClear = false

    var body: some View {
        Group {
            if viewModel.historyRecords.isEmpty {
                ContentUnavailableView(
                    "No Recent Captures",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Successful and retryable deliveries will appear here without duplicating your note content.")
                )
            } else {
                List {
                    if viewModel.failedInboxCount > 0 {
                        Section {
                            Button {
                                Task { await viewModel.retryFailedInbox() }
                            } label: {
                                Label(
                                    "Retry \(viewModel.failedInboxCount) queued capture\(viewModel.failedInboxCount == 1 ? "" : "s")",
                                    systemImage: "arrow.clockwise.circle"
                                )
                            }
                        } header: {
                            Text("Needs attention")
                        }
                    }

                    Section("Recent delivery metadata") {
                        ForEach(viewModel.historyRecords) { record in
                            historyRow(record)
                        }
                    }
                }
                .refreshable { await viewModel.refreshHistory() }
            }
        }
        .navigationTitle("Recent Captures")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !viewModel.historyRecords.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) { confirmsClear = true }
                }
            }
        }
        .alert("Clear capture history?", isPresented: $confirmsClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) {
                Task { await viewModel.clearHistory() }
            }
        } message: {
            Text("This removes local delivery metadata only. It never deletes Markdown notes or attachments.")
        }
        .task { await viewModel.refreshHistory() }
    }

    private func historyRow(_ record: CaptureHistoryRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.outcome == .delivered ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(record.outcome == .delivered ? Geist.text : Geist.error)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(record.destinationName)
                        .font(Geist.label())
                    Spacer()
                    Text(record.deliveredAt ?? record.createdAt, style: .relative)
                        .font(Geist.caption())
                        .foregroundStyle(Geist.muted)
                }
                if let path = record.relativeNotePath {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(Geist.muted)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text(sourceLabel(record.source))
                    if record.attachmentCount > 0 {
                        Label("\(record.attachmentCount)", systemImage: "paperclip")
                    }
                    if let failure = record.failureCategory {
                        Text(failure.displayName)
                    }
                }
                .font(Geist.caption())
                .foregroundStyle(record.outcome == .failed ? Geist.error : Geist.faint)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary(record))
    }

    private func sourceLabel(_ source: CaptureSource) -> String {
        switch source {
        case .app: return String(localized: "App")
        case .keyboard: return String(localized: "Keyboard")
        case .widget: return String(localized: "Widget")
        case .shortcut: return String(localized: "Shortcut")
        case .shareExtension: return String(localized: "Share")
        case .watch: return String(localized: "Watch")
        case .mac: return String(localized: "Mac")
        case .deepLink: return String(localized: "Deep Link")
        case .fileImport: return String(localized: "File Import")
        case .voice: return String(localized: "Voice")
        }
    }

    private func accessibilitySummary(_ record: CaptureHistoryRecord) -> String {
        let status = record.outcome == .delivered ? String(localized: "Delivered") : String(localized: "Failed")
        let attachments = record.attachmentCount == 0
            ? ""
            : String(localized: ", \(record.attachmentCount) attachments")
        let failure = record.failureCategory.map { ", \($0.displayName)" } ?? ""
        let timestamp = (record.deliveredAt ?? record.createdAt).formatted(
            date: .abbreviated,
            time: .shortened
        )
        return "\(status), \(record.destinationName), \(sourceLabel(record.source))\(attachments)\(failure), \(timestamp)"
    }
}
