import SwiftUI
import VoxboardShared

struct HistoryView: View {
    @Environment(TranscriptStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Brutal.bg.ignoresSafeArea()

                if store.transcripts.isEmpty {
                    emptyState
                } else {
                    transcriptList
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
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
                    .brutalHitTarget()
                    .accessibilityLabel("Close")
                }
                if !store.transcripts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("CLEAR ALL") { store.clear() }
                            .font(Brutal.label())
                            .foregroundColor(Brutal.error)
                            .buttonStyle(.plain)
                            .brutalHitTarget()
                    }
                }
            }
            .toolbarBackground(Brutal.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear { store.reload() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            BrutalSectionLabel(number: "—", title: "Empty")
            Text("NO TRANSCRIPTS.")
                .font(Brutal.display(36))
                .foregroundColor(Brutal.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
            Text("Use the keyboard mic in any app\nto see transcripts here.")
                .font(Brutal.body())
                .foregroundColor(Brutal.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - List

    private var transcriptList: some View {
        List {
            ForEach(store.transcripts) { transcript in
                transcriptRow(transcript)
                    .listRowBackground(Brutal.bg)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            .onDelete { store.delete(at: $0) }
        }
        .listStyle(.plain)
        .background(Brutal.bg)
        .scrollContentBackground(.hidden)
    }

    private func transcriptRow(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            BrutalDivider()

            VStack(alignment: .leading, spacing: 12) {
                // Title (or relative date fallback). When enrichment hasn't run,
                // we fall back to showing the date here as a less prominent heading.
                if let title = transcript.title, !title.isEmpty {
                    Text(title.uppercased())
                        .font(Brutal.label(.headline))
                        .foregroundColor(Brutal.text)
                        .lineLimit(2)
                }

                // Metadata row
                HStack(spacing: 6) {
                    Text(relativeDate(transcript.date))
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                    Text("·").font(Brutal.caption()).foregroundColor(Brutal.muted)
                    Text(transcript.modelUsed.uppercased())
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                    Text("·").font(Brutal.caption()).foregroundColor(Brutal.muted)
                    Text(formatDuration(transcript.duration).uppercased())
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                    if transcript.language != "auto" {
                        Text("·").font(Brutal.caption()).foregroundColor(Brutal.muted)
                        Text(transcript.language.uppercased())
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.muted)
                    }
                    if let category = transcript.category, !category.isEmpty {
                        Text("·").font(Brutal.caption()).foregroundColor(Brutal.muted)
                        Text(category.uppercased())
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.text)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))
                    }
                    Spacer()
                    copyMenu(for: transcript)
                }

                // Transcript body — prefer the cleaned version when available.
                Text(transcript.cleanedText ?? transcript.text)
                    .font(Brutal.body())
                    .foregroundColor(Brutal.text)
                    .lineSpacing(4)
                    .lineLimit(5)

                // Tag chips
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

    /// Offers "Copy cleaned" + "Copy raw" when both exist, otherwise a plain
    /// "COPY" button that copies whichever text is available.
    @ViewBuilder
    private func copyMenu(for transcript: Transcript) -> some View {
        if let cleaned = transcript.cleanedText, !cleaned.isEmpty {
            Menu {
                Button("Copy cleaned") { UIPasteboard.general.string = cleaned }
                Button("Copy raw") { UIPasteboard.general.string = transcript.text }
            } label: {
                Text("COPY")
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
            }
            .brutalHitTarget()
        } else {
            Button(action: { UIPasteboard.general.string = transcript.text }) {
                Text("COPY")
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .brutalHitTarget()
        }
    }

    // MARK: - Helpers

    private func relativeDate(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return String(localized: "just now") }
        if diff < 3600 { return String(format: String(localized: "%dm ago"), Int(diff / 60)) }
        if diff < 86400 { return String(format: String(localized: "%dh ago"), Int(diff / 3600)) }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: date)
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let s = Int(d)
        if s < 60 {
            return String(format: String(localized: "%ds"), s)
        } else {
            return String(format: String(localized: "%dm %ds"), s / 60, s % 60)
        }
    }
}
