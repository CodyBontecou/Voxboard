import SwiftUI
import VoxboardShared

struct MacEntryTemplateLibraryView: View {
    @State private var templates: [CaptureEntryTemplate] = []
    @State private var templateToEdit: CaptureEntryTemplate?
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Entry Templates").font(Geist.heading(.title2))
                    Text("Reusable Markdown and YAML formatting for Capture Presets.")
                        .font(Geist.caption()).foregroundStyle(Geist.muted)
                }
                Spacer()
                Button("Add Template", systemImage: "plus") { isAdding = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(Geist.Spacing.four)
            GeistDivider()

            if templates.isEmpty {
                ContentUnavailableView(
                    "No Entry Templates",
                    systemImage: "doc.badge.plus",
                    description: Text("Create a template to reuse prefixes, frontmatter, and suffixes across Presets.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(templates) { template in
                        HStack(spacing: Geist.Spacing.three) {
                            Image(systemName: "doc.text")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name).font(Geist.label())
                                Text(templateSummary(template))
                                    .font(Geist.caption()).foregroundStyle(Geist.muted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Edit") { templateToEdit = template }
                            Button("Delete", role: .destructive) {
                                Task { await delete(template.id) }
                            }
                        }
                        .padding(.vertical, Geist.Spacing.two)
                    }
                }
            }

            if let errorMessage {
                GeistDivider()
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(Geist.caption()).foregroundStyle(Geist.error)
                    .padding(Geist.Spacing.three)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        .task { await load() }
        .sheet(isPresented: $isAdding) {
            MacEntryTemplateEditor(existing: nil, onSave: save)
        }
        .sheet(item: $templateToEdit) { template in
            MacEntryTemplateEditor(existing: template, onSave: save)
        }
    }

    private func templateSummary(_ template: CaptureEntryTemplate) -> String {
        let lineCount = (template.entryPrefix + template.entrySuffix)
            .split(separator: "\n", omittingEmptySubsequences: false).count
        return lineCount == 1
            ? String(localized: "1 formatting line")
            : String(localized: "\(lineCount) formatting lines")
    }

    private func store() throws -> CaptureLibraryStore {
        guard let url = AppConstants.captureLibraryURL else {
            throw MacEntryTemplateError.storageUnavailable
        }
        return CaptureLibraryStore(fileURL: url)
    }

    private func load() async {
        do {
            let library = try await CapturePresetRouteLibrary.load(from: store())
            templates = library.entryTemplates
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ template: CaptureEntryTemplate) async throws {
        let library = try await store().update { library in
            if let index = library.entryTemplates.firstIndex(where: { $0.id == template.id }) {
                library.entryTemplates[index] = template
            } else {
                library.entryTemplates.append(template)
            }
        }
        templates = library.entryTemplates
        errorMessage = nil
    }

    private func delete(_ id: UUID) async {
        do {
            let library = try await store().update { library in
                let removed = library.entryTemplates.first(where: { $0.id == id })
                for index in library.destinations.indices where library.destinations[index].entryTemplateID == id {
                    if let removed {
                        library.destinations[index].entryPrefix = removed.entryPrefix
                        library.destinations[index].entrySuffix = removed.entrySuffix
                    }
                    library.destinations[index].entryTemplateID = nil
                }
                library.entryTemplates.removeAll { $0.id == id }
            }
            CapturePresetStore.clearCaptureEntryTemplate(id)
            templates = library.entryTemplates
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MacEntryTemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    let existing: CaptureEntryTemplate?
    let onSave: (CaptureEntryTemplate) async throws -> Void

    @State private var name: String
    @State private var prefix: String
    @State private var suffix: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(existing: CaptureEntryTemplate?, onSave: @escaping (CaptureEntryTemplate) async throws -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _prefix = State(initialValue: existing?.entryPrefix ?? "")
        _suffix = State(initialValue: existing?.entrySuffix ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.four) {
            HStack {
                Text(existing == nil
                     ? String(localized: "Add Entry Template")
                     : String(localized: "Edit Entry Template"))
                    .font(Geist.heading(.title2))
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isSaving ? String(localized: "Saving…") : String(localized: "Save")) {
                    Task { await saveTemplate() }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
            TextField("Template Name", text: $name)
            Text("Prefix").font(Geist.label())
            TextEditor(text: $prefix).font(.body.monospaced()).frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Geist.border))
            Text("Suffix").font(Geist.label())
            TextEditor(text: $suffix).font(.body.monospaced()).frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Geist.border))
            Text("Tokens: {date}, {time}, {timestamp}, {year}, {YR} (2-digit year), {month}, {day}, {week}, {source}, {id8}, and {id}.")
                .font(Geist.caption()).foregroundStyle(Geist.muted)
            if let errorMessage {
                Text(errorMessage).font(Geist.caption()).foregroundStyle(Geist.error)
            }
        }
        .padding(Geist.Spacing.six)
        .frame(minWidth: 650, minHeight: 600)
        .background(Geist.Palette.background100)
    }

    private func saveTemplate() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = String(localized: "Enter a template name.")
            return
        }
        isSaving = true
        do {
            try await onSave(CaptureEntryTemplate(
                id: existing?.id ?? UUID(),
                name: trimmedName,
                entryPrefix: prefix,
                entrySuffix: suffix
            ))
            dismiss()
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }
}

private enum MacEntryTemplateError: LocalizedError {
    case storageUnavailable
    var errorDescription: String? { String(localized: "Shared Capture storage is unavailable.") }
}
