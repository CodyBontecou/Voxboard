import SwiftUI
import UIKit
import VoxboardShared

struct HistoryView: View {
    @Environment(TranscriptStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showClearHistoryConfirmation = false
    @State private var searchText = ""
    @State private var editingTranscript: Transcript?
    @State private var sharePayload: TranscriptSharePayload?
    @State private var exportError: String?

    private var filteredTranscripts: [Transcript] {
        store.transcripts.filter { TranscriptSearch.matches($0, query: searchText) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Geist.Palette.background200.ignoresSafeArea()
                if store.transcripts.isEmpty {
                    emptyState
                } else if filteredTranscripts.isEmpty {
                    noSearchResults
                } else {
                    transcriptList
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search transcripts")
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
                if !store.transcripts.isEmpty {
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
                Button("Clear All", role: .destructive) { store.clear() }
            } message: {
                Text("Do you really want to clear all of your history? This can't be undone.")
            }
            .alert("History Error", isPresented: errorPresented) {
                Button("Dismiss Error") {
                    exportError = nil
                    store.clearPersistenceError()
                }
            } message: {
                Text(exportError ?? store.lastPersistenceError?.localizedDescription ?? "Unknown error")
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
            Text("No Transcripts Yet")
                .font(Geist.heading(.title))
                .foregroundColor(Geist.text)
            Text("Start a recording to create your first transcript.")
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
            ForEach(filteredTranscripts) { transcript in
                transcriptRow(transcript)
                    .listRowBackground(Geist.Palette.background200)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") {
                            editingTranscript = transcript
                        }
                        Button("Export", systemImage: "square.and.arrow.up") {
                            export(transcript)
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            store.delete(ids: [transcript.id])
                        }
                    }
            }
            .onDelete { offsets in
                let ids = Set(offsets.compactMap { index in
                    filteredTranscripts.indices.contains(index) ? filteredTranscripts[index].id : nil
                })
                store.delete(ids: ids)
            }
        }
        .listStyle(.plain)
        .background(Geist.Palette.background200)
        .scrollContentBackground(.hidden)
    }

    private func transcriptRow(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            HStack(alignment: .top, spacing: Geist.Spacing.three) {
                VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                    if let title = transcript.title, !title.isEmpty {
                        Text(title)
                            .font(Geist.heading(.headline))
                            .foregroundStyle(Geist.text)
                            .lineLimit(2)
                    }
                    HStack(spacing: Geist.Spacing.two) {
                        Text(relativeDate(transcript.date))
                        Text(transcript.modelUsed)
                        Text(formatDuration(transcript.duration))
                        if transcript.language != "auto" { Text(transcript.language) }
                    }
                    .font(Geist.mono())
                    .foregroundStyle(Geist.muted)
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
