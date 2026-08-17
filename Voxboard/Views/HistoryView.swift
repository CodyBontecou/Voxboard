import SwiftUI
import UIKit
import VoxboardShared

struct HistoryView: View {
    @Bindable var viewModel: QuickCaptureViewModel
    @Environment(TranscriptStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showClearHistoryConfirmation = false
    @State private var searchText = ""
    @State private var editingTranscript: Transcript?
    @State private var sharePayload: TranscriptSharePayload?
    @State private var exportError: String?

    private var unifiedItems: [UnifiedHistoryItem] {
        var captureByID: [UUID: CaptureHistoryRecord] = [:]
        for record in viewModel.historyRecords { captureByID[record.requestID] = record }
        let transcriptIDs = Set(store.transcripts.map(\.id))
        let transcriptItems = store.transcripts.map { transcript in
            UnifiedHistoryItem.transcript(transcript, delivery: captureByID[transcript.id])
        }
        let captureItems = viewModel.historyRecords
            .filter { !transcriptIDs.contains($0.requestID) }
            .map(UnifiedHistoryItem.capture)
        return (transcriptItems + captureItems).sorted { $0.date > $1.date }
    }

    private var filteredItems: [UnifiedHistoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return unifiedItems }
        return unifiedItems.filter { $0.matches(query) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Geist.Palette.background200.ignoresSafeArea()
                if unifiedItems.isEmpty {
                    emptyState
                } else if filteredItems.isEmpty {
                    noSearchResults
                } else {
                    transcriptList
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search history")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("History")
                        .font(Geist.heading(.headline))
                        .foregroundColor(Geist.text)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Geist.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                if !unifiedItems.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            showClearHistoryConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Geist.error)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear all history")
                    }
                }
            }
            .toolbarBackground(Geist.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .alert("Clear all history?", isPresented: $showClearHistoryConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear All", role: .destructive) {
                    store.clear()
                    Task { await viewModel.clearHistory() }
                }
            } message: {
                Text("This clears transcript content and Capture delivery metadata. It does not delete exported Markdown notes or attachments.")
            }
            .alert("History Error", isPresented: errorPresented) {
                Button("Dismiss Error") {
                    exportError = nil
                    store.clearPersistenceError()
                }
            } message: {
                Text(exportError ?? store.lastPersistenceError?.localizedDescription ?? String(localized: "Unknown error"))
            }
            .sheet(item: $editingTranscript) { transcript in
                TranscriptEditView(transcript: transcript) { edited in
                    store.update(edited)
                }
            }
            .sheet(item: $sharePayload) { payload in
                TranscriptActivityView(activityItems: [payload.url])
                    .ignoresSafeArea()
            }
        }
        .onAppear { store.reload() }
        .task { await viewModel.refreshHistory() }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { exportError != nil || store.lastPersistenceError != nil },
            set: { presented in
                if !presented {
                    exportError = nil
                    store.clearPersistenceError()
                }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            GeistSectionLabel(number: "—", title: "Empty")
            Text("No History Yet")
                .font(Geist.heading(.title))
                .foregroundColor(Geist.text)
            Text("Record or send a Capture to create your first history item.")
                .font(Geist.body())
                .foregroundColor(Geist.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    private var noSearchResults: some View {
        ContentUnavailableView.search(text: searchText)
            .foregroundStyle(Geist.muted)
    }

    private var transcriptList: some View {
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

            ForEach(filteredItems) { item in
                unifiedHistoryRow(item)
                    .listRowBackground(Geist.Palette.background200)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        if case .transcript(let transcript, _) = item {
                            Button("Edit", systemImage: "pencil") { editingTranscript = transcript }
                            Button("Export", systemImage: "square.and.arrow.up") { export(transcript) }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                store.delete(ids: [transcript.id])
                            }
                        }
                    }
            }
        }
        .listStyle(.plain)
        .background(Geist.Palette.background200)
        .scrollContentBackground(.hidden)
        .refreshable {
            store.reload()
            await viewModel.refreshHistory()
        }
    }

    @ViewBuilder
    private func unifiedHistoryRow(_ item: UnifiedHistoryItem) -> some View {
        switch item {
        case .transcript(let transcript, let delivery):
            transcriptRow(transcript, delivery: delivery)
        case .capture(let record):
            captureRow(record)
        }
    }

    private func transcriptRow(_ transcript: Transcript, delivery: CaptureHistoryRecord?) -> some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            HStack(alignment: .top, spacing: Geist.Spacing.three) {
                VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                    if let title = transcript.title, !title.isEmpty {
                        Text(title)
                            .font(Geist.heading(.headline))
                            .foregroundStyle(Geist.text)
                            .lineLimit(2)
                    }
                    Text("\(relativeDate(transcript.date)) · \(formatDuration(transcript.duration))")
                        .font(Geist.mono())
                        .foregroundStyle(Geist.muted)
                        .lineLimit(1)
                    if let delivery {
                        Label(
                            delivery.outcome == .delivered
                                ? String(localized: "Delivered")
                                : String(localized: "Delivery failed"),
                            systemImage: delivery.outcome == .delivered ? "checkmark.circle" : "exclamationmark.triangle"
                        )
                        .font(Geist.caption(.caption2))
                        .foregroundStyle(delivery.outcome == .delivered ? Geist.muted : Geist.error)
                    }
                    if transcript.speakerCount > 0 {
                        Label(
                            "\(transcript.speakerCount) speaker\(transcript.speakerCount == 1 ? "" : "s")",
                            systemImage: "person.2.wave.2"
                        )
                        .font(Geist.caption(.caption2))
                        .foregroundStyle(Geist.muted)
                    }
                    if let reason = transcript.speakerDiarizationSkipReason {
                        Label(reason.displayText, systemImage: "exclamationmark.triangle")
                            .font(Geist.caption(.caption2))
                            .foregroundStyle(Geist.error)
                    }
                }
                Spacer()
                copyMenu(for: transcript)
                actionMenu(for: transcript)
            }

            Text(transcript.cleanedText ?? transcript.text)
                .font(Geist.body())
                .foregroundStyle(Geist.text)
                .lineLimit(5)

            if let tags = transcript.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Geist.Spacing.two) {
                        ForEach(tags.prefix(5), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(Geist.caption())
                                .foregroundStyle(Geist.muted)
                                .padding(.horizontal, Geist.Spacing.two)
                                .frame(height: 28)
                                .background(Geist.Palette.gray100)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .geistCard(padding: Geist.Spacing.four)
        .padding(.horizontal, Geist.Spacing.four)
        .padding(.vertical, Geist.Spacing.two)
        .contentShape(Rectangle())
    }

    private func captureRow(_ record: CaptureHistoryRecord) -> some View {
        HStack(alignment: .top, spacing: Geist.Spacing.three) {
            Image(systemName: record.outcome == .delivered ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(record.outcome == .delivered ? Geist.text : Geist.error)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: Geist.Spacing.two) {
                HStack {
                    Text(record.destinationName)
                        .font(Geist.heading(.headline))
                    Spacer()
                    Text(record.deliveredAt ?? record.createdAt, style: .relative)
                        .font(Geist.caption())
                        .foregroundStyle(Geist.muted)
                }
                if let path = record.relativeNotePath {
                    Text(path)
                        .font(Geist.mono())
                        .foregroundStyle(Geist.muted)
                        .lineLimit(2)
                }
                HStack(spacing: Geist.Spacing.two) {
                    Text(captureSourceLabel(record.source))
                    if let voxName = record.voxName {
                        Label(voxName, systemImage: "waveform.circle")
                    }
                    if record.attachmentCount > 0 {
                        Label("\(record.attachmentCount)", systemImage: "paperclip")
                    }
                    if let failure = record.failureCategory { Text(failure.displayName) }
                }
                .font(Geist.caption())
                .foregroundStyle(record.outcome == .failed ? Geist.error : Geist.faint)
            }
        }
        .geistCard(padding: Geist.Spacing.four)
        .padding(.horizontal, Geist.Spacing.four)
        .padding(.vertical, Geist.Spacing.two)
        .accessibilityElement(children: .combine)
    }

    private func captureSourceLabel(_ source: CaptureSource) -> String {
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

    @ViewBuilder
    private func copyMenu(for transcript: Transcript) -> some View {
        if let cleaned = transcript.cleanedText, !cleaned.isEmpty {
            Menu {
                Button("Copy cleaned") { UIPasteboard.general.string = cleaned }
                Button("Copy raw") { UIPasteboard.general.string = transcript.text }
            } label: {
                historyActionLabel("Copy")
            }
        } else {
            Button { UIPasteboard.general.string = transcript.text } label: {
                historyActionLabel("Copy")
            }
            .buttonStyle(.plain)
        }
    }

    private func actionMenu(for transcript: Transcript) -> some View {
        Menu {
            Button("Edit", systemImage: "pencil") { editingTranscript = transcript }
            Button("Export", systemImage: "square.and.arrow.up") { export(transcript) }
            Button("Delete", systemImage: "trash", role: .destructive) {
                store.delete(ids: [transcript.id])
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Geist.text)
                .frame(width: 32, height: 32)
                .background(Geist.Palette.gray100)
                .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous))
        }
    }

    private func historyActionLabel(_ label: String) -> some View {
        Text(label.capitalized)
            .font(Geist.label(.footnote))
            .foregroundStyle(Geist.text)
            .padding(.horizontal, Geist.Spacing.two)
            .frame(height: Geist.ControlHeight.small)
            .background(Geist.Palette.gray100)
            .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous))
    }

    private func export(_ transcript: Transcript) {
        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoxboardHistoryExports", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = try TranscriptFileExporter.export(
                transcript,
                format: .md,
                mode: .newFile,
                folderURL: folder,
                newFileNameTemplateOverride: "transcript-{date}-{id8}"
            )
            sharePayload = TranscriptSharePayload(url: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return String(localized: "just now") }
        if diff < 3600 { return String(format: String(localized: "%dm ago"), Int(diff / 60)) }
        if diff < 86400 { return String(format: String(localized: "%dh ago"), Int(diff / 3600)) }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        return seconds < 60
            ? String(format: String(localized: "%ds"), seconds)
            : String(format: String(localized: "%dm %ds"), seconds / 60, seconds % 60)
    }
}

private enum UnifiedHistoryItem: Identifiable {
    case transcript(Transcript, delivery: CaptureHistoryRecord?)
    case capture(CaptureHistoryRecord)

    var id: String {
        switch self {
        case .transcript(let transcript, _): return "transcript-\(transcript.id.uuidString)"
        case .capture(let record): return "capture-\(record.requestID.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case .transcript(let transcript, _): return transcript.date
        case .capture(let record): return record.deliveredAt ?? record.createdAt
        }
    }

    func matches(_ query: String) -> Bool {
        switch self {
        case .transcript(let transcript, let delivery):
            if TranscriptSearch.matches(transcript, query: query) { return true }
            return delivery.map { Self.captureHaystack($0).localizedCaseInsensitiveContains(query) } ?? false
        case .capture(let record):
            return Self.captureHaystack(record).localizedCaseInsensitiveContains(query)
        }
    }

    private static func captureHaystack(_ record: CaptureHistoryRecord) -> String {
        [
            record.destinationName,
            record.voxName,
            record.relativeNotePath,
            record.source.rawValue,
            record.outcome.rawValue,
            record.failureCategory?.displayName,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

private struct TranscriptEditView: View {
    @Environment(\.dismiss) private var dismiss
    let transcript: Transcript
    let onSave: (Transcript) -> Void

    @State private var rawText: String
    @State private var cleanedText: String
    @State private var title: String
    @State private var tags: String
    @State private var category: String

    init(transcript: Transcript, onSave: @escaping (Transcript) -> Void) {
        self.transcript = transcript
        self.onSave = onSave
        _rawText = State(initialValue: transcript.text)
        _cleanedText = State(initialValue: transcript.cleanedText ?? "")
        _title = State(initialValue: transcript.title ?? "")
        _tags = State(initialValue: transcript.tags?.joined(separator: ", ") ?? "")
        _category = State(initialValue: transcript.category ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title and organization") {
                    TextField("Title", text: $title)
                    TextField("Tags, comma separated", text: $tags)
                    TextField("Category", text: $category)
                }
                Section("Cleaned text") {
                    TextEditor(text: $cleanedText).frame(minHeight: 140)
                }
                Section("Raw transcript") {
                    TextEditor(text: $rawText).frame(minHeight: 180)
                }
            }
            .navigationTitle("Edit Transcript")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let parsedTags = tags
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onSave(transcript.withEdits(
                            text: rawText,
                            title: nilIfEmpty(title),
                            tags: parsedTags.isEmpty ? nil : parsedTags,
                            category: nilIfEmpty(category),
                            cleanedText: nilIfEmpty(cleanedText)
                        ))
                        dismiss()
                    }
                }
            }
        }
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct TranscriptSharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

private struct TranscriptActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
