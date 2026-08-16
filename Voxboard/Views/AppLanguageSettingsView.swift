import SwiftUI
import VoxboardShared

/// Pick the language Vox.md uses for its interface, independent of the
/// device language — for example English on a German phone. The selection is
/// applied on the next launch.
struct AppLanguageSettingsView: View {
    @State private var selection: AppLanguage = AppLanguagePreference.current()

    var body: some View {
        List {
            Section {
                systemRow

                ForEach(AppLanguage.allCases.filter { $0 != .system }) { language in
                    languageRow(language)
                }
            } footer: {
                Text("Language changes take effect the next time Vox.md is opened.")
            }
        }
        .navigationTitle("App Language")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Rows

    private var systemRow: some View {
        selectRow(
            title: Text("Use System Language"),
            caption: Text("Follows your device language"),
            language: .system
        )
    }

    private func languageRow(_ language: AppLanguage) -> some View {
        selectRow(
            title: Text(language.nativeDisplayName),
            caption: nil,
            language: language
        )
    }

    private func selectRow(
        title: Text,
        caption: Text?,
        language: AppLanguage
    ) -> some View {
        Button {
            select(language)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    title
                    if let caption {
                        caption
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if language == selection {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func select(_ language: AppLanguage) {
        guard language != selection else { return }
        selection = language
        AppLanguagePreference.set(language)
    }
}
