import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

struct MacEntryTemplateLibraryView: View {
    @State private var templates: [CaptureEntryTemplate] = []
    @State private var drafts: [CaptureEntryTemplate] = []
    @State private var selectedTemplateID: UUID?
    @State private var pendingDeletion: CaptureEntryTemplate?
    @State private var editorRevision = 0
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            templateList
                .frame(width: 280)
            GeistDivider().frame(width: 1)
            templateDetail
        }
        .background(Geist.surface)
        .navigationTitle("Entry Templates")
        .task { await load() }
        .alert(
            "Delete Entry Template?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                guard let template = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await delete(template.id) }
            }
        } message: {
            Text("Destinations using this template will keep its current prefix and suffix as inline formatting.")
        }
    }

    private var templateList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ENTRY TEMPLATES")
                    .font(Geist.label())
                    .foregroundColor(Geist.text)
                Spacer()
                Button {
                    importTemplate()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .help("Import Markdown")
                .accessibilityLabel("Import Markdown")
                Button {
                    addTemplate()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add Template")
                .accessibilityLabel("Add Template")
            }
            .padding(16)
            GeistDivider()

            List(selection: $selectedTemplateID) {
                ForEach(drafts) { template in
                    templateRow(template, isDraft: true)
                        .tag(template.id)
                }
                ForEach(templates) { template in
                    templateRow(template, isDraft: false)
                        .tag(template.id)
                }
            }
            .listStyle(.sidebar)

            if let errorMessage {
                GeistDivider()
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(Geist.caption())
                    .foregroundStyle(Geist.error)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Geist.surface)
    }

    @ViewBuilder
    private var templateDetail: some View {
        if let template = selectedTemplate {
            let isDraft = drafts.contains(where: { $0.id == template.id })
            MacEntryTemplateEditor(
                template: template,
                isDraft: isDraft,
                onSave: save,
                onDiscardDraft: {
                    discardDraft(template.id)
                },
                onDelete: {
                    pendingDeletion = template
                }
            )
            .id(EditorIdentity(templateID: template.id, revision: editorRevision))
        } else {
            ContentUnavailableView(
                templates.isEmpty ? "No Entry Templates" : "Select an Entry Template",
                systemImage: "doc.badge.plus",
                description: Text("Create or select a template to edit its reusable Markdown formatting.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedTemplate: CaptureEntryTemplate? {
        guard let selectedTemplateID else { return nil }
        return drafts.first(where: { $0.id == selectedTemplateID })
            ?? templates.first(where: { $0.id == selectedTemplateID })
    }

    private func templateRow(_ template: CaptureEntryTemplate, isDraft: Bool) -> some View {
        HStack(spacing: Geist.Spacing.three) {
            Image(systemName: isDraft ? "doc.badge.plus" : "doc.text")
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name.isEmpty ? String(localized: "New Template") : template.name)
                    .font(Geist.label())
                Text(isDraft ? String(localized: "Unsaved") : templateSummary(template))
                    .font(Geist.caption())
                    .foregroundStyle(Geist.muted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, Geist.Spacing.two)
    }

    private func addTemplate() {
        let template = CaptureEntryTemplate(name: "")
        drafts.append(template)
        selectedTemplateID = template.id
        errorMessage = nil
    }

    private func discardDraft(_ id: UUID) {
        drafts.removeAll { $0.id == id }
        selectedTemplateID = templates.first?.id ?? drafts.first?.id
    }

    private func importTemplate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let template = try importedTemplate(from: url)
            drafts.append(template)
            selectedTemplateID = template.id
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importedTemplate(from url: URL) throws -> CaptureEntryTemplate {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let path = url.lastPathComponent
        guard url.pathExtension.lowercased() == "md" else {
            throw CaptureVaultMarkdownTemplateError.markdownFileRequired(path)
        }
        let data = try Data(contentsOf: url)
        let characterLimit = CaptureInputLimits.maximumTextCharacters
        guard data.count <= characterLimit * 4 else {
            throw CaptureVaultMarkdownTemplateError.templateTooLarge(
                path: path,
                limit: characterLimit
            )
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            throw CaptureVaultMarkdownTemplateError.invalidUTF8(path)
        }
        guard contents.count <= characterLimit else {
            throw CaptureVaultMarkdownTemplateError.templateTooLarge(
                path: path,
                limit: characterLimit
            )
        }

        let name = url.deletingPathExtension().lastPathComponent
        return CaptureEntryTemplate(
            name: name.isEmpty ? String(localized: "Imported Template") : name,
            entryPrefix: contents
        )
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
            if let selectedTemplateID,
               !drafts.contains(where: { $0.id == selectedTemplateID }),
               !templates.contains(where: { $0.id == selectedTemplateID }) {
                self.selectedTemplateID = nil
            }
            if selectedTemplateID == nil {
                selectedTemplateID = drafts.first?.id ?? templates.first?.id
            }
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
        drafts.removeAll { $0.id == template.id }
        selectedTemplateID = template.id
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
            selectedTemplateID = templates.first?.id ?? drafts.first?.id
            editorRevision += 1
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private struct EditorIdentity: Hashable {
        let templateID: UUID
        let revision: Int
    }
}

private struct MacEntryTemplateEditor: View {
    let template: CaptureEntryTemplate
    let isDraft: Bool
    let onSave: (CaptureEntryTemplate) async throws -> Void
    let onDiscardDraft: () -> Void
    let onDelete: () -> Void

    @State private var name: String
    @State private var prefix: String
    @State private var suffix: String
    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    init(
        template: CaptureEntryTemplate,
        isDraft: Bool,
        onSave: @escaping (CaptureEntryTemplate) async throws -> Void,
        onDiscardDraft: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.template = template
        self.isDraft = isDraft
        self.onSave = onSave
        self.onDiscardDraft = onDiscardDraft
        self.onDelete = onDelete
        _name = State(initialValue: template.name)
        _prefix = State(initialValue: template.entryPrefix)
        _suffix = State(initialValue: template.entrySuffix)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Geist.Spacing.four) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isDraft ? String(localized: "New Entry Template") : template.name)
                            .font(Geist.heading(.title2))
                        Text("Reusable Markdown and YAML formatting for Capture Presets.")
                            .font(Geist.caption())
                            .foregroundStyle(Geist.muted)
                    }
                    Spacer()
                    if isDraft {
                        Button("Discard Draft", role: .destructive, action: onDiscardDraft)
                    } else {
                        Button("Delete", role: .destructive, action: onDelete)
                    }
                    Button(isSaving ? String(localized: "Saving…") : String(localized: "Save")) {
                        Task { await saveTemplate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }

                TextField("Template Name", text: $name)
                Text("Prefix").font(Geist.label())
                TextEditor(text: $prefix)
                    .font(.body.monospaced())
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Geist.border))
                Text("Suffix").font(Geist.label())
                TextEditor(text: $suffix)
                    .font(.body.monospaced())
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Geist.border))
                Text("Tokens: {date}, {time}, {hour}, {minute}, {second}, {timestamp}, {year}, {YR} (2-digit year), {month}, {day}, {week}, {source}, {id8}, {id}, and {location}.")
                    .font(Geist.caption())
                    .foregroundStyle(Geist.muted)
                if let locationSample = CaptureEntryLocationTokenSupport.renderedSample(
                    prefix: prefix,
                    suffix: suffix
                ) {
                    CaptureEntryLocationTokenPreview(sample: locationSample)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(Geist.caption())
                        .foregroundStyle(Geist.error)
                } else if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .font(Geist.caption())
                        .foregroundStyle(Geist.muted)
                }
            }
            .padding(Geist.Spacing.six)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Geist.Palette.background100)
    }

    private func saveTemplate() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            statusMessage = nil
            errorMessage = String(localized: "Enter a template name.")
            return
        }
        isSaving = true
        statusMessage = nil
        errorMessage = nil
        do {
            try await onSave(CaptureEntryTemplate(
                id: template.id,
                name: trimmedName,
                entryPrefix: prefix,
                entrySuffix: suffix
            ))
            isSaving = false
            statusMessage = String(localized: "Saved")
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
