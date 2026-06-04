import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

/// Manage v2md-style recording flows: named presets that control export,
/// frontmatter, audio retention, and post-processing.
struct FlowSettingsView: View {
    @State private var flows: [RecordingFlow] = RecordingFlowStore.loadFlows()

    var body: some View {
        List {
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
                            if flow.id == RecordingFlowStore.selectedFlowId() {
                                Text("SELECTED")
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
                Text("Flows")
            } footer: {
                Text("Select the active flow from the Listen screen dropdown before recording. Use this screen to edit the default flow or add custom flows for your own frontmatter, audio, export, and post-processing rules.")
            }

            Section {
                Button {
                    flows.append(RecordingFlowStore.makeCustomFlow())
                } label: {
                    Label("Add Custom Flow", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Flows")
        .preferredColorScheme(.dark)
        .onChange(of: flows) { _, newValue in
            RecordingFlowStore.saveFlows(newValue)
        }
    }

    private func delete(_ flow: RecordingFlow) {
        flows.removeAll { $0.id == flow.id }
        if RecordingFlowStore.selectedFlowId() == flow.id {
            RecordingFlowStore.selectFlow(id: flows.first?.id ?? RecordingFlowStore.generalId)
        }
    }
}

private struct FlowEditorView: View {
    @Binding var flow: RecordingFlow
    @State private var frontmatterText: String
    @State private var showBookmarkPicker = false
    @State private var bookmarkPickerKind: BookmarkKind = .exportFolder

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
            frontmatterSection
            fileExportSection
            audioExportSection
        }
        .navigationTitle(flow.displayName)
        .navigationBarTitleDisplayMode(.inline)
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
                .tint(Brutal.muted)
        }
    }

    private var postProcessingSection: some View {
        Section("Post-Processing") {
            Picker("Mode", selection: $flow.postProcessingMode) {
                ForEach(RecordingFlowPostProcessingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            if flow.postProcessingMode == .custom {
                TextEditor(text: $flow.customPostProcessingInstruction)
                    .frame(minHeight: 90)
            }
        }
    }

    private var frontmatterSection: some View {
        Section("Frontmatter") {
            Text("One `key: value` per line. Example: `tags: [dream, voice]`.")
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
                .tint(Brutal.muted)
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
                        .tint(Brutal.muted)
                        .onChange(of: flow.exportSettings.mdObsidianEnabled) { _, _ in markPerFlow() }
                }

                if flow.exportSettings.format == .yaml {
                    Toggle("Use .md Extension", isOn: $flow.exportSettings.yamlUsesMarkdownExtension)
                        .tint(Brutal.muted)
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
                    .tint(Brutal.muted)
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
            Text("File Export")
        } footer: {
            Text("These settings apply only when this flow is selected before recording. Choose a different export directory for each flow to route notes into separate folders.")
        }
    }

    private var audioExportSection: some View {
        Section {
            Picker("Save Audio", selection: $flow.audioSaveMode) {
                ForEach(RecordingFlowAudioSaveMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            if flow.audioSaveMode != .off {
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

                if flow.audioSaveMode == .attachmentsFolder, flow.exportSettings.audioFolderName.isEmpty {
                    TextField("Attachments Folder", text: $flow.attachmentsFolderName)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }
            }
        } header: {
            Text("Audio Export")
        } footer: {
            Text("When no audio export directory is set, saved audio uses this flow's note export folder. Attachments Folder creates a subfolder next to the note.")
        }
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
            .tint(Brutal.muted)
            .disabled(flow.exportSettings.yamlProperties.count == 1 && flow.exportSettings.yamlProperties.contains(property))
        }
    }

    private func folderRow(title: LocalizedStringKey, value: String, systemImage: String = "folder") -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.isEmpty ? String(localized: "Not set") : value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: systemImage)
                .foregroundStyle(Brutal.muted)
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
                                .textCase(.uppercase)

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
        .preferredColorScheme(.dark)
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
