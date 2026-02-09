import SwiftUI
import VoxVaultShared

/// Shows previous transcriptions in a scrollable list.
/// Supports copy to clipboard, swipe-to-delete, and clear all.
struct HistoryView: View {
    @Environment(TranscriptStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.transcripts.isEmpty {
                    emptyState
                } else {
                    transcriptList
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                if !store.transcripts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear All", role: .destructive) {
                            store.clear()
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            store.reload()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            "No Transcripts Yet",
            systemImage: "waveform",
            description: Text("Your voice transcriptions will appear here")
        )
    }

    // MARK: - Transcript List

    private var transcriptList: some View {
        List {
            ForEach(store.transcripts) { transcript in
                VStack(alignment: .leading, spacing: 8) {
                    Text(transcript.text)
                        .font(.body)
                        .lineLimit(4)

                    HStack(spacing: 4) {
                        Text(transcript.date, style: .relative)
                        Text("·")
                        Text(transcript.modelUsed)
                        Text("·")
                        Text(formatDuration(transcript.duration))
                        if transcript.language != "auto" {
                            Text("·")
                            Text(transcript.language.uppercased())
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = transcript.text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
            .onDelete { offsets in
                store.delete(at: offsets)
            }
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ d: TimeInterval) -> String {
        let s = Int(d)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
