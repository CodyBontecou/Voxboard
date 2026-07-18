import AppIntents
import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

/// Manage reusable Vox capture workflows across text, links, media, scans,
/// files, and voice recordings.
struct FlowSettingsView: View {
    @State private var flows: [RecordingFlow] = RecordingFlowStore.loadFlows()

    var body: some View {
        List {
            introSection

            Section {
                ForEach($flows) { $flow in
                    NavigationLink {
                        FlowEditorView(flow: $flow)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: flow.symbolName)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(flow.displayName)
                                Text(flow.postProcessingMode.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if flow.id == CaptureVoxProfileStore.selectedProfileID(defaults: AppConstants.sharedDefaults) {
                                Text("Capture")
                                    .font(.caption2.monospaced().weight(.semibold))
                                    .foregroundStyle(.secondary)
                            } else if flow.id == RecordingFlowStore.selectedFlowId() {
                                Text("Keyboard")
                                    .font(.caption2.monospaced().weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if !flow.isBuiltIn {
                            Button("Delete", role: .destructive) {
                                delete(flow)
                            }
                        }
                    }
                }
            } header: {
                Text("Your Voxes")
            } footer: {
                Text("Tap a Vox to customize how every Capture is processed, formatted, and routed. Voice-only audio and legacy export options remain available inside each Vox.")
            }

            Section {
                Button {
                    flows.append(RecordingFlowStore.makeCustomFlow())
                } label: {
                    Label("Add Vox", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Manage Voxes")
        .font(Geist.body())
        .tint(Geist.Palette.gray1000)
        .scrollContentBackground(.hidden)
        .background(Geist.Palette.background200)
        .onChange(of: flows) { _, newValue in
            RecordingFlowStore.saveFlows(newValue)
            if #available(iOS 18.0, *) {
                VoxboardShortcutsProvider.updateAppShortcutParameters()
            }
        }
    }

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("What is a Vox?", systemImage: "waveform.circle")
                    .font(.headline)
                Text("A Vox is a reusable capture workflow. Choose one in Capture and Vox.md uses it for typed Markdown, links, photos, files, scans, sketches, and voice.")
                Text("Create Voxes for meetings, journal entries, task capture, ideas, or any route and template setup you use often.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        }
    }

    private func delete(_ flow: RecordingFlow) {
        flows.removeAll { $0.id == flow.id }
        let fallbackID = flows.first?.id ?? RecordingFlowStore.generalId
        if RecordingFlowStore.selectedFlowId() == flow.id {
            RecordingFlowStore.selectFlow(id: fallbackID)
        }
        if CaptureVoxProfileStore.selectedProfileID(defaults: AppConstants.sharedDefaults) == flow.id {
            CaptureVoxProfileStore.selectCaptureProfile(
                id: fallbackID,
                defaults: AppConstants.sharedDefaults
            )
        }
    }
}

private struct FlowEditorView: View {
    @Binding var flow: RecordingFlow
    @State private var frontmatterText: String
    @State private var showBookmarkPicker = false
    @State private var bookmarkPickerKind: BookmarkKind = .exportFolder
    @State private var captureDestinations: [CaptureDestination] = []
    @State private var captureEntryTemplates: [CaptureEntryTemplate] = []
    @State private var captureDestinationLoadError: String?

    private enum VoxCapturePlacementChoice: String, Hashable {
        case routeDefault
        case top
        case bottom
    }

    private enum BookmarkKind {
        case exportFolder
        case audioFolder
        case markdownTemplate

        var allowedContentTypes: [UTType] {
            switch self {
            case .exportFolder, .audioFolder:
                return [.folder]
            case .markdownTemplate:
                return [.init(filenameExtension: "md") ?? .plainText, .plainText]
            }
        }
    }

    init(flow: Binding<RecordingFlow>) {
        self._flow = flow
        self._frontmatterText = State(initialValue: Self.renderFrontmatter(flow.wrappedValue.staticFrontmatter))
    }

    var body: some View {
        Form {
            identitySection
            postProcessingSection
            preciseCaptureRoutingSection
            if flow.captureDestinationID == nil {
                fileExportSection
            }
            if showsFrontmatterSection {
                frontmatterSection
            }
            audioExportSection
        }
        .navigationTitle(flow.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadCaptureDestinations() }
        .onAppear {
            // File export now lives on each flow. Mark old flow records as
            // per-flow when the user opens them so later edits do not fall back
            // to the legacy app-wide Files tab settings.
            flow.exportSettings.usesCustomExportSettings = true
        }
        .fileImporter(
            isPresented: $showBookmarkPicker,
            allowedContentTypes: bookmarkPickerKind.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            saveBookmark(url: url, kind: bookmarkPickerKind)
        }
        .onDisappear {
            flow.staticFrontmatter = Self.parseFrontmatter(frontmatterText)
        }
    }

    private var showsFrontmatterSection: Bool { true }

    private var identitySection: some View {
        Section("Identity") {
            TextField("Name", text: $flow.name)
            NavigationLink {
                FlowIconPickerView(symbolName: $flow.symbolName)
            } label: {
                HStack {
                    Text("Icon")
                    Spacer()
                    Image(systemName: FlowIconPickerView.iconName(for: flow.symbolName))
                        .frame(width: 24)
                        .foregroundStyle(.secondary)
                    Text(FlowIconPickerView.title(for: flow.symbolName))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Toggle("Enabled", isOn: $flow.isEnabled)
                .tint(Geist.muted)
        }
    }

    private var postProcessingSection: some View {
        Section {
            Toggle("Apply to Capture Text", isOn: $flow.captureProcessingEnabled)
                .tint(Geist.muted)

            Picker("Mode", selection: $flow.postProcessingMode) {
                ForEach(RecordingFlowPostProcessingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(flow.postProcessingMode.helpTitle, systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
                Text(flow.postProcessingMode.helpText)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            if flow.postProcessingMode == .custom {
                TextEditor(text: $flow.customPostProcessingInstruction)
                    .frame(minHeight: 90)
                Text("Describe exactly how Vox.md should shape captured text. Leave blank to preserve the original when AI enrichment is unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Empty Capture Prompt", text: $flow.capturePrompt, axis: .vertical)
                .lineLimit(2...4)
            Text("Example: What do you want to remember?")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Capture Processing")
        } footer: {
            Text("Voice runs always use the selected mode. Applying it to Capture Text is opt-in so existing typed Markdown is never rewritten unexpectedly. Processing runs on device and falls back to deterministic or original text.")
        }
    }

    private var preciseCaptureRoutingSection: some View {
        Section {
            Picker("Markdown Route", selection: $flow.captureDestinationID) {
                Text("App Default / Legacy Voice Export").tag(Optional<UUID>.none)
                ForEach(captureDestinations) { destination in
                    Text(destination.name).tag(Optional(destination.id))
                }
            }

            if let destinationID = flow.captureDestinationID,
               let destination = captureDestinations.first(where: { $0.id == destinationID }) {
                Label(destination.rootName, systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(captureDestinationSummary(destination))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Default Placement", selection: capturePlacementBinding) {
                    Text("Route Default").tag(VoxCapturePlacementChoice.routeDefault)
                    Text("Top").tag(VoxCapturePlacementChoice.top)
                    Text("Bottom").tag(VoxCapturePlacementChoice.bottom)
                }

                Picker("Default Entry Template", selection: $flow.captureEntryTemplateID) {
                    Text("Route Default").tag(UUID?.none)
                    ForEach(captureEntryTemplates) { template in
                        Text(template.name).tag(Optional(template.id))
                    }
                }
            } else if flow.captureDestinationID != nil {
                Text("This destination is missing. Choose another route or use the app default.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let captureDestinationLoadError {
                Text(captureDestinationLoadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Unified Capture Route")
        } footer: {
            Text("A unified route gives this Vox the same rolling notes, prepend, heading insertion, attachment folder, conflict-safe writes, and retries as Quick Capture. Create routes from Capture → sliders.")
        }
    }

    private var frontmatterSection: some View {
        Section("Metadata") {
            Picker("Scope", selection: $flow.metadataScope) {
                ForEach(CaptureVoxMetadataScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            Text(flow.metadataScope == .document
                 ? "Note Frontmatter is best for one note per capture. On rolling notes, later captures may update the note-wide values."
                 : "Inline Entry Fields writes queryable `key:: value` lines with each entry, keeping rolling-note metadata separate.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("One `key: value` per line. Example: `tags: [journal, idea]`.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $frontmatterText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .onChange(of: frontmatterText) { _, value in
                    flow.staticFrontmatter = Self.parseFrontmatter(value)
                }
        }
    }

    private var fileExportSection: some View {
        Section {
            Toggle("Save Notes to Files", isOn: $flow.exportSettings.exportEnabled)
                .tint(Geist.muted)
                .onChange(of: flow.exportSettings.exportEnabled) { _, _ in markPerFlow() }

            if flow.exportSettings.exportEnabled {
                Button {
                    openBookmarkPicker(.exportFolder)
                } label: {
                    folderRow(title: "Export Directory", value: flow.exportSettings.folderName)
                }
                .buttonStyle(.plain)

                if !flow.exportSettings.folderName.isEmpty {
                    Button("Clear Export Directory", role: .destructive) {
                        markPerFlow()
                        flow.exportSettings.folderBookmark = nil
                        flow.exportSettings.folderName = ""
                    }
                }

                Picker("Format", selection: $flow.exportSettings.format) {
                    Text("TXT").tag(ExportFileFormat.txt)
                    Text("MD").tag(ExportFileFormat.md)
                    Text("JSON").tag(ExportFileFormat.json)
                    Text("YAML").tag(ExportFileFormat.yaml)
                }
                .onChange(of: flow.exportSettings.format) { _, _ in markPerFlow() }

                if flow.exportSettings.format == .md {
                    Toggle("Obsidian Bases", isOn: $flow.exportSettings.mdObsidianEnabled)
                        .tint(Geist.muted)
                        .onChange(of: flow.exportSettings.mdObsidianEnabled) { _, _ in markPerFlow() }
                }

                if flow.exportSettings.format == .yaml {
                    Toggle("Use .md Extension", isOn: $flow.exportSettings.yamlUsesMarkdownExtension)
                        .tint(Geist.muted)
                        .onChange(of: flow.exportSettings.yamlUsesMarkdownExtension) { _, _ in markPerFlow() }
                    yamlPropertiesPicker
                }

                Picker("Mode", selection: $flow.exportSettings.mode) {
                    Text("New File").tag(ExportFileMode.newFile)
                    Text("Append").tag(ExportFileMode.append)
                }
                .onChange(of: flow.exportSettings.mode) { _, _ in markPerFlow() }

                if flow.exportSettings.mode == .newFile {
                    TextField("Filename Template", text: $flow.exportSettings.newFileNameTemplate)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onChange(of: flow.exportSettings.newFileNameTemplate) { _, _ in markPerFlow() }
                    Text("Tokens: {timestamp}, {date}, {time}, {id8}, {id}, {model}, {language}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Append Filename", text: $flow.exportSettings.appendFileName)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onChange(of: flow.exportSettings.appendFileName) { _, _ in markPerFlow() }
                }

                Toggle("Use Markdown Template", isOn: $flow.exportSettings.markdownTemplateEnabled)
                    .tint(Geist.muted)
                    .onChange(of: flow.exportSettings.markdownTemplateEnabled) { _, _ in markPerFlow() }
                if flow.exportSettings.markdownTemplateEnabled {
                    Button {
                        openBookmarkPicker(.markdownTemplate)
                    } label: {
                        folderRow(title: "Markdown Template", value: flow.exportSettings.markdownTemplateName, systemImage: "doc.text")
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Legacy Voice File Export")
        } footer: {
            Text("These compatibility settings apply to direct voice runs only when no unified Capture route is selected.")
        }
    }

    private var audioExportSection: some View {
        Section {
            Picker("Save Audio", selection: $flow.audioSaveMode) {
                ForEach(RecordingFlowAudioSaveMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .onChange(of: flow.audioSaveMode) { _, newMode in
                markPerFlow()
                if newMode == .alongsideTranscript {
                    flow.exportSettings.audioFolderBookmark = nil
                    flow.exportSettings.audioFolderName = ""
                }
            }

            if flow.audioSaveMode == .attachmentsFolder {
                if flow.captureDestinationID != nil {
                    TextField("Attachments Folder", text: $flow.attachmentsFolderName)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Text("Relative to the unified Markdown destination. Leave blank to use that destination’s default attachment folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        openBookmarkPicker(.audioFolder)
                    } label: {
                        folderRow(title: "Audio Export Directory", value: flow.exportSettings.audioFolderName)
                    }
                    .buttonStyle(.plain)

                    if !flow.exportSettings.audioFolderName.isEmpty {
                        Button("Clear Audio Directory", role: .destructive) {
                            flow.exportSettings.audioFolderBookmark = nil
                            flow.exportSettings.audioFolderName = ""
                        }
                    }

                    if flow.exportSettings.audioFolderName.isEmpty {
                        TextField("Attachments Folder", text: $flow.attachmentsFolderName)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                }
            }

            if flow.audioSaveMode != .off {
                Toggle("Embed Audio in Markdown", isOn: $flow.exportSettings.embedAudioInMarkdown)
                    .tint(Geist.muted)
                    .disabled(!markdownAudioEmbedAvailable)
                    .onChange(of: flow.exportSettings.embedAudioInMarkdown) { _, _ in markPerFlow() }

                if flow.exportSettings.embedAudioInMarkdown && markdownAudioEmbedAvailable {
                    Picker("Embed Position", selection: $flow.exportSettings.audioEmbedPlacement) {
                        ForEach(RecordingFlowAudioEmbedPlacement.allCases) { placement in
                            Text(placement.displayName).tag(placement)
                        }
                    }
                    .onChange(of: flow.exportSettings.audioEmbedPlacement) { _, _ in markPerFlow() }
                }

                Text(markdownAudioEmbedHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Voice Audio")
        } footer: {
            Text(audioExportFooterText)
        }
    }

    private var audioExportFooterText: String {
        switch flow.audioSaveMode {
        case .off:
            return "Turn this on to save a copy of the recorded audio when a note is exported."
        case .alongsideTranscript:
            return flow.captureDestinationID == nil
                ? "Saved audio uses the same legacy export directory and base filename as the note."
                : "Saved audio is placed alongside the unified Markdown note."
        case .attachmentsFolder:
            return flow.captureDestinationID == nil
                ? "When no audio export directory is set, saved audio uses this Vox's legacy note export folder."
                : "Saved audio uses a subfolder inside the unified Markdown destination, and that route survives deferred retries."
        }
    }

    private var markdownAudioEmbedAvailable: Bool {
        if flow.captureDestinationID != nil { return true }
        guard flow.exportSettings.exportEnabled else { return false }
        if flow.exportSettings.markdownTemplateEnabled { return true }
        if flow.exportSettings.format == .md { return true }
        return flow.exportSettings.format == .yaml && flow.exportSettings.yamlUsesMarkdownExtension
    }

    private var markdownAudioEmbedHelpText: String {
        if flow.captureDestinationID != nil {
            return "Adds an Obsidian-style audio link to the unified Markdown note at the selected position."
        }
        guard markdownAudioEmbedAvailable else {
            return "Audio embeds require a Markdown note export. Switch this Vox to MD, a Markdown template, or YAML with the .md extension."
        }
        return "Adds an Obsidian-style `![[recording.m4a]]` link to the note so you can replay the recording while reviewing the transcript."
    }

    private var yamlPropertiesPicker: some View {
        ForEach(ExportYAMLProperty.allCases, id: \.rawValue) { property in
            Toggle(
                property.displayName,
                isOn: Binding(
                    get: { flow.exportSettings.yamlProperties.contains(property) },
                    set: { enabled in toggleYAMLProperty(property, enabled: enabled) }
                )
            )
            .tint(Geist.muted)
            .disabled(flow.exportSettings.yamlProperties.count == 1 && flow.exportSettings.yamlProperties.contains(property))
        }
    }

    private var capturePlacementBinding: Binding<VoxCapturePlacementChoice> {
        Binding(
            get: {
                switch flow.capturePlacementOverride {
                case nil, .beneathHeading: return .routeDefault
                case .prepend: return .top
                case .append: return .bottom
                }
            },
            set: { choice in
                switch choice {
                case .routeDefault: flow.capturePlacementOverride = nil
                case .top: flow.capturePlacementOverride = .prepend
                case .bottom: flow.capturePlacementOverride = .append
                }
            }
        )
    }

    private func loadCaptureDestinations() async {
        guard let url = AppConstants.captureLibraryURL else {
            captureDestinationLoadError = String(localized: "Shared capture storage is unavailable.")
            return
        }
        do {
            let library = try await CaptureLibraryStore(fileURL: url).load()
            captureDestinations = library.destinations
            captureEntryTemplates = library.entryTemplates
            captureDestinationLoadError = nil
        } catch {
            captureDestinationLoadError = error.localizedDescription
        }
    }

    private func captureDestinationSummary(_ destination: CaptureDestination) -> String {
        let target: String
        switch destination.noteTarget {
        case .newNote(let path): target = path
        case .rollingNote(let path, let period): target = "\(period.rawValue.capitalized): \(path)"
        case .existingNote(let path): target = path
        }
        let placement: String
        switch destination.placement {
        case .append: placement = String(localized: "append")
        case .prepend: placement = String(localized: "prepend")
        case .beneathHeading(let heading, _): placement = String(localized: "under \(heading.title)")
        }
        return "\(target) · \(placement)"
    }

    private func folderRow(title: LocalizedStringKey, value: String, systemImage: String = "folder") -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.isEmpty ? String(localized: "Not set") : value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: systemImage)
                .foregroundStyle(Geist.muted)
        }
        .contentShape(Rectangle())
    }

    private func openBookmarkPicker(_ kind: BookmarkKind) {
        markPerFlow()
        bookmarkPickerKind = kind
        showBookmarkPicker = true
    }

    private func markPerFlow() {
        flow.exportSettings.usesCustomExportSettings = true
    }

    private func toggleYAMLProperty(_ property: ExportYAMLProperty, enabled: Bool) {
        markPerFlow()
        if enabled {
            flow.exportSettings.yamlProperties.insert(property)
        } else {
            guard flow.exportSettings.yamlProperties.count > 1 else { return }
            flow.exportSettings.yamlProperties.remove(property)
        }
    }

    private func saveBookmark(url: URL, kind: BookmarkKind) {
        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        markPerFlow()
        switch kind {
        case .exportFolder:
            flow.exportSettings.folderBookmark = bookmark
            flow.exportSettings.folderName = url.lastPathComponent
        case .audioFolder:
            flow.exportSettings.audioFolderBookmark = bookmark
            flow.exportSettings.audioFolderName = url.lastPathComponent
        case .markdownTemplate:
            flow.exportSettings.markdownTemplateBookmark = bookmark
            flow.exportSettings.markdownTemplateName = url.lastPathComponent
        }
    }

    private static func renderFrontmatter(_ frontmatter: [String: String]) -> String {
        frontmatter
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    private static func parseFrontmatter(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }
}

private struct FlowIconPickerView: View {
    @Binding var symbolName: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private let columns = [GridItem(.adaptive(minimum: 78), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                selectedIconPreview

                if filteredCategories.isEmpty {
                    Text("No matching icons")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    ForEach(filteredCategories) { category in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(category.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(nil)

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(category.options) { option in
                                    iconButton(option)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Icon")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search icons")
        .tint(Geist.Palette.gray1000)
    }

    private var filteredCategories: [FlowIconCategory] {
        Self.filteredCategories(matching: searchText)
    }

    private var selectedIconPreview: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.iconName(for: symbolName))
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Selected Icon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Self.title(for: symbolName))
                    .font(.body.weight(.semibold))
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.10)))
    }

    private func iconButton(_ option: FlowIconOption) -> some View {
        let selected = option.symbolName == Self.iconName(for: symbolName)
        return Button {
            symbolName = option.symbolName
            dismiss()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: option.symbolName)
                    .font(.title2)
                Text(option.title)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .foregroundColor(selected ? .accentColor : .primary)
            .frame(maxWidth: .infinity, minHeight: 78)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityValue(option.symbolName)
    }

    static func iconName(for symbolName: String) -> String {
        let trimmed = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "questionmark.square" : trimmed
    }

    static func title(for symbolName: String) -> String {
        let iconName = iconName(for: symbolName)
        return allOptions.first(where: { $0.symbolName == iconName })?.title ?? iconName
    }

    private static func filteredCategories(matching query: String) -> [FlowIconCategory] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return iconCategories }

        return iconCategories.compactMap { category in
            let matches = category.options.filter { $0.matches(trimmed) }
            guard !matches.isEmpty else { return nil }
            return FlowIconCategory(title: category.title, options: matches)
        }
    }

    private static let allOptions = iconCategories.flatMap(\.options)

    private static let iconCategories: [FlowIconCategory] = [
        FlowIconCategory(
            title: "Writing",
            options: [
                FlowIconOption("text.alignleft", "Text"),
                FlowIconOption("note.text", "Note"),
                FlowIconOption("doc.text", "Document"),
                FlowIconOption("doc.text.magnifyingglass", "Research"),
                FlowIconOption("list.bullet", "List"),
                FlowIconOption("quote.bubble", "Quote"),
                FlowIconOption("books.vertical", "Books"),
                FlowIconOption("bookmark", "Bookmark"),
                FlowIconOption("newspaper", "Article"),
                FlowIconOption("pencil", "Draft"),
            ]
        ),
        FlowIconCategory(
            title: "Voice",
            options: [
                FlowIconOption("mic", "Mic"),
                FlowIconOption("waveform", "Waveform"),
                FlowIconOption("wave.3.right", "Audio"),
                FlowIconOption("record.circle", "Record"),
                FlowIconOption("headphones", "Listen"),
                FlowIconOption("speaker.wave.2", "Speaker"),
                FlowIconOption("message", "Message"),
                FlowIconOption("bubble.left.and.text.bubble.right", "Chat"),
                FlowIconOption("phone", "Call"),
                FlowIconOption("video", "Video"),
            ]
        ),
        FlowIconCategory(
            title: "Tasks",
            options: [
                FlowIconOption("checkmark.circle", "Done"),
                FlowIconOption("checklist", "Checklist"),
                FlowIconOption("calendar", "Calendar"),
                FlowIconOption("bell", "Reminder"),
                FlowIconOption("flag", "Flag"),
                FlowIconOption("target", "Goal"),
                FlowIconOption("tray.and.arrow.down", "Inbox"),
                FlowIconOption("paperplane", "Send"),
                FlowIconOption("wand.and.stars", "Magic"),
                FlowIconOption("timer", "Timer"),
            ]
        ),
        FlowIconCategory(
            title: "Personal",
            options: [
                FlowIconOption("person", "Person"),
                FlowIconOption("person.crop.circle", "Profile"),
                FlowIconOption("brain.head.profile", "Thought"),
                FlowIconOption("heart", "Heart"),
                FlowIconOption("moon.stars", "Dream"),
                FlowIconOption("lightbulb", "Idea"),
                FlowIconOption("sparkles", "Sparkles"),
                FlowIconOption("house", "Home"),
                FlowIconOption("leaf", "Nature"),
                FlowIconOption("figure.walk", "Walk"),
            ]
        ),
        FlowIconCategory(
            title: "Work",
            options: [
                FlowIconOption("briefcase", "Work"),
                FlowIconOption("person.2", "People"),
                FlowIconOption("person.2.wave.2", "Meeting"),
                FlowIconOption("building.2", "Company"),
                FlowIconOption("chart.bar", "Stats"),
                FlowIconOption("rectangle.on.rectangle.angled", "Slides"),
                FlowIconOption("folder", "Folder"),
                FlowIconOption("archivebox", "Archive"),
                FlowIconOption("hammer", "Build"),
                FlowIconOption("gearshape", "Settings"),
            ]
        ),
    ]
}

private extension RecordingFlowPostProcessingMode {
    var helpTitle: String {
        switch self {
        case .none:
            return "Preserves captured text"
        case .clean:
            return "Cleans prose without changing intent"
        case .todoList:
            return "Creates a Markdown checklist"
        case .meetingNotes:
            return "Formats notes and action items"
        case .custom:
            return "Uses your custom instruction"
        }
    }

    var helpText: String {
        switch self {
        case .none:
            return "Keeps typed Markdown, OCR, and voice text exactly as captured. Static frontmatter and route settings still apply."
        case .clean:
            return "Fixes casing and punctuation while preserving meaning and Markdown structure. Without on-device enrichment, the original text is retained."
        case .todoList:
            return "Turns captured tasks into `- [ ]` Markdown items without inventing new work. A deterministic local fallback is always available."
        case .meetingNotes:
            return "Builds Markdown meeting notes with useful sections and grounded action items from typed text, OCR, or voice."
        case .custom:
            return "When on-device AI is available, Vox.md follows your instruction for captured text. Use it for standups, journal prompts, summaries, or call follow-ups."
        }
    }
}

private struct FlowIconCategory: Identifiable {
    let title: String
    let options: [FlowIconOption]

    var id: String { title }
}

private struct FlowIconOption: Identifiable {
    let symbolName: String
    let title: String
    let keywords: [String]

    var id: String { symbolName }

    init(_ symbolName: String, _ title: String, keywords: [String] = []) {
        self.symbolName = symbolName
        self.title = title
        self.keywords = keywords
    }

    func matches(_ query: String) -> Bool {
        let haystack = ([symbolName, title] + keywords).joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(query)
    }
}
