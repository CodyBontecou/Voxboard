import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

struct MacCaptureDestinationLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var library = CaptureLibraryEnvelope()
    @State private var destinationToEdit: CaptureDestination?
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if library.destinations.isEmpty {
                    ContentUnavailableView(
                        "No Capture Routes",
                        systemImage: "folder.badge.plus",
                        description: Text("Add a local folder or Obsidian vault for precise Markdown delivery on this Mac.")
                    )
                } else {
                    ForEach(library.destinations) { destination in
                        Button {
                            destinationToEdit = destination
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: destination.id == library.defaultDestinationID ? "star.fill" : "folder")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(destination.name)
                                    Text("\(destination.rootName) · \(targetSummary(destination.noteTarget))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if destination.id != library.defaultDestinationID {
                                Button("Make Default") { Task { await makeDefault(destination.id) } }
                            }
                            Button("Delete", role: .destructive) { Task { await delete(destination.id) } }
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Capture Routes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { isAdding = true } label: { Label("Add Route", systemImage: "plus") }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $isAdding) {
            MacCaptureDestinationEditor(existing: nil, templates: library.entryTemplates) { destination in
                try await save(destination)
            }
        }
        .sheet(item: $destinationToEdit) { destination in
            MacCaptureDestinationEditor(existing: destination, templates: library.entryTemplates) { updated in
                try await save(updated)
            }
        }
    }

    private func store() throws -> CaptureLibraryStore {
        guard let url = AppConstants.captureLibraryURL else {
            throw MacCaptureRouteError.storageUnavailable
        }
        return CaptureLibraryStore(fileURL: url)
    }

    private func load() async {
        do {
            library = try await store().load()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ destination: CaptureDestination) async throws {
        library = try await store().update { value in
            if let index = value.destinations.firstIndex(where: { $0.id == destination.id }) {
                value.destinations[index] = destination
            } else {
                value.destinations.append(destination)
            }
            if value.defaultDestinationID == nil { value.defaultDestinationID = destination.id }
        }
    }

    private func makeDefault(_ id: UUID) async {
        do {
            library = try await store().update { $0.defaultDestinationID = id }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ id: UUID) async {
        guard let captureRootURL = AppConstants.captureDirectoryURL else {
            errorMessage = MacCaptureRouteError.storageUnavailable.localizedDescription
            return
        }
        do {
            let inbox = CaptureInbox(rootDirectoryURL: captureRootURL)
            let processing = try await inbox.requestIDs(
                referencingDestination: id,
                states: [.processing]
            )
            guard processing.isEmpty else {
                throw MacCaptureRouteError.destinationProcessing(processing.count)
            }
            let queued = try await inbox.requestIDs(
                referencingDestination: id,
                states: [.pending, .failed]
            )
            let replacement = library.destinations.first { $0.id != id }
            if let replacement {
                _ = try await inbox.rerouteRequests(
                    from: id,
                    to: replacement.id,
                    states: [.pending, .failed]
                )
            } else if !queued.isEmpty {
                throw MacCaptureRouteError.destinationQueued(queued.count)
            }
            library = try await store().update { value in
                value.destinations.removeAll { $0.id == id }
                value.flowBindings = value.flowBindings.filter { $0.value != id }
                if value.defaultDestinationID == id {
                    value.defaultDestinationID = value.destinations.first?.id
                }
            }
            RecordingFlowStore.clearCaptureDestination(id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func targetSummary(_ target: CaptureNoteTarget) -> String {
        switch target {
        case .newNote(let path): return path
        case .rollingNote(let path, let period): return "\(period.rawValue): \(path)"
        case .existingNote(let path): return path
        }
    }
}

private struct MacCaptureDestinationEditor: View {
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
    @State private var prefix: String
    @State private var suffix: String
    @State private var attachmentsFolder: String
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
        _templateID = State(initialValue: boundID)
        _prefix = State(initialValue: bound?.entryPrefix ?? existing?.entryPrefix ?? "")
        _suffix = State(initialValue: bound?.entrySuffix ?? existing?.entrySuffix ?? "")
        _attachmentsFolder = State(initialValue: existing?.attachmentsFolderName ?? "attachments")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Route Name (Optional)", text: $name)
                    Button { chooseFolder() } label: {
                        LabeledContent("Vault / Folder", value: rootName.isEmpty ? "Choose…" : rootName)
                    }
                }
                Section("Note Target") {
                    Picker("Target", selection: $targetKind) {
                        ForEach(TargetKind.allCases) { Text($0.title).tag($0) }
                    }
                    TextField(targetKind == .existingNote ? "Relative Note Path" : "Path Template", text: $path)
                    if targetKind == .existingNote {
                        Button("Choose Existing Note…") { chooseExistingNote() }
                            .disabled(rootBookmark.isEmpty)
                    }
                    if targetKind == .rollingNote {
                        Picker("Period", selection: $period) {
                            ForEach(CaptureRollingPeriod.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                    }
                    Text("Path tokens include {date}, {time}, {timestamp}, {period}, {week}, and {id8}.")
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
                    TextField("Attachments Folder", text: $attachmentsFolder)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "Add Capture Route" : "Edit Capture Route")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await save() } }.disabled(isSaving)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 620)
    }

    private func chooseExistingNote() {
        do {
            var isStale = false
            let rootURL = try URL(
                resolvingBookmarkData: rootBookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL
            guard !isStale else { throw MacCaptureRouteError.folderPermissionExpired }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
            panel.directoryURL = rootURL
            panel.prompt = "Choose Note"
            guard panel.runModal() == .OK, let selectedURL = panel.url?.standardizedFileURL else { return }
            let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            guard selectedURL.path.hasPrefix(rootPrefix) else { throw MacCaptureRouteError.noteOutsideRoot }
            let relativePath = String(selectedURL.path.dropFirst(rootPrefix.count))
            try CapturePathValidation.validateRelativePath(relativePath)
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
        panel.prompt = "Choose"
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
        } catch {
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
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else { throw MacCaptureRouteError.folderPermissionExpired }
        let noteURL = try CapturePathValidation.containedFileURL(
            relativePath: relativePath,
            rootURL: rootURL
        )
        let didAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if didAccess { rootURL.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: noteURL.path) else {
            throw MacCaptureRouteError.existingNoteMissing(relativePath)
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

    private func save() async {
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let routePath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rootBookmark.isEmpty else { throw MacCaptureRouteError.folderRequired }
            let routeName = trimmedName.isEmpty ? rootName : trimmedName
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
            }
            isSaving = true
            try await onSave(CaptureDestination(
                id: existing?.id ?? UUID(),
                name: routeName,
                rootBookmark: rootBookmark,
                rootName: rootName,
                noteTarget: target,
                placement: placement,
                entryPrefix: prefix,
                entrySuffix: suffix,
                entryTemplateID: templateID,
                attachmentsFolderName: attachmentsFolder
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
    case existingNoteMissing(String), destinationQueued(Int), destinationProcessing(Int)

    var errorDescription: String? {
        switch self {
        case .storageUnavailable: "Shared capture storage is unavailable."
        case .folderRequired: "Choose a vault or folder."
        case .headingRequired: "Enter a heading title."
        case .folderPermissionExpired: "The selected vault or folder permission expired. Choose it again."
        case .noteOutsideRoot: "Choose a Markdown note inside the selected vault or folder."
        case .existingNoteMissing(let path): "The existing note ‘\(path)’ was not found in the selected vault or folder."
        case .destinationQueued(let count): "Add another route before deleting this one so \(count) queued capture(s) can be rerouted."
        case .destinationProcessing(let count): "Wait for \(count) active capture(s) to finish before deleting this route."
        }
    }
}
