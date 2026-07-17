import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

struct CaptureDestinationLibraryView: View {
    @Bindable var viewModel: QuickCaptureViewModel
    @State private var destinationToEdit: CaptureDestination?
    @State private var isAddingDestination = false
    @State private var templateToEdit: CaptureEntryTemplate?
    @State private var isAddingTemplate = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if viewModel.destinations.isEmpty {
                    ContentUnavailableView(
                        "No Destinations",
                        systemImage: "folder.badge.plus",
                        description: Text("Add an Obsidian vault or Files folder to start capturing.")
                    )
                } else {
                    ForEach(viewModel.destinations) { destination in
                        Button {
                            destinationToEdit = destination
                        } label: {
                            destinationRow(destination)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) {
                                Task { await delete(destination.id) }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if destination.id != viewModel.defaultDestinationID {
                                Button("Default") {
                                    Task { await setDefault(destination.id) }
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            } header: {
                Text("Reusable destinations")
            } footer: {
                Text("Each destination owns its vault folder, note target, placement, heading, and entry formatting.")
            }

            Section {
                Button {
                    isAddingDestination = true
                } label: {
                    Label("Add Destination", systemImage: "plus")
                }
            }

            Section {
                ForEach(viewModel.entryTemplates) { template in
                    Button {
                        templateToEdit = template
                    } label: {
                        HStack {
                            Image(systemName: "doc.text")
                            Text(template.name)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            Task { await deleteTemplate(template.id) }
                        }
                    }
                }
                Button {
                    isAddingTemplate = true
                } label: {
                    Label("Add Entry Template", systemImage: "doc.badge.plus")
                }
            } header: {
                Text("Reusable entry templates")
            } footer: {
                Text("Templates can contain multiline Markdown or YAML frontmatter. Tokens: {date}, {time}, {timestamp}, {source}, {id8}.")
            }

            if let errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Destinations")
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isAddingDestination) {
            NavigationStack {
                CaptureDestinationEditorView(existing: nil, templates: viewModel.entryTemplates) { destination in
                    try await viewModel.upsertDestination(destination)
                }
            }
        }
        .sheet(item: $destinationToEdit) { destination in
            NavigationStack {
                CaptureDestinationEditorView(existing: destination, templates: viewModel.entryTemplates) { updated in
                    try await viewModel.upsertDestination(updated)
                }
            }
        }
        .sheet(isPresented: $isAddingTemplate) {
            NavigationStack {
                CaptureEntryTemplateEditorView(existing: nil) { template in
                    try await viewModel.upsertEntryTemplate(template)
                }
            }
        }
        .sheet(item: $templateToEdit) { template in
            NavigationStack {
                CaptureEntryTemplateEditorView(existing: template) { updated in
                    try await viewModel.upsertEntryTemplate(updated)
                }
            }
        }
    }

    private func destinationRow(_ destination: CaptureDestination) -> some View {
        HStack(spacing: 12) {
            Image(systemName: destination.id == viewModel.defaultDestinationID ? "star.fill" : "folder")
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(destination.name)
                    .foregroundStyle(.primary)
                Text(destination.rootName + " · " + targetSummary(destination.noteTarget))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func targetSummary(_ target: CaptureNoteTarget) -> String {
        switch target {
        case .newNote(let template): return template
        case .rollingNote(let template, _): return template
        case .existingNote(let path): return path
        }
    }

    private func delete(_ id: UUID) async {
        do {
            try await viewModel.deleteDestination(id: id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteTemplate(_ id: UUID) async {
        do {
            try await viewModel.deleteEntryTemplate(id: id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setDefault(_ id: UUID) async {
        do {
            try await viewModel.setDefaultDestination(id: id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CaptureDestinationEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private enum TargetKind: String, CaseIterable, Identifiable {
        case newNote
        case rollingNote
        case existingNote

        var id: String { rawValue }
        var label: String {
            switch self {
            case .newNote: return "New Note"
            case .rollingNote: return "Rolling Note"
            case .existingNote: return "Existing Note"
            }
        }
    }

    private enum PlacementKind: String, CaseIterable, Identifiable {
        case append
        case prepend
        case heading

        var id: String { rawValue }
        var label: String {
            switch self {
            case .append: return "Bottom"
            case .prepend: return "Top"
            case .heading: return "Heading"
            }
        }
    }

    let existing: CaptureDestination?
    let templates: [CaptureEntryTemplate]
    let onSave: (CaptureDestination) async throws -> Void

    @State private var name: String
    @State private var rootBookmark: Data
    @State private var rootName: String
    @State private var targetKind: TargetKind
    @State private var pathTemplate: String
    @State private var rollingPeriod: CaptureRollingPeriod
    @State private var placementKind: PlacementKind
    @State private var headingTitle: String
    @State private var headingLevel: Int
    @State private var missingHeadingBehavior: CaptureMissingHeadingBehavior
    @State private var selectedTemplateID: UUID?
    @State private var entryPrefix: String
    @State private var entrySuffix: String
    @State private var attachmentsFolderName: String
    @State private var isChoosingFolder = false
    @State private var isChoosingExistingNote = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        existing: CaptureDestination?,
        templates: [CaptureEntryTemplate],
        onSave: @escaping (CaptureDestination) async throws -> Void
    ) {
        self.existing = existing
        self.templates = templates
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _rootBookmark = State(initialValue: existing?.rootBookmark ?? Data())
        _rootName = State(initialValue: existing?.rootName ?? "")

        switch existing?.noteTarget {
        case .newNote(let template):
            _targetKind = State(initialValue: .newNote)
            _pathTemplate = State(initialValue: template)
            _rollingPeriod = State(initialValue: .daily)
        case .rollingNote(let template, let period):
            _targetKind = State(initialValue: .rollingNote)
            _pathTemplate = State(initialValue: template)
            _rollingPeriod = State(initialValue: period)
        case .existingNote(let path):
            _targetKind = State(initialValue: .existingNote)
            _pathTemplate = State(initialValue: path)
            _rollingPeriod = State(initialValue: .daily)
        case nil:
            _targetKind = State(initialValue: .rollingNote)
            _pathTemplate = State(initialValue: "Journal/{period}.md")
            _rollingPeriod = State(initialValue: .daily)
        }

        switch existing?.placement {
        case .append:
            _placementKind = State(initialValue: .append)
            _headingTitle = State(initialValue: "")
            _headingLevel = State(initialValue: 2)
            _missingHeadingBehavior = State(initialValue: .fail)
        case .prepend:
            _placementKind = State(initialValue: .prepend)
            _headingTitle = State(initialValue: "")
            _headingLevel = State(initialValue: 2)
            _missingHeadingBehavior = State(initialValue: .fail)
        case .beneathHeading(let selector, let behavior):
            _placementKind = State(initialValue: .heading)
            _headingTitle = State(initialValue: selector.title)
            _headingLevel = State(initialValue: selector.level ?? 2)
            _missingHeadingBehavior = State(initialValue: behavior)
        case nil:
            _placementKind = State(initialValue: .append)
            _headingTitle = State(initialValue: "")
            _headingLevel = State(initialValue: 2)
            _missingHeadingBehavior = State(initialValue: .fail)
        }

        let selectedTemplateID = existing?.entryTemplateID ?? templates.first(where: {
            $0.entryPrefix == existing?.entryPrefix && $0.entrySuffix == existing?.entrySuffix
        })?.id
        let selectedTemplate = templates.first { $0.id == selectedTemplateID }
        _selectedTemplateID = State(initialValue: selectedTemplateID)
        _entryPrefix = State(initialValue: selectedTemplate?.entryPrefix ?? existing?.entryPrefix ?? "")
        _entrySuffix = State(initialValue: selectedTemplate?.entrySuffix ?? existing?.entrySuffix ?? "")
        _attachmentsFolderName = State(initialValue: existing?.attachmentsFolderName ?? "attachments")
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Destination Name", text: $name)
                Button {
                    isChoosingFolder = true
                } label: {
                    HStack {
                        Text("Vault / Folder")
                        Spacer()
                        Text(rootName.isEmpty ? "Choose…" : rootName)
                            .foregroundStyle(.secondary)
                        Image(systemName: "folder")
                    }
                }
            }

            Section("Note Target") {
                Picker("Target", selection: $targetKind) {
                    ForEach(TargetKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                TextField(pathFieldTitle, text: $pathTemplate)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                if targetKind == .existingNote {
                    Button("Choose Existing Note…") {
                        isChoosingExistingNote = true
                    }
                    .disabled(rootBookmark.isEmpty)
                }

                if targetKind == .rollingNote {
                    Picker("Period", selection: $rollingPeriod) {
                        ForEach(CaptureRollingPeriod.allCases, id: \.self) { period in
                            Text(period.rawValue.capitalized).tag(period)
                        }
                    }
                }

                Text(pathHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Placement") {
                Picker("Insert", selection: $placementKind) {
                    ForEach(PlacementKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                if placementKind == .heading {
                    TextField("Heading title", text: $headingTitle)
                    Stepper("Heading level: \(headingLevel)", value: $headingLevel, in: 1...6)
                    Picker("If missing", selection: $missingHeadingBehavior) {
                        Text("Show Error").tag(CaptureMissingHeadingBehavior.fail)
                        Text("Create Heading").tag(CaptureMissingHeadingBehavior.create)
                    }
                }
            }

            Section("Entry Formatting") {
                if !templates.isEmpty {
                    Picker("Reusable Template", selection: $selectedTemplateID) {
                        Text("Custom").tag(UUID?.none)
                        ForEach(templates) { template in
                            Text(template.name).tag(Optional(template.id))
                        }
                    }
                    .onChange(of: selectedTemplateID) { _, id in
                        guard let template = templates.first(where: { $0.id == id }) else { return }
                        entryPrefix = template.entryPrefix
                        entrySuffix = template.entrySuffix
                    }
                }
                Text("Prefix").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $entryPrefix)
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
                    .disabled(selectedTemplateID != nil)
                    .accessibilityLabel("Entry prefix")
                Text("Suffix").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $entrySuffix)
                    .font(.body.monospaced())
                    .frame(minHeight: 70)
                    .disabled(selectedTemplateID != nil)
                    .accessibilityLabel("Entry suffix")
                if selectedTemplateID != nil {
                    Text("This destination stays linked to the reusable template. Choose Custom to edit a private snapshot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Multiline Markdown and YAML frontmatter are supported. Tokens: {date}, {time}, {timestamp}, {source}, {id8}.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Attachments Folder", text: $attachmentsFolderName)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }

            if let errorMessage {
                Section("Error") {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(existing == nil ? "Add Destination" : "Edit Destination")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save") {
                    Task { await save() }
                }
                .disabled(isSaving)
            }
        }
        .sheet(isPresented: $isChoosingFolder) {
            CaptureFolderPicker(
                initialDirectoryURL: resolvedRootURL,
                onPick: { url in
                    isChoosingFolder = false
                    saveFolderBookmark(url)
                },
                onCancel: { isChoosingFolder = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isChoosingExistingNote) {
            CaptureMarkdownNotePicker(
                initialDirectoryURL: resolvedRootURL,
                onPick: { url in
                    isChoosingExistingNote = false
                    chooseExistingNote(url)
                },
                onCancel: { isChoosingExistingNote = false }
            )
            .ignoresSafeArea()
        }
    }

    private var resolvedRootURL: URL? {
        guard !rootBookmark.isEmpty else { return nil }
        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: rootBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return isStale ? nil : url
    }

    private var pathFieldTitle: String {
        switch targetKind {
        case .newNote: return "Filename template"
        case .rollingNote: return "Rolling path template"
        case .existingNote: return "Existing note path"
        }
    }

    private var pathHelp: String {
        switch targetKind {
        case .newNote:
            return "Tokens: {timestamp}, {date}, {time}, {id8}, {id}. Existing filenames are automatically uniqued."
        case .rollingNote:
            return "Use {period} for the selected daily, weekly, monthly, quarterly, or yearly bucket. Tokens also include {date}, {year}, {month}, {day}, and {week}."
        case .existingNote:
            return "Path relative to the selected vault or folder, for example Projects/Vox.md."
        }
    }

    private func chooseExistingNote(_ url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            var isStale = false
            let rootURL = try URL(
                resolvingBookmarkData: rootBookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL
            guard !isStale else { throw DestinationEditorError.folderPermissionExpired }
            let selectedURL = url.standardizedFileURL
            let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            guard selectedURL.path.hasPrefix(rootPrefix) else {
                throw DestinationEditorError.noteOutsideRoot
            }
            let relativePath = String(selectedURL.path.dropFirst(rootPrefix.count))
            try CapturePathValidation.validateRelativePath(relativePath)
            pathTemplate = relativePath
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveFolderBookmark(_ url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            rootBookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            rootName = url.lastPathComponent
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { throw DestinationEditorError.nameRequired }
            guard !rootBookmark.isEmpty else { throw DestinationEditorError.folderRequired }
            let trimmedPath = pathTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            try CapturePathValidation.validateRelativePath(trimmedPath)
            if !attachmentsFolderName.isEmpty {
                try CapturePathValidation.validateRelativePath(attachmentsFolderName)
            }

            let target: CaptureNoteTarget
            switch targetKind {
            case .newNote:
                target = .newNote(pathTemplate: trimmedPath)
            case .rollingNote:
                target = .rollingNote(pathTemplate: trimmedPath, period: rollingPeriod)
            case .existingNote:
                target = .existingNote(relativePath: trimmedPath)
            }

            let placement: CapturePlacement
            switch placementKind {
            case .append:
                placement = .append
            case .prepend:
                placement = .prepend
            case .heading:
                let title = headingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { throw DestinationEditorError.headingRequired }
                placement = .beneathHeading(
                    CaptureHeadingSelector(title: title, level: headingLevel),
                    missingHeadingBehavior: missingHeadingBehavior
                )
            }

            if case .existingNote(let relativePath) = target {
                try preflightExistingNote(relativePath: relativePath, placement: placement)
            }

            isSaving = true
            try await onSave(CaptureDestination(
                id: existing?.id ?? UUID(),
                name: trimmedName,
                rootBookmark: rootBookmark,
                rootName: rootName,
                noteTarget: target,
                placement: placement,
                entryPrefix: entryPrefix,
                entrySuffix: entrySuffix,
                entryTemplateID: selectedTemplateID,
                attachmentsFolderName: attachmentsFolderName
            ))
            dismiss()
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }

    private func preflightExistingNote(
        relativePath: String,
        placement: CapturePlacement
    ) throws {
        var isStale = false
        let rootURL = try URL(
            resolvingBookmarkData: rootBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else { throw DestinationEditorError.folderPermissionExpired }
        let noteURL = try CapturePathValidation.containedFileURL(
            relativePath: relativePath,
            rootURL: rootURL
        )
        let didAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if didAccess { rootURL.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: noteURL.path) else {
            throw DestinationEditorError.existingNoteMissing(relativePath)
        }
        let markdown = try String(contentsOf: noteURL, encoding: .utf8)
        _ = try MarkdownDocumentEditor().applying(
            MarkdownCaptureMutation(
                requestID: UUID(),
                entry: "Vox.md route preflight",
                placement: placement
            ),
            to: markdown
        )
    }
}

private struct CaptureEntryTemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let existing: CaptureEntryTemplate?
    let onSave: (CaptureEntryTemplate) async throws -> Void

    @State private var name: String
    @State private var entryPrefix: String
    @State private var entrySuffix: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        existing: CaptureEntryTemplate?,
        onSave: @escaping (CaptureEntryTemplate) async throws -> Void
    ) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _entryPrefix = State(initialValue: existing?.entryPrefix ?? "")
        _entrySuffix = State(initialValue: existing?.entrySuffix ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                Text("Prefix").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $entryPrefix)
                    .font(.body.monospaced())
                    .frame(minHeight: 150)
                    .accessibilityLabel("Template prefix")
                Text("Suffix").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $entrySuffix)
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                    .accessibilityLabel("Template suffix")
            } header: {
                Text("Template")
            } footer: {
                Text("Use multiline Markdown or a leading --- YAML frontmatter block. Available tokens: {date}, {time}, {timestamp}, {year}, {month}, {day}, {week}, {source}, {id8}, {id}.")
            }
            if let errorMessage {
                Section("Error") { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(existing == nil ? "Add Template" : "Edit Template")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save") {
                    Task { await save() }
                }
                .disabled(isSaving)
            }
        }
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Enter a template name."
            return
        }
        isSaving = true
        do {
            try await onSave(CaptureEntryTemplate(
                id: existing?.id ?? UUID(),
                name: trimmedName,
                entryPrefix: entryPrefix,
                entrySuffix: entrySuffix
            ))
            dismiss()
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }
}

private enum DestinationEditorError: Error, LocalizedError {
    case nameRequired
    case folderRequired
    case headingRequired
    case existingNoteMissing(String)
    case folderPermissionExpired
    case noteOutsideRoot

    var errorDescription: String? {
        switch self {
        case .nameRequired: return "Enter a destination name."
        case .folderRequired: return "Choose a vault or folder."
        case .headingRequired: return "Enter the Markdown heading to capture beneath."
        case .existingNoteMissing(let path): return "The existing note ‘\(path)’ was not found in the selected vault or folder."
        case .folderPermissionExpired: return "The selected vault or folder permission expired. Choose it again."
        case .noteOutsideRoot: return "Choose a Markdown note inside the selected vault or folder."
        }
    }
}
