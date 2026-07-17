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
                Brutal.bg.ignoresSafeArea()
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
                    Text("HISTORY")
                        .font(Brutal.label(.headline))
                        .foregroundColor(Brutal.text)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Brutal.muted)
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
                                .foregroundColor(Brutal.error)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear all history")
                    }
                }
            }
            .toolbarBackground(Brutal.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .alert("Clear all history?", isPresented: $showClearHistoryConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear All", role: .destructive) { store.clear() }
            } message: {
                Text("Do you really want to clear all of your history? This can't be undone.")
            }
            .alert("History Error", isPresented: errorPresented) {
                Button("OK") {
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
        .preferredColorScheme(.dark)
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
            BrutalSectionLabel(number: "—", title: "Empty")
            Text("NO TRANSCRIPTS.")
                .font(Brutal.display(36))
                .foregroundColor(Brutal.muted)
            Text("Use the keyboard mic in any app\nto see transcripts here.")
                .font(Brutal.body())
                .foregroundColor(Brutal.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    private var noSearchResults: some View {
        ContentUnavailableView.search(text: searchText)
            .foregroundStyle(Brutal.muted)
    }

    private var transcriptList: some View {
        List {
            ForEach(filteredTranscripts) { transcript in
                transcriptRow(transcript)
                    .listRowBackground(Brutal.bg)
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
        .background(Brutal.bg)
        .scrollContentBackground(.hidden)
    }

    private func transcriptRow(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            BrutalDivider()
            VStack(alignment: .leading, spacing: 12) {
                if let title = transcript.title, !title.isEmpty {
                    Text(title.uppercased())
                        .font(Brutal.label(.headline))
                        .foregroundColor(Brutal.text)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text(relativeDate(transcript.date))
                    Text("·")
                    Text(transcript.modelUsed.uppercased())
                    Text("·")
                    Text(formatDuration(transcript.duration).uppercased())
                    if transcript.language != "auto" {
                        Text("·")
                        Text(transcript.language.uppercased())
                    }
                    Spacer()
                    copyMenu(for: transcript)
                    actionMenu(for: transcript)
                }
                .font(Brutal.caption())
                .foregroundColor(Brutal.muted)

                Text(transcript.cleanedText ?? transcript.text)
                    .font(Brutal.body())
                    .foregroundColor(Brutal.text)
                    .lineSpacing(4)
                    .lineLimit(5)

                if let tags = transcript.tags, !tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(tags.prefix(5), id: \.self) { tag in
                            Text("#\(tag)".uppercased())
                                .font(Brutal.caption())
                                .foregroundColor(Brutal.muted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func copyMenu(for transcript: Transcript) -> some View {
        if let cleaned = transcript.cleanedText, !cleaned.isEmpty {
            Menu {
                Button("Copy cleaned") { UIPasteboard.general.string = cleaned }
                Button("Copy raw") { UIPasteboard.general.string = transcript.text }
            } label: {
                historyActionLabel("COPY")
            }
        } else {
            Button { UIPasteboard.general.string = transcript.text } label: {
                historyActionLabel("COPY")
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
                .foregroundStyle(Brutal.text)
                .frame(width: 30, height: 26)
                .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
        }
    }

    private func historyActionLabel(_ label: String) -> some View {
        Text(label)
            .font(Brutal.caption())
            .foregroundColor(Brutal.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
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
        .preferredColorScheme(.dark)
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
