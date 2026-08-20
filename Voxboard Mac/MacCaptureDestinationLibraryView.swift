import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

struct MacCaptureDestinationEditor: View {
    private enum TargetKind: String, CaseIterable, Identifiable {
        case newNote, rollingNote, existingNote
        var id: String { rawValue }
        var title: String {
            switch self {
            case .newNote: "New Note"
            case .rollingNote: "Rolling"
            case .existingNote: "Existing"
            }
        }
    }

    private enum PlacementKind: String, CaseIterable, Identifiable {
        case append, prepend, heading
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @Environment(\.dismiss) private var dismiss
    let existing: CaptureDestination?
    let templates: [CaptureEntryTemplate]
    let fixedName: String?
    let onSave: (CaptureDestination) async throws -> Void

    @State private var name: String
    @State private var rootBookmark: Data
    @State private var rootName: String
    @State private var targetKind: TargetKind
    @State private var path: String
    @State private var period: CaptureRollingPeriod
    @State private var placementKind: PlacementKind
    @State private var heading: String
    @State private var headingLevel: Int
    @State private var missingHeadingBehavior: CaptureMissingHeadingBehavior
    @State private var templateID: UUID?
    @State private var markdownTemplatePath: String?
    @State private var prefix: String
    @State private var suffix: String
    @State private var attachmentsFolder: String
    @State private var retryProtectionEnabled: Bool
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
        case .newNote(let value):
            _targetKind = State(initialValue: .newNote); _path = State(initialValue: value); _period = State(initialValue: .daily)
        case .rollingNote(let value, let valuePeriod):
            _targetKind = State(initialValue: .rollingNote); _path = State(initialValue: value); _period = State(initialValue: valuePeriod)
        case .existingNote(let value):
            _targetKind = State(initialValue: .existingNote); _path = State(initialValue: value); _period = State(initialValue: .daily)
        case nil:
            _targetKind = State(initialValue: .rollingNote); _path = State(initialValue: "Journal/{period}.md"); _period = State(initialValue: .daily)
        }
        switch existing?.placement {
        case .prepend:
            _placementKind = State(initialValue: .prepend); _heading = State(initialValue: ""); _headingLevel = State(initialValue: 2); _missingHeadingBehavior = State(initialValue: .fail)
        case .beneathHeading(let selector, let behavior):
            _placementKind = State(initialValue: .heading); _heading = State(initialValue: selector.title); _headingLevel = State(initialValue: selector.level ?? 2); _missingHeadingBehavior = State(initialValue: behavior)
        default:
            _placementKind = State(initialValue: .append); _heading = State(initialValue: ""); _headingLevel = State(initialValue: 2); _missingHeadingBehavior = State(initialValue: .fail)
        }
        let boundID = existing?.entryTemplateID
        let bound = templates.first { $0.id == boundID }
        _templateID = State(initialValue: existing?.markdownTemplatePath == nil ? boundID : nil)
        _markdownTemplatePath = State(initialValue: existing?.markdownTemplatePath)
        _prefix = State(initialValue: bound?.entryPrefix ?? existing?.entryPrefix ?? "")
        _suffix = State(initialValue: bound?.entrySuffix ?? existing?.entrySuffix ?? "")
        _attachmentsFolder = State(initialValue: existing?.attachmentsFolderName ?? "attachments")
        _retryProtectionEnabled = State(initialValue: existing?.retryProtectionEnabled ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(fixedName == nil ? String(localized: "Identity") : String(localized: "Preset Destination")) {
                    if let fixedName {
                        LabeledContent("Preset", value: fixedName)
                    } else {
                        TextField("Destination Name (Optional)", text: $name)
                    }
                    Button { chooseFolder() } label: {
                        LabeledContent("Vault / Folder", value: rootName.isEmpty ? "Choose…" : rootName)
                    }
                }
                Section("Note Target") {
                    Picker("Target", selection: $targetKind) {
                        ForEach(TargetKind.allCases) { Text($0.title).tag($0) }
                    }
                    TextField(targetKind == .existingNote
                              ? String(localized: "Relative Note Path")
                              : String(localized: "Path Template"), text: $path)
                    if targetKind == .existingNote {
                        Button("Choose Existing Note…") { chooseExistingNote() }
                            .disabled(rootBookmark.isEmpty)
                    }
                    if targetKind == .rollingNote {
                        Picker("Period", selection: $period) {
                            ForEach(CaptureRollingPeriod.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                    }
                    Text("Path tokens include {date}, {time}, {hour}, {minute}, {second}, {timestamp}, {year}, {YR} (2-digit year), {month}, {day}, {period}, {week}, and {id8}.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Placement") {
                    Picker("Insert", selection: $placementKind) {
                        ForEach(PlacementKind.allCases) { Text($0.title).tag($0) }
                    }
                    if placementKind == .heading {
                        TextField("Heading", text: $heading)
                        Stepper("Heading level: \(headingLevel)", value: $headingLevel, in: 1...6)
                        Picker("If Missing", selection: $missingHeadingBehavior) {
                            Text("Show Error").tag(CaptureMissingHeadingBehavior.fail)
                            Text("Create Heading").tag(CaptureMissingHeadingBehavior.create)
                        }
                    }
                }
                Section("Entry Formatting") {
                    if let markdownTemplatePath {
                        LabeledContent("Vault Template", value: markdownTemplatePath)
                        Button("Choose Another Template…") { chooseMarkdownTemplate() }
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
                        Button("Choose Template from Vault…") { chooseMarkdownTemplate() }
                            .disabled(rootBookmark.isEmpty)
                        if !templates.isEmpty {
                            Picker("Reusable Template", selection: $templateID) {
                                Text("Custom").tag(UUID?.none)
                                ForEach(templates) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .onChange(of: templateID) { _, id in
                                guard let template = templates.first(where: { $0.id == id }) else { return }
                                prefix = template.entryPrefix; suffix = template.entrySuffix
                            }
                        }
                        Text("Prefix").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $prefix).frame(minHeight: 80).disabled(templateID != nil)
                        Text("Suffix").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $suffix).frame(minHeight: 60).disabled(templateID != nil)
                        if let locationSample = CaptureEntryLocationTokenSupport.renderedSample(
                            prefix: prefix,
                            suffix: suffix
                        ) {
                            CaptureEntryLocationTokenPreview(sample: locationSample)
                        }
                    }
                    Text("Tokens: {date}, {time}, {hour}, {minute}, {second}, {timestamp}, {year}, {YR} (2-digit year), {month}, {day}, {week}, {source}, {id8}, {id}, and {location}.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Attachments Folder", text: $attachmentsFolder)
                }
                Section("Delivery") {
                    Toggle("Retry Protection", isOn: $retryProtectionEnabled)
                    Text("Prevents duplicate entries when delivery is retried. This adds a vox-capture HTML comment to each captured entry, which may be visible while editing Markdown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil
                             ? String(localized: "Set Up Destination")
                             : String(localized: "Edit Destination"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? String(localized: "Saving…") : String(localized: "Save")) {
                        Task { await save() }
                    }.disabled(isSaving)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 620)
    }

    private func chooseExistingNote() {
        do {
            let resolution = try CaptureBookmarkResolver.resolve(rootBookmark)
            let rootURL = resolution.url.standardizedFileURL
            guard !resolution.isStale else { throw MacCaptureRouteError.folderPermissionExpired }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
            panel.directoryURL = rootURL
            panel.prompt = String(localized: "Choose Note")
            guard panel.runModal() == .OK, let selectedURL = panel.url?.standardizedFileURL else { return }
            let rootAccess = rootURL.startAccessingSecurityScopedResource()
            let selectedAccess = selectedURL.startAccessingSecurityScopedResource()
            defer {
                if selectedAccess { selectedURL.stopAccessingSecurityScopedResource() }
                if rootAccess { rootURL.stopAccessingSecurityScopedResource() }
            }
            let relativePath: String
            do {
                relativePath = try CapturePathValidation.relativePath(
                    for: selectedURL,
                    containedIn: rootURL
                )
            } catch {
                throw MacCaptureRouteError.noteOutsideRoot
            }
            path = relativePath
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            rootBookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            rootName = url.lastPathComponent
            markdownTemplatePath = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseMarkdownTemplate() {
        do {
            let resolution = try CaptureBookmarkResolver.resolve(rootBookmark)
            let rootURL = resolution.url.standardizedFileURL
            guard !resolution.isStale else { throw MacCaptureRouteError.folderPermissionExpired }
            let rootAccess = rootURL.startAccessingSecurityScopedResource()
            defer { if rootAccess { rootURL.stopAccessingSecurityScopedResource() } }

            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.directoryURL = rootURL
            panel.prompt = String(localized: "Choose Template")
            guard panel.runModal() == .OK, let selectedURL = panel.url?.standardizedFileURL else { return }
            guard selectedURL.pathExtension.lowercased() == "md" else {
                throw MacCaptureRouteError.markdownTemplateRequired
            }
            let selectedAccess = selectedURL.startAccessingSecurityScopedResource()
            defer { if selectedAccess { selectedURL.stopAccessingSecurityScopedResource() } }
            let relativePath: String
            do {
                relativePath = try CapturePathValidation.relativePath(
                    for: selectedURL,
                    containedIn: rootURL
                )
            } catch {
                throw MacCaptureRouteError.templateOutsideRoot
            }
            try preflightMarkdownTemplate(relativePath: relativePath)
            markdownTemplatePath = relativePath
            templateID = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func preflightMarkdownTemplate(relativePath: String) throws {
        let resolution = try CaptureBookmarkResolver.resolve(rootBookmark)
        let rootURL = resolution.url
        guard !resolution.isStale else { throw MacCaptureRouteError.folderPermissionExpired }
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
        let resolution = try CaptureBookmarkResolver.resolve(rootBookmark)
        let rootURL = resolution.url
        guard !resolution.isStale else { throw MacCaptureRouteError.folderPermissionExpired }
        let didAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if didAccess { rootURL.stopAccessingSecurityScopedResource() } }
        let noteURL = try CapturePathValidation.containedFileURL(
            relativePath: relativePath,
            rootURL: rootURL
        )
        guard FileManager.default.fileExists(atPath: noteURL.path) else {
            throw MacCaptureRouteError.existingNoteMissing(relativePath)
        }
        let markdown = try String(contentsOf: noteURL, encoding: .utf8)
        _ = try MarkdownDocumentEditor().applying(
            MarkdownCaptureMutation(
                requestID: UUID(),
                entry: String(localized: "Vox.md route preflight"),
                placement: placement
            ),
            to: markdown
        )
    }

    private func save() async {
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let routePath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rootBookmark.isEmpty else { throw MacCaptureRouteError.folderRequired }
            let ownedName = fixedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let routeName = ownedName?.isEmpty == false
                ? ownedName!
                : (trimmedName.isEmpty ? rootName : trimmedName)
            try CapturePathValidation.validateRelativePath(routePath)
            if !attachmentsFolder.isEmpty { try CapturePathValidation.validateRelativePath(attachmentsFolder) }
            let target: CaptureNoteTarget = switch targetKind {
            case .newNote: .newNote(pathTemplate: routePath)
            case .rollingNote: .rollingNote(pathTemplate: routePath, period: period)
            case .existingNote: .existingNote(relativePath: routePath)
            }
            let placement: CapturePlacement = switch placementKind {
            case .append: .append
            case .prepend: .prepend
            case .heading:
                .beneathHeading(
                    CaptureHeadingSelector(title: heading.trimmingCharacters(in: .whitespacesAndNewlines), level: headingLevel),
                    missingHeadingBehavior: missingHeadingBehavior
                )
            }
            if case .beneathHeading(let selector, _) = placement, selector.title.isEmpty {
                throw MacCaptureRouteError.headingRequired
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
                name: routeName,
                rootBookmark: rootBookmark,
                rootName: rootName,
                noteTarget: target,
                placement: placement,
                entryPrefix: markdownTemplatePath == nil ? prefix : "",
                entrySuffix: markdownTemplatePath == nil ? suffix : "",
                entryTemplateID: markdownTemplatePath == nil ? templateID : nil,
                markdownTemplatePath: markdownTemplatePath,
                attachmentsFolderName: attachmentsFolder,
                retryProtectionEnabled: retryProtectionEnabled
            ))
            dismiss()
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }
}

private enum MacCaptureRouteError: Error, LocalizedError {
    case storageUnavailable, folderRequired, headingRequired, folderPermissionExpired, noteOutsideRoot
    case templateOutsideRoot, markdownTemplateRequired
    case existingNoteMissing(String)

    var errorDescription: String? {
        switch self {
        case .storageUnavailable: String(localized: "Shared capture storage is unavailable.")
        case .folderRequired: String(localized: "Choose a vault or folder.")
        case .headingRequired: String(localized: "Enter a heading title.")
        case .folderPermissionExpired: String(localized: "The selected vault or folder permission expired. Choose it again.")
        case .noteOutsideRoot: String(localized: "Choose a Markdown note inside the selected vault or folder.")
        case .templateOutsideRoot: String(localized: "Choose a Markdown template inside the selected vault or folder.")
        case .markdownTemplateRequired: String(localized: "Choose a Markdown (.md) template file.")
        case .existingNoteMissing(let path): String(localized: "The existing note ‘\(path)’ was not found in the selected vault or folder.")
        }
    }
}
