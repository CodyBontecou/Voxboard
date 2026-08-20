import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

struct CaptureEntryTemplateLibraryView: View {
    @State private var templates: [CaptureEntryTemplate] = []
    @State private var templateToEdit: CaptureEntryTemplate?
    @State private var isAdding = false
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if templates.isEmpty {
                ContentUnavailableView(
                    "No Entry Templates",
                    systemImage: "doc.badge.plus",
                    description: Text("Create reusable Markdown or YAML formatting for your Capture Presets.")
                )
            } else {
                ForEach(templates) { template in
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
                            Task { await delete(template.id) }
                        }
                    }
                }
            }

            Section {
                Button {
                    isAdding = true
                } label: {
                    Label("Add Entry Template", systemImage: "doc.badge.plus")
                }
                Button {
                    isImporting = true
                } label: {
                    Label("Import Markdown Template", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("Templates can contain multiline Markdown or YAML frontmatter. Tokens include {date}, {time}, {hour}, {minute}, {second}, {timestamp}, {source}, {id8}, and {location}.")
            }

            if let errorMessage {
                Section("Error") {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Entry Templates")
        .task { await load() }
        .sheet(isPresented: $isAdding) {
            NavigationStack {
                CaptureEntryTemplateEditorView(existing: nil) { template in
                    try await save(template)
                }
            }
        }
        .sheet(item: $templateToEdit) { template in
            NavigationStack {
                CaptureEntryTemplateEditorView(existing: template) { updated in
                    try await save(updated)
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.init(filenameExtension: "md") ?? .plainText],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            do {
                templateToEdit = try importedTemplate(from: url)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
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

    private func store() throws -> CaptureLibraryStore {
        guard let url = AppConstants.captureLibraryURL else {
            throw CaptureEntryTemplateLibraryError.storageUnavailable
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

private enum CaptureEntryTemplateLibraryError: Error, LocalizedError {
    case storageUnavailable

    var errorDescription: String? {
        "Shared capture storage is unavailable."
    }
}

struct CaptureDestinationEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private enum TargetKind: String, CaseIterable, Identifiable {
        case newNote
        case rollingNote
        case existingNote

        var id: String { rawValue }
        var label: String {
            switch self {
            case .newNote: return String(localized: "New Note")
            case .rollingNote: return String(localized: "Rolling Note")
            case .existingNote: return String(localized: "Existing Note")
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
            case .append: return String(localized: "Bottom")
            case .prepend: return String(localized: "Top")
            case .heading: return String(localized: "Heading")
            }
        }
    }

    let existing: CaptureDestination?
    let templates: [CaptureEntryTemplate]
    /// When set, the route is owned and named by a Capture Preset rather than
    /// presented as an independently named destination.
    let fixedName: String?
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
    @State private var markdownTemplatePath: String?
    @State private var entryPrefix: String
    @State private var entrySuffix: String
    @State private var attachmentsFolderName: String
    @State private var retryProtectionEnabled: Bool
    @State private var isChoosingFolder = false
    @State private var isChoosingExistingNote = false
    @State private var isChoosingMarkdownTemplate = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        existing: CaptureDestination?,
        templates: [CaptureEntryTemplate],
        fixedName: String? = nil,
        onSave: @escaping (CaptureDestination) async throws -> Void
    ) {
        self.existing = existing
        self.templates = templates
        self.fixedName = fixedName
        self.onSave = onSave
        _name = State(initialValue: fixedName ?? existing?.name ?? "")
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
        _selectedTemplateID = State(
            initialValue: existing?.markdownTemplatePath == nil ? selectedTemplateID : nil
        )
        _markdownTemplatePath = State(initialValue: existing?.markdownTemplatePath)
        _entryPrefix = State(initialValue: selectedTemplate?.entryPrefix ?? existing?.entryPrefix ?? "")
        _entrySuffix = State(initialValue: selectedTemplate?.entrySuffix ?? existing?.entrySuffix ?? "")
        _attachmentsFolderName = State(initialValue: existing?.attachmentsFolderName ?? "attachments")
        _retryProtectionEnabled = State(initialValue: existing?.retryProtectionEnabled ?? false)
    }

    var body: some View {
        Form {
            Section(fixedName == nil ? String(localized: "Identity") : String(localized: "Preset Destination")) {
                if let fixedName {
                    LabeledContent("Preset", value: fixedName)
                } else {
                    TextField("Destination Name (Optional)", text: $name)
                }
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
                if let markdownTemplatePath {
                    LabeledContent("Vault Template", value: markdownTemplatePath)
                    Button("Choose Another Template…") {
                        isChoosingMarkdownTemplate = true
                    }
                    Button("Remove Vault Template", role: .destructive) {
                        self.markdownTemplatePath = nil
                    }
                    Text("Vox.md reads this file from your vault for every capture, so edits made in Obsidian apply automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Vault templates support the same tokens, including {location}, which follows the delivering Capture Preset's location setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Choose Template from Vault…") {
                        isChoosingMarkdownTemplate = true
                    }
                    .disabled(rootBookmark.isEmpty)

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
                    Text("Multiline Markdown and YAML frontmatter are supported. Tokens: {date}, {time}, {hour}, {minute}, {second}, {timestamp}, {source}, {id8}, {location}.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let locationSample = CaptureEntryLocationTokenSupport.renderedSample(
                        prefix: entryPrefix,
                        suffix: entrySuffix
                    ) {
                        CaptureEntryLocationTokenPreview(sample: locationSample)
                    }
                }
                TextField("Attachments Folder", text: $attachmentsFolderName)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }

            Section("Delivery") {
                Toggle("Retry Protection", isOn: $retryProtectionEnabled)
                Text("Prevents duplicate entries when delivery is retried. This adds a vox-capture HTML comment to each captured entry, which may be visible while editing Markdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Section("Error") {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(
            fixedName == nil
                ? (existing == nil ? String(localized: "Add Destination") : String(localized: "Edit Destination"))
                : (existing == nil ? String(localized: "Set Up Destination") : String(localized: "Edit Destination"))
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? String(localized: "Saving…") : String(localized: "Save")) {
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
        .sheet(isPresented: $isChoosingMarkdownTemplate) {
            CaptureMarkdownNotePicker(
                initialDirectoryURL: resolvedRootURL,
                onPick: { url in
                    isChoosingMarkdownTemplate = false
                    chooseMarkdownTemplate(url)
                },
                onCancel: { isChoosingMarkdownTemplate = false }
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
        case .newNote: return String(localized: "Filename template")
        case .rollingNote: return String(localized: "Rolling path template")
        case .existingNote: return String(localized: "Existing note path")
        }
    }

    private var pathHelp: String {
        switch targetKind {
        case .newNote:
            return String(localized: "Tokens: {timestamp}, {date}, {time}, {hour}, {minute}, {second}, {year}, {YR} (2-digit year), {month}, {day}, {id8}, {id}. Existing filenames are automatically uniqued.")
        case .rollingNote:
            return String(localized: "Use {period} for the selected daily, weekly, monthly, quarterly, or yearly bucket. Tokens also include {date}, {hour}, {minute}, {second}, {year}, {YR} (2-digit year), {month}, {day}, and {week}.")
        case .existingNote:
            return String(localized: "Path relative to the selected vault or folder, for example Projects/Vox.md.")
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
            let rootAccess = rootURL.startAccessingSecurityScopedResource()
            defer { if rootAccess { rootURL.stopAccessingSecurityScopedResource() } }
            let relativePath: String
            do {
                relativePath = try CapturePathValidation.relativePath(
                    for: url,
                    containedIn: rootURL
                )
            } catch {
                throw DestinationEditorError.noteOutsideRoot
            }
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
            markdownTemplatePath = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rootBookmark.isEmpty else { throw DestinationEditorError.folderRequired }
            let ownedName = fixedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let destinationName = ownedName?.isEmpty == false
                ? ownedName!
                : (trimmedName.isEmpty ? rootName : trimmedName)
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
                if markdownTemplatePath == relativePath {
                    throw CaptureVaultMarkdownTemplateError.templateMatchesDestination(relativePath)
                }
            }
            if let markdownTemplatePath {
                try preflightMarkdownTemplate(relativePath: markdownTemplatePath)
            }

            isSaving = true
            try await onSave(CaptureDestination(
                id: existing?.id ?? UUID(),
                name: destinationName,
                rootBookmark: rootBookmark,
                rootName: rootName,
                noteTarget: target,
                placement: placement,
                entryPrefix: markdownTemplatePath == nil ? entryPrefix : "",
                entrySuffix: markdownTemplatePath == nil ? entrySuffix : "",
                entryTemplateID: markdownTemplatePath == nil ? selectedTemplateID : nil,
                markdownTemplatePath: markdownTemplatePath,
                attachmentsFolderName: attachmentsFolderName,
                retryProtectionEnabled: retryProtectionEnabled
            ))
            dismiss()
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }

    private func chooseMarkdownTemplate(_ url: URL) {
        let selectedAccess = url.startAccessingSecurityScopedResource()
        defer { if selectedAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let relativePath = try relativeMarkdownPath(
                for: url,
                outsideRootError: DestinationEditorError.templateOutsideRoot
            )
            try preflightMarkdownTemplate(relativePath: relativePath)
            markdownTemplatePath = relativePath
            selectedTemplateID = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func relativeMarkdownPath(
        for url: URL,
        outsideRootError: DestinationEditorError
    ) throws -> String {
        var isStale = false
        let rootURL = try URL(
            resolvingBookmarkData: rootBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ).standardizedFileURL
        guard !isStale else { throw DestinationEditorError.folderPermissionExpired }
        guard url.pathExtension.lowercased() == "md" else {
            throw DestinationEditorError.markdownTemplateRequired
        }
        let rootAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if rootAccess { rootURL.stopAccessingSecurityScopedResource() } }
        do {
            return try CapturePathValidation.relativePath(
                for: url,
                containedIn: rootURL
            )
        } catch {
            throw outsideRootError
        }
    }

    private func preflightMarkdownTemplate(relativePath: String) throws {
        var isStale = false
        let rootURL = try URL(
            resolvingBookmarkData: rootBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else { throw DestinationEditorError.folderPermissionExpired }
        let rootAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if rootAccess { rootURL.stopAccessingSecurityScopedResource() } }
        let templateURL = try CapturePathValidation.containedFileURL(
            relativePath: relativePath,
            rootURL: rootURL
        )
        guard FileManager.default.fileExists(atPath: templateURL.path) else {
            throw CaptureVaultMarkdownTemplateError.templateMissing(relativePath)
        }
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        guard template.count <= CaptureInputLimits.maximumTextCharacters else {
            throw CaptureVaultMarkdownTemplateError.templateTooLarge(
                path: relativePath,
                limit: CaptureInputLimits.maximumTextCharacters
            )
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
        let didAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if didAccess { rootURL.stopAccessingSecurityScopedResource() } }
        let noteURL = try CapturePathValidation.containedFileURL(
            relativePath: relativePath,
            rootURL: rootURL
        )
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

struct CaptureEntryTemplateEditorView: View {
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
                Text("Use multiline Markdown or a leading --- YAML frontmatter block. Available tokens: {date}, {time}, {hour}, {minute}, {second}, {timestamp}, {year}, {YR} (2-digit year), {month}, {day}, {week}, {source}, {id8}, {id}, {location}.")
            }
            if let locationSample = CaptureEntryLocationTokenSupport.renderedSample(
                prefix: entryPrefix,
                suffix: entrySuffix
            ) {
                Section {
                    CaptureEntryLocationTokenPreview(sample: locationSample)
                } header: {
                    Text("{location} token")
                }
            }
            if let errorMessage {
                Section("Error") { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(existing == nil ? String(localized: "Add Template") : String(localized: "Edit Template"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? String(localized: "Saving…") : String(localized: "Save")) {
                    Task { await save() }
                }
                .disabled(isSaving)
            }
        }
    }

    private func save() async {
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
    case folderRequired
    case headingRequired
    case existingNoteMissing(String)
    case folderPermissionExpired
    case noteOutsideRoot
    case templateOutsideRoot
    case markdownTemplateRequired

    var errorDescription: String? {
        switch self {
        case .folderRequired: return String(localized: "Choose a vault or folder.")
        case .headingRequired: return String(localized: "Enter the Markdown heading to capture beneath.")
        case .existingNoteMissing(let path): return String(localized: "The existing note ‘\(path)’ was not found in the selected vault or folder.")
        case .folderPermissionExpired: return String(localized: "The selected vault or folder permission expired. Choose it again.")
        case .noteOutsideRoot: return String(localized: "Choose a Markdown note inside the selected vault or folder.")
        case .templateOutsideRoot: return String(localized: "Choose a Markdown template inside the selected vault or folder.")
        case .markdownTemplateRequired: return String(localized: "Choose a Markdown (.md) template file.")
        }
    }
}
