import SwiftUI

// MARK: - FilesTabView

/// Tab 3 — flow-scoped file export setup.
///
/// File export used to be configured globally from this tab. It now lives inside
/// each recording flow so users can route different flows to different note and
/// audio directories.
struct FilesTabView: View {
    var body: some View {
        ZStack {
            Brutal.surface.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    mainSection
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("FILES")
                    .font(Brutal.label(.headline))
                    .foregroundColor(Brutal.text)
            }
        }
        .toolbarBackground(Brutal.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func sectionHeader(_ number: String, _ title: LocalizedStringKey) -> some View {
        HStack {
            BrutalSectionLabel(number: number, title: title)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .background(Brutal.bg)
    }

    @ViewBuilder
    private var mainSection: some View {
        sectionHeader("00", "Vox's")
        BrutalDivider()
        NavigationLink {
            FlowSettingsView()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MANAGE VOX'S")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.text)
                    Text("Set export, template, note folder, and audio folder per Vox")
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Brutal.muted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Brutal.bg)
        }
        .buttonStyle(.plain)
        BrutalDivider()

        Text("Choose a Vox before recording. Voxboard saves the resulting note to that Vox's Export Directory, making it easy to keep meeting notes, journal entries, tasks, and other workflows in separate folders.")
            .font(Brutal.caption())
            .foregroundColor(Brutal.muted)
            .lineSpacing(3)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brutal.bg)

        sectionHeader("01", "Per-Vox Routing")
        BrutalDivider()
        infoRow(title: "EXPORT DIRECTORY", subtitle: "Required for a Vox to auto-save notes to Files or Obsidian.", symbol: "folder")
        BrutalDivider()
        infoRow(title: "AUDIO EXPORT DIRECTORY", subtitle: "Optional. If unset, saved audio stays next to the Vox's exported note.", symbol: "waveform")
        BrutalDivider()
        infoRow(title: "MARKDOWN TEMPLATE", subtitle: "Optional per-Vox template for custom note layouts.", symbol: "doc.text")
        BrutalDivider()
    }

    private func infoRow(title: LocalizedStringKey, subtitle: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Brutal.muted)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Brutal.label())
                    .foregroundColor(Brutal.text)
                Text(subtitle)
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
                    .lineSpacing(2)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Brutal.bg)
    }
}
