import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

extension Notification.Name {
    static let macShowCapture = Notification.Name("VoxboardMacShowCapture")
    static let macShowHistory = Notification.Name("VoxboardMacShowHistory")
    static let macChooseCaptureFiles = Notification.Name("VoxboardMacChooseCaptureFiles")
    static let macClearCaptureDraft = Notification.Name("VoxboardMacClearCaptureDraft")
}

private enum MacDestination: String, CaseIterable, Identifiable, Hashable {
    case capture = "Capture"
    case history = "History"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .capture: return "square.and.pencil"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape.fill"
        }
    }
}

struct MacRootView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var recorder: MacRecorder
    @Bindable var quickCaptureViewModel: QuickCaptureViewModel
    let windowCoordinator: MacWindowCoordinator
    @State private var selection: MacDestination? = .capture
    @State private var windowToken = UUID().uuidString

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("VOX.MD") {
                    ForEach(MacDestination.allCases) { destination in
                        NavigationLink(value: destination) {
                            Label(destination.rawValue, systemImage: destination.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .tag(destination)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
        } detail: {
            switch selection ?? .capture {
            case .capture:
                MacCaptureWorkspaceView(
                    viewModel: quickCaptureViewModel,
                    recorder: recorder,
                    windowToken: windowToken,
                    windowCoordinator: windowCoordinator,
                    openHistory: { windowCoordinator.showHistory() },
                    openSettings: { selection = .settings }
                )
            case .history:
                MacHistoryView(viewModel: quickCaptureViewModel)
            case .settings:
                MacSettingsView(recorder: recorder)
            }
        }
        .tint(Geist.Palette.gray1000)
        .frame(minWidth: 980, minHeight: 680)
        .background(
            MacSceneWindowRegistrar(
                kind: .main(token: windowToken),
                coordinator: windowCoordinator
            )
        )
        .onAppear {
            windowCoordinator.configure(openWindow: openWindow)
            windowCoordinator.mainRootReady(token: windowToken)
        }
        .onDisappear {
            windowCoordinator.mainRootNotReady(token: windowToken)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macShowCapture)) { notification in
            guard notification.object == nil || (notification.object as? String) == windowToken else { return }
            selection = .capture
        }
        .onReceive(NotificationCenter.default.publisher(for: .macShowHistory)) { notification in
            guard notification.object == nil || (notification.object as? String) == windowToken else { return }
            windowCoordinator.showHistory()
        }
    }
}

// MARK: - Model

private struct MacModelView: View {
    @Environment(ModelManager.self) private var modelManager

    private var whisperModels: [WhisperModelInfo] {
        WhisperModelInfo.availableModels.filter { !$0.engine.isParakeet }
    }

    private var parakeetModels: [WhisperModelInfo] {
        WhisperModelInfo.availableModels.filter { $0.engine.isParakeet }
    }

    var body: some View {
        ZStack {
            Geist.surface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    pageHeader("Download and select the local speech model used by macOS recordings and imports. Whisper models run through whisper.cpp + Metal on this Mac.")
                    modelSection("01", "Whisper Models", models: whisperModels)
                    modelSection("02", "Parakeet Models", models: parakeetModels)
                    languageSection
                }
            }
        }
        .navigationTitle("Model")
        .alert(
            "Model Operation Failed",
            isPresented: Binding(
                get: { modelManager.modelOperationError != nil },
                set: { if !$0 { modelManager.modelOperationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                modelManager.modelOperationError = nil
            }
        } message: {
            Text(modelManager.modelOperationError ?? "The model operation could not be completed.")
        }
    }

    private func pageHeader(_ text: String) -> some View {
        Text(text)
            .font(Geist.caption())
            .foregroundColor(Geist.muted)
            .lineSpacing(3)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Geist.bg)
    }

    private func modelSection(_ number: String, _ title: LocalizedStringKey, models: [WhisperModelInfo]) -> some View {
        VStack(spacing: 0) {
            sectionHeader(number, title)
            GeistDivider()
            ForEach(models) { model in
                modelRow(model)
                GeistDivider()
            }
        }
    }

    private var languageSection: some View {
        VStack(spacing: 0) {
            sectionHeader("03", "Language")
            GeistDivider()
            HStack {
                Text("Transcription Language")
                    .font(Geist.label())
                    .foregroundColor(Geist.text)
                Spacer()
                Picker("Language", selection: Binding(
                    get: { modelManager.selectedLanguage },
                    set: { modelManager.selectedLanguage = $0 }
                )) {
                    ForEach(modelManager.availableLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .frame(width: 220)
            }
            .padding(20)
            .background(Geist.bg)
        }
    }

    private func modelRow(_ model: WhisperModelInfo) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(Geist.label())
                        .foregroundColor(Geist.text)
                    if model.isBundled {
                        Text("Bundled")
                            .font(Geist.caption())
                            .foregroundColor(Geist.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(Rectangle().stroke(Geist.borderHi, lineWidth: 1))
                    }
                    if model.engine.isParakeet {
                        Text("Core ML")
                            .font(Geist.caption())
                            .foregroundColor(Geist.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))
                    }
                }
                Text(model.sizeLabel)
                    .font(Geist.caption())
                    .foregroundColor(Geist.muted)
                if let description = model.modelDescription {
                    Text(description)
                        .font(Geist.caption())
                        .foregroundColor(Geist.muted)
                }
            }
            Spacer()
            modelAction(model)
        }
        .padding(20)
        .background(Geist.bg)
    }

    @ViewBuilder
    private func modelAction(_ model: WhisperModelInfo) -> some View {
        if modelManager.isModelDownloaded(model) {
            HStack(spacing: 12) {
                if modelManager.selectedModelId == model.id {
                    Text("Selected")
                        .font(Geist.caption())
                        .foregroundColor(Geist.text)
                } else {
                    Button("Select Model") { modelManager.selectedModelId = model.id }
                        .font(Geist.caption())
                        .foregroundColor(Geist.text)
                        .buttonStyle(.plain)
                }
                Button("Delete") { modelManager.deleteModel(model) }
                    .font(Geist.caption())
                    .foregroundColor(Geist.error)
                    .buttonStyle(.plain)
            }
        } else if modelManager.isDownloading[model.id] == true {
            HStack(spacing: 8) {
                ProgressView(value: modelManager.downloadProgress[model.id] ?? 0)
                    .frame(width: 110)
                    .tint(Geist.text)
                Text("\(Int((modelManager.downloadProgress[model.id] ?? 0) * 100))%")
                    .font(Geist.caption())
                    .foregroundColor(Geist.muted)
                Button("Cancel") { modelManager.cancelDownload(model) }
                    .font(Geist.caption())
                    .foregroundColor(Geist.error)
                    .buttonStyle(.plain)
            }
        } else {
            Button {
                modelManager.startDownload(model)
            } label: {
                Text("↓ DOWNLOAD")
                    .font(Geist.caption())
                    .foregroundColor(Geist.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .overlay(Rectangle().stroke(Geist.borderHi, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Capture Presets

private struct MacCapturePresetSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var flows: [CapturePreset] = CapturePresetStore.loadFlows()
    @State private var selectedFlowId: String = CapturePresetStore.selectedFlowId()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("CAPTURE PRESETS")
                        .font(Geist.label())
                        .foregroundColor(Geist.text)
                    Spacer()
                    Button { addFlow() } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                }
                .padding(16)
                GeistDivider()
                List(selection: $selectedFlowId) {
                    ForEach(flows) { flow in
                        Label(flow.displayName, systemImage: MacFlowIconPickerView.iconName(for: flow.symbolName))
                            .tag(flow.id)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: 260)
            GeistDivider().frame(width: 1)

            if let index = flows.firstIndex(where: { $0.id == selectedFlowId }) {
                MacCapturePresetEditor(preset: $flows[index], onDelete: { delete(flows[index]) })
                    .id(flows[index].id)
            } else {
                Text("Select a Capture Preset")
                    .font(Geist.body())
                    .foregroundColor(Geist.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Capture Presets")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { reload() }
        .onChange(of: flows) { _, newValue in CapturePresetStore.saveFlows(newValue) }
        .onChange(of: selectedFlowId) { _, id in CapturePresetStore.selectFlow(id: id) }
    }

    private func reload() {
        flows = CapturePresetStore.loadFlows()
        selectedFlowId = CapturePresetStore.selectedFlowId()
    }

    private func addFlow() {
        let flow = CapturePresetStore.makeCustomFlow()
        flows.append(flow)
        selectedFlowId = flow.id
    }

    private func delete(_ flow: CapturePreset) {
        guard !flow.isBuiltIn else { return }
        let selectedCapturePresetID = CapturePresetProfileStore.selectedProfileID(
            defaults: AppConstants.sharedDefaults
        )
        CapturePresetStore.retirePreset(
            id: flow.id,
            ownedRouteID: flow.captureDestinationID
        )
        flows.removeAll { $0.id == flow.id }
        let fallbackID = flows.first?.id ?? CapturePresetStore.generalId
        selectedFlowId = fallbackID
        CapturePresetStore.selectFlow(id: fallbackID)
        if selectedCapturePresetID == flow.id {
            CapturePresetProfileStore.selectCaptureProfile(
                id: fallbackID,
                defaults: AppConstants.sharedDefaults
            )
        }
    }
}

private struct MacCapturePresetEditor: View {
    @Binding var flow: CapturePreset
    let onDelete: () -> Void
    @State private var frontmatterText: String
    @State private var isIconPickerPresented = false
    @State private var captureDestinations: [CaptureDestination] = []
    @State private var captureEntryTemplates: [CaptureEntryTemplate] = []
    @State private var captureDestinationLoadError: String?
    @State private var isEditingDestination = false
    @State private var isCaptureProcessingInfoPresented = false
    @AppStorage(
        CapturePresetProfileStore.selectedCaptureProfileIDKey,
        store: AppConstants.sharedDefaults
    ) private var selectedCaptureVoxID = ""

    init(preset: Binding<CapturePreset>, onDelete: @escaping () -> Void) {
        self._flow = preset
        self.onDelete = onDelete
        self._frontmatterText = State(initialValue: Self.renderFrontmatter(preset.wrappedValue.staticFrontmatter))
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $flow.name)
                Button {
                    isIconPickerPresented = true
                } label: {
                    HStack(spacing: 10) {
                        Text("Icon")
                        Spacer()
                        Image(systemName: MacFlowIconPickerView.iconName(for: flow.symbolName))
                            .frame(width: 24)
                            .foregroundStyle(.secondary)
                        Text(MacFlowIconPickerView.title(for: flow.symbolName))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Toggle("Enabled", isOn: $flow.isEnabled)
                if selectedCaptureVoxID == flow.id {
                    Label("Default for Capture", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Use as Capture Default") {
                        CapturePresetProfileStore.selectCaptureProfile(
                            id: flow.id,
                            defaults: AppConstants.sharedDefaults
                        )
                        selectedCaptureVoxID = flow.id
                    }
                    .disabled(!flow.isEnabled)
                }
            }

            Section("Capture Processing") {
                HStack(spacing: 10) {
                    Toggle("Apply to Capture Text", isOn: $flow.captureProcessingEnabled)
                    Button {
                        isCaptureProcessingInfoPresented = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("About Apply to Capture Text")
                    .accessibilityLabel("About Apply to Capture Text")
                }
                Picker("Mode", selection: $flow.postProcessingMode) {
                    ForEach(CapturePresetProcessingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if flow.postProcessingMode == .custom {
                    TextEditor(text: $flow.customPostProcessingInstruction)
                        .frame(minHeight: 90)
                }
                TextField("Empty Capture Prompt", text: $flow.capturePrompt)
                Text(flow.postProcessingMode.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Destination") {
                if let destination = ownedDestination {
                    LabeledContent("Vault / Folder", value: destination.rootName)
                    Text(captureDestinationSummary(destination))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button("Edit Destination…") {
                        isEditingDestination = true
                    }
                } else {
                    Text("Choose a vault or folder and define where this preset writes Markdown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Set Up Destination…") {
                        isEditingDestination = true
                    }
                }
                if let captureDestinationLoadError {
                    Text(captureDestinationLoadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("This destination belongs to this preset, including its note target, placement, formatting, attachments, and retry behavior.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if flow.captureDestinationID == nil {
                Section("Legacy Voice File Export") {
                Toggle("Save Notes to Files", isOn: $flow.exportSettings.exportEnabled)
                    .onChange(of: flow.exportSettings.exportEnabled) { _, _ in markPerFlow() }
                if flow.exportSettings.exportEnabled {
                    Button { chooseFolder(.exportFolder) } label: {
                        settingRow("Export Directory", value: flow.exportSettings.folderName, image: "folder")
                    }
                    Picker("Format", selection: $flow.exportSettings.format) {
                        ForEach(ExportFileFormat.allCases, id: \.self) { format in
                            Text(format.rawValue.uppercased()).tag(format)
                        }
                    }
                    Picker("Mode", selection: $flow.exportSettings.mode) {
                        Text("New File").tag(ExportFileMode.newFile)
                        Text("Append").tag(ExportFileMode.append)
                    }
                    if flow.exportSettings.mode == .newFile {
                        TextField("Filename Template", text: $flow.exportSettings.newFileNameTemplate)
                        Text("Tokens: {timestamp}, {date}, {time}, {YR} (2-digit year), {id8}, {id}, {model}, {language}")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Append Filename", text: $flow.exportSettings.appendFileName)
                    }
                    Toggle("Obsidian Bases", isOn: $flow.exportSettings.mdObsidianEnabled)
                    Toggle("Use Markdown Template", isOn: $flow.exportSettings.markdownTemplateEnabled)
                    if flow.exportSettings.markdownTemplateEnabled {
                        Button { chooseFolder(.markdownTemplate) } label: {
                            settingRow("Markdown Template", value: flow.exportSettings.markdownTemplateName, image: "doc.text")
                        }
                    }
                }
                }
            }

            Section("Metadata") {
                Picker("Scope", selection: $flow.metadataScope) {
                    ForEach(CapturePresetMetadataScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                Text(flow.metadataScope == .document
                     ? "Use note frontmatter for one-note-per-capture routes."
                     : "Use inline key:: value fields to keep rolling-note entries separate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $frontmatterText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
                    .onChange(of: frontmatterText) { _, text in flow.staticFrontmatter = Self.parseFrontmatter(text) }
            }

            Section("Voice Audio") {
                Picker("Save Audio", selection: $flow.audioSaveMode) {
                    ForEach(CapturePresetAudioSaveMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if flow.audioSaveMode == .attachmentsFolder {
                    if flow.captureDestinationID != nil {
                        TextField("Attachments Folder", text: $flow.attachmentsFolderName)
                        Text("Relative to the unified Markdown destination. Leave blank to use its default attachment folder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button { chooseFolder(.audioFolder) } label: {
                            settingRow("Audio Export Directory", value: flow.exportSettings.audioFolderName, image: "folder")
                        }
                        TextField("Attachments Folder", text: $flow.attachmentsFolderName)
                    }
                }
                if flow.audioSaveMode != .off {
                    Toggle("Embed Audio in Markdown", isOn: $flow.exportSettings.embedAudioInMarkdown)
                        .disabled(!markdownAudioEmbedAvailable)
                        .onChange(of: flow.exportSettings.embedAudioInMarkdown) { _, _ in markPerFlow() }
                    if flow.exportSettings.embedAudioInMarkdown && markdownAudioEmbedAvailable {
                        Picker("Embed Position", selection: $flow.exportSettings.audioEmbedPlacement) {
                            ForEach(CapturePresetAudioEmbedPlacement.allCases) { placement in
                                Text(placement.displayName).tag(placement)
                            }
                        }
                        .onChange(of: flow.exportSettings.audioEmbedPlacement) { _, _ in markPerFlow() }
                    }
                    Text(markdownAudioEmbedHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !flow.isBuiltIn {
                Section {
                    Button("Delete Preset", role: .destructive, action: onDelete)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 18)
        .navigationTitle(flow.displayName)
        .sheet(isPresented: $isIconPickerPresented) {
            MacFlowIconPickerView(symbolName: $flow.symbolName)
                .frame(minWidth: 540, minHeight: 620)
        }
        .sheet(isPresented: $isEditingDestination) {
            MacCaptureDestinationEditor(
                existing: ownedDestination,
                templates: captureEntryTemplates,
                fixedName: flow.displayName
            ) { destination in
                try await saveOwnedDestination(destination)
            }
        }
        .sheet(isPresented: $isCaptureProcessingInfoPresented) {
            MacCaptureTextProcessingInfoView()
        }
        .task { await loadCaptureDestinations() }
        .onAppear { flow.exportSettings.usesCustomExportSettings = true }
        .onDisappear { flow.staticFrontmatter = Self.parseFrontmatter(frontmatterText) }
    }

    private enum BookmarkKind {
        case exportFolder, audioFolder, markdownTemplate
    }

    private var ownedDestination: CaptureDestination? {
        guard let id = flow.captureDestinationID else { return nil }
        return captureDestinations.first(where: { $0.id == id })
    }

    private func saveOwnedDestination(_ submittedDestination: CaptureDestination) async throws {
        guard let url = AppConstants.captureLibraryURL else {
            throw MacCapturePresetDestinationError.storageUnavailable
        }
        let destination = CapturePresetStore.migratingLegacyMarkdownTemplate(
            into: submittedDestination,
            from: flow.exportSettings
        )
        let library = try await CaptureLibraryStore(fileURL: url).update { library in
            if let index = library.destinations.firstIndex(where: { $0.id == destination.id }) {
                library.destinations[index] = destination
            } else {
                library.destinations.append(destination)
            }
            if library.defaultDestinationID == nil {
                library.defaultDestinationID = destination.id
            }
        }
        flow.captureDestinationID = destination.id
        flow.captureEntryTemplateID = nil
        flow.capturePlacementOverride = nil
        if destination.markdownTemplatePath != nil {
            flow.exportSettings.markdownTemplateEnabled = false
            flow.exportSettings.markdownTemplateBookmark = nil
            flow.exportSettings.markdownTemplateName = ""
        }
        captureDestinations = library.destinations
        captureEntryTemplates = library.entryTemplates
        captureDestinationLoadError = nil
    }

    private func loadCaptureDestinations() async {
        guard let url = AppConstants.captureLibraryURL else {
            captureDestinationLoadError = "Shared capture storage is unavailable."
            return
        }
        do {
            let store = CaptureLibraryStore(fileURL: url)
            let library = try await CapturePresetRouteLibrary.load(from: store)
            captureDestinations = library.destinations
            captureEntryTemplates = library.entryTemplates
            if let refreshed = CapturePresetStore.flow(id: flow.id) {
                // Route migration owns only these fields. Keep any edits made
                // while the asynchronous load was in flight.
                flow.captureDestinationID = refreshed.captureDestinationID
                flow.captureEntryTemplateID = refreshed.captureEntryTemplateID
                flow.capturePlacementOverride = refreshed.capturePlacementOverride
                if let routeID = refreshed.captureDestinationID,
                   library.destinations.first(where: { $0.id == routeID })?.markdownTemplatePath != nil {
                    flow.exportSettings.markdownTemplateEnabled = false
                    flow.exportSettings.markdownTemplateBookmark = nil
                    flow.exportSettings.markdownTemplateName = ""
                }
            }
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
        case .append: placement = "append"
        case .prepend: placement = "prepend"
        case .beneathHeading(let heading, _): placement = "under \(heading.title)"
        }
        return "\(target) · \(placement)"
    }

    private func settingRow(_ title: String, value: String, image: String) -> some View {
        HStack {
            Label(title, systemImage: image)
            Spacer()
            Text(value.isEmpty ? "Not set" : value)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
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
            return "Audio embeds require a Markdown note export. Switch this preset to MD, a Markdown template, or YAML with the .md extension."
        }
        return "Adds an Obsidian-style `![[recording.m4a]]` link to the note so you can replay the recording while reviewing the transcript."
    }

    private func markPerFlow() {
        flow.exportSettings.usesCustomExportSettings = true
    }

    private func chooseFolder(_ kind: BookmarkKind) {
        markPerFlow()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = kind != .markdownTemplate
        panel.canChooseFiles = kind == .markdownTemplate
        panel.allowedContentTypes = kind == .markdownTemplate ? [.plainText, .text, UTType(filenameExtension: "md") ?? .plainText] : []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
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
        frontmatter.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private static func parseFrontmatter(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty { result[key] = value }
        }
        return result
    }
}

private struct MacCaptureTextProcessingInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 30, weight: .medium))
                    .accessibilityHidden(true)
                Text("Apply to Capture Text")
                    .font(.title2.weight(.semibold))
                Spacer()
            }

            Text("When this setting is on, Vox.md uses on-device Apple Intelligence to edit captured text using the selected mode before updating your Markdown file.")

            VStack(alignment: .leading, spacing: 14) {
                infoRow(
                    icon: "checkmark.circle",
                    title: "Follows the selected mode",
                    detail: "Clean prose, create a todo checklist, format meeting notes, or follow your custom instruction."
                )
                infoRow(
                    icon: "lock.shield",
                    title: "Runs on device",
                    detail: "Your captured text is processed locally and is not sent to a cloud AI service."
                )
                infoRow(
                    icon: "doc.text",
                    title: "Keeps capture reliable",
                    detail: "If Apple Intelligence is unavailable, Vox.md uses a local fallback when possible or keeps the original text."
                )
            }

            Text("This switch applies to typed and mixed-media Capture text. Voice recordings continue to use the preset’s selected mode.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func infoRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum MacCapturePresetDestinationError: Error, LocalizedError {
    case storageUnavailable

    var errorDescription: String? {
        "Shared capture storage is unavailable."
    }
}

private struct MacFlowIconPickerView: View {
    @Binding var symbolName: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            GeistDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    selectedIconPreview

                    if filteredCategories.isEmpty {
                        Text("No matching icons")
                            .font(Geist.body())
                            .foregroundColor(Geist.muted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 48)
                    } else {
                        ForEach(filteredCategories) { category in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(category.title)
                                    .font(Geist.caption())
                                    .foregroundColor(Geist.faint)

                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(category.options) { option in
                                        iconButton(option)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Geist.bg)
        }
        .background(Geist.bg)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose Icon")
                    .font(Geist.label(.title3))
                    .foregroundColor(Geist.text)
                Text("Pick the symbol shown for this Capture Preset.")
                    .font(Geist.caption())
                    .foregroundColor(Geist.muted)
            }

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Geist.faint)
                TextField("Search icons", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Geist.body(.callout))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 230)
            .background(Geist.surface2)
            .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))

            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(20)
        .background(Geist.surface)
    }

    private var filteredCategories: [MacFlowIconCategory] {
        Self.filteredCategories(matching: searchText)
    }

    private var selectedIconPreview: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.iconName(for: symbolName))
                .font(.title2)
                .foregroundColor(Geist.text)
                .frame(width: 48, height: 48)
                .background(Geist.surface2)
                .overlay(Rectangle().stroke(Geist.borderHi, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text("Selected Icon")
                    .font(Geist.caption())
                    .foregroundColor(Geist.muted)
                Text(Self.title(for: symbolName))
                    .font(Geist.label())
                    .foregroundColor(Geist.text)
            }
            Spacer()
        }
        .padding(14)
        .background(Geist.surface)
        .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))
    }

    private func iconButton(_ option: MacFlowIconOption) -> some View {
        let selected = option.symbolName == Self.iconName(for: symbolName)
        return Button {
            symbolName = option.symbolName
            dismiss()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: option.symbolName)
                    .font(.title2)
                Text(option.title)
                    .font(Geist.caption())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .foregroundColor(selected ? Geist.text : Geist.muted)
            .frame(maxWidth: .infinity, minHeight: 82)
            .padding(.vertical, 8)
            .background(selected ? Geist.surface2 : Geist.surface)
            .overlay(Rectangle().stroke(selected ? Geist.text : Geist.border, lineWidth: selected ? 2 : 1))
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

    private static func filteredCategories(matching query: String) -> [MacFlowIconCategory] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return iconCategories }

        return iconCategories.compactMap { category in
            let matches = category.options.filter { $0.matches(trimmed) }
            guard !matches.isEmpty else { return nil }
            return MacFlowIconCategory(title: category.title, options: matches)
        }
    }

    private static let allOptions = iconCategories.flatMap(\.options)

    private static let iconCategories: [MacFlowIconCategory] = [
        MacFlowIconCategory(
            title: "Writing",
            options: [
                MacFlowIconOption("text.alignleft", "Text"),
                MacFlowIconOption("note.text", "Note"),
                MacFlowIconOption("doc.text", "Document"),
                MacFlowIconOption("doc.text.magnifyingglass", "Research"),
                MacFlowIconOption("list.bullet", "List"),
                MacFlowIconOption("quote.bubble", "Quote"),
                MacFlowIconOption("books.vertical", "Books"),
                MacFlowIconOption("bookmark", "Bookmark"),
                MacFlowIconOption("newspaper", "Article"),
                MacFlowIconOption("pencil", "Draft"),
            ]
        ),
        MacFlowIconCategory(
            title: "Voice",
            options: [
                MacFlowIconOption("mic", "Mic"),
                MacFlowIconOption("waveform", "Waveform"),
                MacFlowIconOption("wave.3.right", "Audio"),
                MacFlowIconOption("record.circle", "Record"),
                MacFlowIconOption("headphones", "Listen"),
                MacFlowIconOption("speaker.wave.2", "Speaker"),
                MacFlowIconOption("message", "Message"),
                MacFlowIconOption("bubble.left.and.text.bubble.right", "Chat"),
                MacFlowIconOption("phone", "Call"),
                MacFlowIconOption("video", "Video"),
            ]
        ),
        MacFlowIconCategory(
            title: "Tasks",
            options: [
                MacFlowIconOption("checkmark.circle", "Done"),
                MacFlowIconOption("checklist", "Checklist"),
                MacFlowIconOption("calendar", "Calendar"),
                MacFlowIconOption("bell", "Reminder"),
                MacFlowIconOption("flag", "Flag"),
                MacFlowIconOption("target", "Goal"),
                MacFlowIconOption("tray.and.arrow.down", "Inbox"),
                MacFlowIconOption("paperplane", "Send"),
                MacFlowIconOption("wand.and.stars", "Magic"),
                MacFlowIconOption("timer", "Timer"),
            ]
        ),
        MacFlowIconCategory(
            title: "Personal",
            options: [
                MacFlowIconOption("person", "Person"),
                MacFlowIconOption("person.crop.circle", "Profile"),
                MacFlowIconOption("brain.head.profile", "Thought"),
                MacFlowIconOption("heart", "Heart"),
                MacFlowIconOption("moon.stars", "Dream"),
                MacFlowIconOption("lightbulb", "Idea"),
                MacFlowIconOption("sparkles", "Sparkles"),
                MacFlowIconOption("house", "Home"),
                MacFlowIconOption("leaf", "Nature"),
                MacFlowIconOption("figure.walk", "Walk"),
            ]
        ),
        MacFlowIconCategory(
            title: "Work",
            options: [
                MacFlowIconOption("briefcase", "Work"),
                MacFlowIconOption("person.2", "People"),
                MacFlowIconOption("person.2.wave.2", "Meeting"),
                MacFlowIconOption("building.2", "Company"),
                MacFlowIconOption("chart.bar", "Stats"),
                MacFlowIconOption("rectangle.on.rectangle.angled", "Slides"),
                MacFlowIconOption("folder", "Folder"),
                MacFlowIconOption("archivebox", "Archive"),
                MacFlowIconOption("hammer", "Build"),
                MacFlowIconOption("gearshape", "Settings"),
            ]
        ),
    ]
}

private struct MacFlowIconCategory: Identifiable {
    let title: String
    let options: [MacFlowIconOption]

    var id: String { title }
}

private struct MacFlowIconOption: Identifiable {
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

// MARK: - History

struct MacHistoryView: View {
    @Bindable var viewModel: QuickCaptureViewModel
    @Environment(TranscriptStore.self) private var store
    @State private var searchText = ""
    @State private var showsClearConfirmation = false
    @State private var selectedTranscript: Transcript?

    private var unifiedItems: [MacUnifiedHistoryItem] {
        var captureByID: [UUID: CaptureHistoryRecord] = [:]
        for record in viewModel.historyRecords { captureByID[record.requestID] = record }
        let transcriptIDs = Set(store.transcripts.map(\.id))
        let transcripts = store.transcripts.map {
            MacUnifiedHistoryItem.transcript($0, delivery: captureByID[$0.id])
        }
        let captures = viewModel.historyRecords
            .filter { !transcriptIDs.contains($0.requestID) }
            .map(MacUnifiedHistoryItem.capture)
        return (transcripts + captures).sorted { $0.date > $1.date }
    }

    private var filteredItems: [MacUnifiedHistoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? unifiedItems : unifiedItems.filter { $0.matches(query) }
    }

    var body: some View {
        ZStack {
            Geist.Palette.background200.ignoresSafeArea()
            if unifiedItems.isEmpty {
                VStack(spacing: Geist.Spacing.four) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(Geist.faint)
                    Text("No History Yet")
                        .font(Geist.heading(.title))
                    Text("Record or send a Capture to create your first history item.")
                        .font(Geist.body())
                        .foregroundStyle(Geist.muted)
                }
            } else if filteredItems.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    if viewModel.failedInboxCount > 0 {
                        Section("Needs Attention") {
                            Button {
                                Task { await viewModel.retryFailedInbox() }
                            } label: {
                                Label(
                                    "Retry \(viewModel.failedInboxCount) queued capture\(viewModel.failedInboxCount == 1 ? "" : "s")",
                                    systemImage: "arrow.clockwise.circle"
                                )
                            }
                        }
                    }

                    ForEach(filteredItems) { item in
                        historyRow(item)
                            .listRowBackground(Geist.Palette.background200)
                            .listRowSeparator(.hidden)
                            .padding(.vertical, Geist.Spacing.one)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("History")
        .searchable(text: $searchText, prompt: "Search history")
        .toolbar {
            Button("Reload", systemImage: "arrow.clockwise") {
                store.reload()
                Task { await viewModel.refreshHistory() }
            }
            Button("Clear All", systemImage: "trash", role: .destructive) {
                showsClearConfirmation = true
            }
            .disabled(unifiedItems.isEmpty)
        }
        .sheet(item: $selectedTranscript) { transcript in
            NavigationStack {
                MacTranscriptDetailView(transcript: transcript)
            }
            .frame(minWidth: 680, minHeight: 560)
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                store.clear()
                Task { await viewModel.clearHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears transcript content and Capture delivery metadata. Exported Markdown notes and attachments are not deleted.")
        }
        .onAppear { store.reload() }
        .task { await viewModel.refreshHistory() }
    }

    @ViewBuilder
    private func historyRow(_ item: MacUnifiedHistoryItem) -> some View {
        switch item {
        case .transcript(let transcript, let delivery):
            VStack(alignment: .leading, spacing: Geist.Spacing.three) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                        Text(transcript.title ?? relativeDate(transcript.date))
                            .font(Geist.heading(.headline))
                        Text("\(relativeDate(transcript.date)) · \(transcript.modelUsed) · \(formatDurationShort(transcript.duration))")
                            .font(Geist.mono())
                            .foregroundStyle(Geist.muted)
                    }
                    Spacer()
                    if let delivery {
                        Label(
                            delivery.outcome == .delivered ? "Delivered" : "Failed",
                            systemImage: delivery.outcome == .delivered ? "checkmark.circle" : "exclamationmark.triangle"
                        )
                        .font(Geist.caption())
                        .foregroundStyle(delivery.outcome == .delivered ? Geist.muted : Geist.error)
                    }
                    Button("Open") { selectedTranscript = transcript }
                        .buttonStyle(.plain)
                    Button("Copy") { copyToPasteboard(transcript.cleanedText ?? transcript.text) }
                        .buttonStyle(.plain)
                    Button("Delete", role: .destructive) {
                        store.delete(ids: [transcript.id])
                        Task { await viewModel.deleteHistory(requestID: transcript.id) }
                    }
                    .buttonStyle(.plain)
                }
                Text(transcript.cleanedText ?? transcript.text)
                    .font(Geist.body())
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            .geistCard(padding: Geist.Spacing.four)
            .contentShape(RoundedRectangle(cornerRadius: Geist.Radius.medium, style: .continuous))
            .onTapGesture { selectedTranscript = transcript }
            .help("Open full transcript")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                selectedTranscript = transcript
            }

        case .capture(let record):
            HStack(alignment: .top, spacing: Geist.Spacing.three) {
                Image(systemName: record.outcome == .delivered ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(record.outcome == .delivered ? Geist.text : Geist.error)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: Geist.Spacing.two) {
                    HStack {
                        Text(record.destinationName)
                            .font(Geist.heading(.headline))
                        Spacer()
                        Text(record.deliveredAt ?? record.createdAt, style: .relative)
                            .font(Geist.caption())
                            .foregroundStyle(Geist.muted)
                    }
                    if let path = record.relativeNotePath {
                        Text(path)
                            .font(Geist.mono())
                            .foregroundStyle(Geist.muted)
                    }
                    HStack(spacing: Geist.Spacing.three) {
                        Text(record.source.rawValue.capitalized)
                        if let preset = record.voxName {
                            Label(preset, systemImage: "slider.horizontal.3")
                        }
                        if record.attachmentCount > 0 {
                            Label("\(record.attachmentCount)", systemImage: "paperclip")
                        }
                        if let failure = record.failureCategory {
                            Text(failure.displayName).foregroundStyle(Geist.error)
                        }
                        Spacer()
                        if record.outcome == .delivered, record.relativeNotePath != nil {
                            Button("Reveal") { reveal(record) }
                                .buttonStyle(.plain)
                        }
                        Button("Delete", role: .destructive) {
                            Task { await viewModel.deleteHistory(requestID: record.requestID) }
                        }
                        .buttonStyle(.plain)
                    }
                    .font(Geist.caption())
                    .foregroundStyle(Geist.faint)
                }
            }
            .geistCard(padding: Geist.Spacing.four)
        }
    }

    private func reveal(_ record: CaptureHistoryRecord) {
        Task { @MainActor in
            do {
                guard let libraryURL = AppConstants.captureLibraryURL,
                      let relativePath = record.relativeNotePath else { return }
                let library = try await CaptureLibraryStore(fileURL: libraryURL).load()
                guard let destination = library.destinations.first(where: { $0.id == record.destinationID }) else {
                    throw MacHistoryRevealError.destinationMissing
                }
                let rootResolution = try CaptureBookmarkResolver.resolve(destination.rootBookmark)
                let rootURL = rootResolution.url
                guard !rootResolution.isStale else { throw MacHistoryRevealError.permissionExpired }
                let didAccess = rootURL.startAccessingSecurityScopedResource()
                defer { if didAccess { rootURL.stopAccessingSecurityScopedResource() } }
                let noteURL = try CapturePathValidation.containedFileURL(
                    relativePath: relativePath,
                    rootURL: rootURL
                )
                NSWorkspace.shared.activateFileViewerSelecting([noteURL])
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct MacTranscriptDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let transcript: Transcript

    private var cleanedText: String? {
        guard let cleanedText = transcript.cleanedText,
              !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return cleanedText
    }

    private var displayTitle: String {
        guard let title = transcript.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "Transcript"
        }
        return title
    }

    private var primaryText: String {
        cleanedText ?? transcript.text
    }

    private var showsRawTranscript: Bool {
        guard let cleanedText else { return false }
        return cleanedText != transcript.text
    }

    var body: some View {
        ZStack {
            Geist.Palette.background200.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Geist.Spacing.six) {
                    header
                    transcriptSection(
                        cleanedText == nil ? "Transcript" : "Cleaned Transcript",
                        text: primaryText
                    )
                    if showsRawTranscript {
                        transcriptSection("Raw Transcript", text: transcript.text)
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(Geist.Spacing.six)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("History Detail")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                copyControl
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            Text(displayTitle)
                .font(Geist.heading(.title))
                .foregroundStyle(Geist.text)
                .textSelection(.enabled)

            Text(transcript.date.formatted(date: .long, time: .shortened))
                .font(Geist.mono())
                .foregroundStyle(Geist.muted)

            HStack(spacing: Geist.Spacing.four) {
                Label(formatDurationShort(transcript.duration), systemImage: "clock")
                Label(transcript.modelUsed, systemImage: "waveform")
                Label(transcript.language.uppercased(), systemImage: "globe")
                if let category = transcript.category, !category.isEmpty {
                    Label(category, systemImage: "folder")
                }
            }
            .font(Geist.caption())
            .foregroundStyle(Geist.muted)

            if let tags = transcript.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Geist.Spacing.two) {
                        ForEach(tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(Geist.caption())
                                .foregroundStyle(Geist.muted)
                                .padding(.horizontal, Geist.Spacing.three)
                                .frame(height: 28)
                                .background(Geist.Palette.gray100)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func transcriptSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            Text(title.uppercased())
                .font(Geist.mono(.caption, medium: true))
                .foregroundStyle(Geist.faint)
            Text(text)
                .font(Geist.body())
                .foregroundStyle(Geist.text)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .geistCard(padding: Geist.Spacing.six)
    }

    @ViewBuilder
    private var copyControl: some View {
        if showsRawTranscript {
            Menu("Copy", systemImage: "doc.on.doc") {
                Button("Copy Cleaned") { copyToPasteboard(primaryText) }
                Button("Copy Raw") { copyToPasteboard(transcript.text) }
            }
        } else {
            Button("Copy", systemImage: "doc.on.doc") {
                copyToPasteboard(primaryText)
            }
        }
    }
}

private enum MacUnifiedHistoryItem: Identifiable {
    case transcript(Transcript, delivery: CaptureHistoryRecord?)
    case capture(CaptureHistoryRecord)

    var id: String {
        switch self {
        case .transcript(let transcript, _): "transcript-\(transcript.id.uuidString)"
        case .capture(let record): "capture-\(record.requestID.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case .transcript(let transcript, _): transcript.date
        case .capture(let record): record.deliveredAt ?? record.createdAt
        }
    }

    func matches(_ query: String) -> Bool {
        switch self {
        case .transcript(let transcript, let delivery):
            if TranscriptSearch.matches(transcript, query: query) { return true }
            return delivery.map { Self.captureHaystack($0).localizedCaseInsensitiveContains(query) } ?? false
        case .capture(let record):
            return Self.captureHaystack(record).localizedCaseInsensitiveContains(query)
        }
    }

    private static func captureHaystack(_ record: CaptureHistoryRecord) -> String {
        [
            record.destinationName,
            record.voxName,
            record.relativeNotePath,
            record.source.rawValue,
            record.outcome.rawValue,
            record.failureCategory?.displayName,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

private enum MacHistoryRevealError: Error, LocalizedError {
    case destinationMissing
    case permissionExpired

    var errorDescription: String? {
        switch self {
        case .destinationMissing: "The Capture destination no longer exists."
        case .permissionExpired: "Folder permission expired. Reauthorize the destination in Capture Presets."
        }
    }
}

// MARK: - Settings / Paywall

struct MacSettingsView: View {
    let recorder: MacRecorder
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(MacStoreManager.self) private var storeManager
    @AppStorage(MacAppVisibilityMode.storageKey, store: AppConstants.sharedDefaults)
    private var visibilityModeRaw = MacAppVisibilityMode.dockAndMenuBar.rawValue
    @State private var showPaywall = false
    @State private var showDebug = false
    @State private var showModels = false
    @State private var showCapturePresets = false
    @State private var showEntryTemplates = false
    @State private var hotKeyFlows = CapturePresetStore.loadFlows()
    @State private var hotKeyDestinations: [CaptureDestination] = []
    @State private var hotKeyBindings: [MacHotKeyTarget: MacHotKeyShortcut] = [:]
    @State private var editingHotKeyTarget: MacHotKeyTarget?
    @State private var hotKeyStatusMessage: String?

    var body: some View {
        ZStack {
            Geist.surface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    sectionHeader("—", "Vox.md Unlimited")
                    settingsRow(
                        title: usageTracker.hasUnlocked ? "UNLIMITED UNLOCKED" : "UNLOCK UNLIMITED",
                        detail: usageTracker.hasUnlocked
                            ? "Lifetime access — no limits"
                            : String(
                                format: "%.1f / 15 min · %d / 10 captures used",
                                usageTracker.minutesUsed,
                                usageTracker.successfulCapturesUsed
                            ),
                        trailing: usageTracker.hasUnlocked ? "PURCHASED" : storeManager.displayPrice
                    )
                    if !usageTracker.hasUnlocked {
                        Button("View Upgrade Options") { showPaywall = true }
                            .buttonStyle(GeistButtonStyle(variant: .primary))
                            .padding(20)
                    }
                    sectionHeader("01", "Mac Companion")
                    settingsRow(title: "ON-DEVICE TRANSCRIPTION", detail: "Whisper and Parakeet models run locally with Metal/Core ML acceleration.", trailing: "LOCAL")
                    settingsRow(title: "APPLE INTELLIGENCE", detail: appleIntelligenceDetail, trailing: appleIntelligenceStatus)
                    settingsRow(title: "FILE EXPORT", detail: "Presets, templates, Markdown exports, and attachments use local app storage. Folder permissions stay on this Mac.", trailing: "ENABLED")
                    settingsRow(title: "KEYBOARD + LOCK SCREEN", detail: "Custom keyboard, widgets, Dynamic Island, and Live Activities remain iOS-specific.", trailing: "IOS")
                    sectionHeader("02", "Capture Configuration")
                    configurationSettings
                    sectionHeader("03", "Global Keybinds")
                    hotKeySettings
                    sectionHeader("04", "Visibility")
                    visibilitySettings
                    sectionHeader("05", "About")
                    settingsRow(title: "VERSION", detail: appVersionString, trailing: "")
                    settingsRow(title: "PROCESSING", detail: "Voice and text stay on-device.", trailing: "PRIVATE")
                    sectionHeader("06", "Debug")
                    Button("View Debug Log") { showDebug = true }
                        .buttonStyle(GeistButtonStyle(variant: .secondary))
                        .padding(20)
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showPaywall) {
            MacPaywallView().environment(usageTracker).environment(storeManager)
        }
        .sheet(isPresented: $showDebug) {
            MacDebugLogView()
        }
        .sheet(isPresented: $showModels) {
            NavigationStack { MacModelView() }
                .frame(minWidth: 760, minHeight: 620)
        }
        .sheet(isPresented: $showCapturePresets, onDismiss: {
            Task { await reloadHotKeyConfiguration() }
        }) {
            NavigationStack { MacCapturePresetSettingsView() }
                .frame(minWidth: 960, minHeight: 680)
        }
        .sheet(isPresented: $showEntryTemplates) {
            MacEntryTemplateLibraryView()
        }
        .sheet(item: $editingHotKeyTarget) { target in
            MacHotKeyRecorderSheet(
                title: hotKeyTitle(for: target),
                detail: hotKeyDetail(for: target),
                currentShortcut: hotKeyBindings[target],
                conflictingBindingName: { shortcut in
                    conflictingBindingName(for: shortcut, excluding: target)
                },
                onSave: { shortcut in saveHotKey(shortcut, for: target) },
                onClear: { clearHotKey(for: target) }
            )
        }
        .task { await reloadHotKeyConfiguration() }
    }

    private var visibilityMode: MacAppVisibilityMode {
        MacAppVisibilityMode(rawValue: visibilityModeRaw) ?? .dockAndMenuBar
    }

    private var visibilityFootnote: String {
        switch visibilityMode {
        case .dockAndMenuBar:
            return "Default. Click “Show Vox.md” from the menu bar or use Cmd-Tab."
        case .menuBarOnly:
            return "No Dock icon or Cmd-Tab entry. Click the menu bar item to reveal Vox.md."
        case .dockOnly:
            return "Use the Dock icon or Cmd-Tab to bring Vox.md forward."
        case .hidden:
            return "Fully hidden. Reopen Vox.md from Spotlight, Finder, or Launchpad to access it again."
        }
    }

    private var appleIntelligenceStatus: String {
        if #available(macOS 26, *) {
            return FoundationModelsBackend.isAvailable ? "READY" : "UNAVAILABLE"
        }
        return "MACOS 26+"
    }

    private var appleIntelligenceDetail: String {
        if #available(macOS 26, *) {
            return "Foundation Models cleans transcripts, adds titles/tags/categories, and powers smart folder routing on-device."
        }
        return "Requires macOS 26+ on an Apple Intelligence-capable Mac."
    }

    private var configurationSettings: some View {
        VStack(spacing: 0) {
            GeistDivider()
            VStack(spacing: 12) {
                Button {
                    showCapturePresets = true
                } label: {
                    settingsNavigationRow(
                        title: "Capture Presets & Destinations",
                        detail: "Configure processing, vault routes, entry formatting, attachments, and retry behavior.",
                        image: "slider.horizontal.3"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    showEntryTemplates = true
                } label: {
                    settingsNavigationRow(
                        title: "Entry Templates",
                        detail: "Create reusable Markdown and YAML formatting for routed notes.",
                        image: "doc.badge.plus"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    showModels = true
                } label: {
                    settingsNavigationRow(
                        title: "Transcription Models",
                        detail: "Download, select, and remove local Whisper or Parakeet models.",
                        image: "cpu"
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(Geist.bg)
        }
    }

    private func settingsNavigationRow(title: String, detail: String, image: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: image)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Geist.label())
                Text(detail).font(Geist.caption()).foregroundColor(Geist.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(Geist.faint)
        }
        .foregroundColor(Geist.text)
        .padding(14)
        .background(Geist.surface)
        .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))
    }

    private var visibilitySettings: some View {
        VStack(spacing: 0) {
            GeistDivider()
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose where Vox.md appears. macOS controls the Dock icon and Cmd-Tab entry together.")
                    .font(Geist.caption())
                    .foregroundColor(Geist.muted)

                VStack(spacing: 8) {
                    ForEach(MacAppVisibilityMode.allCases) { mode in
                        visibilityModeRow(mode)
                    }
                }

                Text(visibilityFootnote)
                    .font(Geist.caption())
                    .foregroundColor(Geist.faint)
            }
            .padding(20)
            .background(Geist.bg)
        }
    }

    private func visibilityModeRow(_ mode: MacAppVisibilityMode) -> some View {
        let isSelected = visibilityMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                visibilityModeRaw = mode.rawValue
            }
            mode.apply()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(isSelected ? Geist.bg : Geist.faint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(Geist.label())
                        .foregroundColor(isSelected ? Geist.bg : Geist.text)
                    Text(mode.summary)
                        .font(Geist.caption())
                        .foregroundColor(isSelected ? Geist.bg.opacity(0.72) : Geist.muted)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Geist.bg)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isSelected ? Geist.text : Geist.surface)
            .overlay(Rectangle().stroke(isSelected ? Geist.text : Geist.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var hotKeySettings: some View {
        VStack(spacing: 0) {
            GeistDivider()
            VStack(alignment: .leading, spacing: 14) {
                Text("Start or stop a recording from anywhere on macOS while Vox.md is running. Use the transcription-only keybind for temporary dictation, or assign preset keybinds to write to specific destinations.")
                    .font(Geist.caption())
                    .foregroundColor(Geist.muted)

                hotKeyRow(
                    target: .transcriptionOnly,
                    title: "Transcribe to Clipboard",
                    detail: "Copy plain text to the clipboard without creating a note, saving to History, or retaining audio."
                )

                hotKeyRow(
                    target: .selectedPreset,
                    title: "Selected Capture Preset",
                    detail: "Use whichever preset is currently selected in Capture."
                )

                if !enabledHotKeyFlows.isEmpty {
                    Text("CAPTURE PRESETS")
                        .font(Geist.caption())
                        .foregroundColor(Geist.faint)
                        .padding(.top, 4)

                    ForEach(enabledHotKeyFlows) { flow in
                        hotKeyRow(
                            target: .preset(flow.id),
                            title: flow.displayName,
                            detail: hotKeyRouteSummary(for: flow)
                        )
                    }
                }

                Text("For a fast reading workflow, configure one preset to create a New Note and another to use an Existing Note, then assign a keybind to each. Press any recording keybind again to stop the active recording.")
                    .font(Geist.caption())
                    .foregroundColor(Geist.faint)

                if let hotKeyStatusMessage {
                    Text(hotKeyStatusMessage)
                        .font(Geist.caption())
                        .foregroundColor(Geist.error)
                }
            }
            .padding(20)
            .background(Geist.bg)
        }
    }

    private var enabledHotKeyFlows: [CapturePreset] {
        hotKeyFlows.filter(\.isEnabled)
    }

    private func hotKeyRow(
        target: MacHotKeyTarget,
        title: String,
        detail: String
    ) -> some View {
        let shortcut = hotKeyBindings[target]
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Geist.label())
                    .foregroundColor(Geist.text)
                Text(detail)
                    .font(Geist.caption())
                    .foregroundColor(Geist.muted)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            Text(shortcut?.displayString ?? "OFF")
                .font(Geist.mono(.caption, medium: true))
                .foregroundColor(shortcut == nil ? Geist.faint : Geist.text)
                .frame(minWidth: 72, alignment: .trailing)

            Button(shortcut == nil ? "Set" : "Change") {
                editingHotKeyTarget = target
            }
            .buttonStyle(GeistButtonStyle(variant: .secondary, size: .small))

            if shortcut != nil {
                Button {
                    clearHotKey(for: target)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundColor(Geist.error)
                .accessibilityLabel("Clear \(title) keybind")
            }
        }
        .padding(14)
        .background(Geist.surface)
        .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))
    }

    private func hotKeyTitle(for target: MacHotKeyTarget) -> String {
        switch target {
        case .transcriptionOnly:
            return "Transcribe to Clipboard"
        case .selectedPreset:
            return "Selected Capture Preset"
        case .preset(let presetID):
            return hotKeyFlows.first(where: { $0.id == presetID })?.displayName ?? "Capture Preset"
        }
    }

    private func hotKeyDetail(for target: MacHotKeyTarget) -> String {
        switch target {
        case .transcriptionOnly:
            return "Start or stop a temporary transcription. The result is copied to the clipboard without being saved to a file or History."
        case .selectedPreset:
            return "Start or stop recording with whichever Capture Preset is currently selected."
        case .preset(let presetID):
            guard let flow = hotKeyFlows.first(where: { $0.id == presetID }) else {
                return "Start or stop recording with this Capture Preset."
            }
            return hotKeyRouteSummary(for: flow)
        }
    }

    private func hotKeyRouteSummary(for flow: CapturePreset) -> String {
        guard let destinationID = flow.captureDestinationID,
              let destination = hotKeyDestinations.first(where: { $0.id == destinationID }) else {
            return "Destination not configured."
        }

        switch destination.noteTarget {
        case .newNote(let pathTemplate):
            return "Create a new note at \(pathTemplate) in \(destination.rootName)."
        case .rollingNote(let pathTemplate, let period):
            return "Write to the \(period.rawValue) rolling note at \(pathTemplate)."
        case .existingNote(let relativePath):
            let verb: String
            switch destination.placement {
            case .append: verb = "Append to"
            case .prepend: verb = "Prepend to"
            case .beneathHeading: verb = "Insert into"
            }
            return "\(verb) \(relativePath) in \(destination.rootName)."
        }
    }

    private func conflictingBindingName(
        for shortcut: MacHotKeyShortcut,
        excluding target: MacHotKeyTarget
    ) -> String? {
        guard let conflict = MacHotKeyStore.conflictingTarget(
            for: shortcut,
            excluding: target,
            activePresetIDs: Set(enabledHotKeyFlows.map(\.id))
        ) else { return nil }
        return hotKeyTitle(for: conflict)
    }

    private func saveHotKey(_ shortcut: MacHotKeyShortcut, for target: MacHotKeyTarget) {
        MacHotKeyStore.save(shortcut, for: target)
        reloadHotKeyBindings()
        MacGlobalHotKeyCenter.shared.reloadRegistration()
        hotKeyStatusMessage = MacGlobalHotKeyCenter.shared.lastRegistrationError
        editingHotKeyTarget = nil
    }

    private func clearHotKey(for target: MacHotKeyTarget) {
        MacHotKeyStore.clear(target)
        reloadHotKeyBindings()
        MacGlobalHotKeyCenter.shared.reloadRegistration()
        hotKeyStatusMessage = MacGlobalHotKeyCenter.shared.lastRegistrationError
        editingHotKeyTarget = nil
    }

    private func reloadHotKeyBindings() {
        hotKeyBindings = Dictionary(
            uniqueKeysWithValues: MacHotKeyStore.configuredBindings().map {
                ($0.target, $0.shortcut)
            }
        )
    }

    private func reloadHotKeyConfiguration() async {
        hotKeyFlows = CapturePresetStore.loadFlows()
        reloadHotKeyBindings()
        guard let captureLibraryURL = AppConstants.captureLibraryURL else {
            hotKeyDestinations = []
            return
        }
        do {
            let library = try await CapturePresetRouteLibrary.load(
                from: CaptureLibraryStore(fileURL: captureLibraryURL)
            )
            // Loading the route library may complete legacy destination
            // ownership migration, so refresh the matching preset IDs too.
            hotKeyFlows = CapturePresetStore.loadFlows()
            hotKeyDestinations = library.destinations
        } catch {
            hotKeyDestinations = []
        }
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

private struct MacHotKeyRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let detail: String
    let currentShortcut: MacHotKeyShortcut?
    let conflictingBindingName: (MacHotKeyShortcut) -> String?
    let onSave: (MacHotKeyShortcut) -> Void
    let onClear: () -> Void

    @State private var capturedShortcut: MacHotKeyShortcut?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("Set \(title) Keybind")
                    .font(Geist.heading(.title2))
                    .foregroundColor(Geist.text)
                Text(detail)
                    .font(Geist.body())
                    .foregroundColor(Geist.muted)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Text(capturedShortcut?.displayString ?? "PRESS A KEYBIND")
                    .font(Geist.display(42))
                    .foregroundColor(Geist.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .background(Geist.surface2)
                    .overlay(Rectangle().stroke(Geist.borderHi, lineWidth: 2))

                Text("Use a letter, number, Space, arrow, or function key with ⌃ Control, ⌥ Option, or ⌘ Command. ⇧ Shift can be combined. Press Esc to cancel.")
                    .font(Geist.caption())
                    .foregroundColor(Geist.muted)
                    .multilineTextAlignment(.center)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(Geist.caption())
                    .foregroundColor(Geist.error)
            }

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(GeistButtonStyle(variant: .secondary))

                Button("Clear") { onClear() }
                    .buttonStyle(.plain)
                    .foregroundColor(Geist.error)
                    .disabled(currentShortcut == nil && capturedShortcut == nil)

                Spacer()

                Button("Save Keybind") {
                    guard let capturedShortcut else { return }
                    if let conflict = conflictingBindingName(capturedShortcut) {
                        errorMessage = "\(capturedShortcut.displayString) is already assigned to \(conflict)."
                        return
                    }
                    onSave(capturedShortcut)
                }
                .buttonStyle(GeistButtonStyle(variant: .primary))
                .disabled(capturedShortcut == nil)
            }
        }
        .padding(30)
        .frame(width: 560)
        .background(Geist.bg)
        .background(
            MacHotKeyCaptureView(
                onKeyDown: handleKeyDown,
                onFlagsChanged: handleFlagsChanged
            )
            .frame(width: 0, height: 0)
        )
        .onAppear {
            capturedShortcut = currentShortcut
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        if event.keyCode == 53 {
            dismiss()
            return
        }

        guard let shortcut = MacHotKeyShortcut(event: event) else {
            errorMessage = "Press one non-modifier key with Control, Option, or Command."
            return
        }
        if let conflict = conflictingBindingName(shortcut) {
            capturedShortcut = nil
            errorMessage = "\(shortcut.displayString) is already assigned to \(conflict)."
            return
        }

        capturedShortcut = shortcut
        errorMessage = nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(MacHotKeyShortcut.allowedModifierFlags)
        guard !modifiers.isEmpty else { return }

        if modifiers.intersection([.command, .option, .control]).isEmpty {
            errorMessage = "Shift alone cannot be used. Add Control, Option, or Command plus one non-modifier key."
        } else {
            errorMessage = "Now press a letter, number, Space, arrow, or function key to finish the shortcut."
        }
    }
}

private struct MacHotKeyCaptureView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Void
    let onFlagsChanged: (NSEvent) -> Void

    func makeNSView(context: Context) -> MacHotKeyCaptureNSView {
        let view = MacHotKeyCaptureNSView()
        view.onKeyDown = onKeyDown
        view.onFlagsChanged = onFlagsChanged
        return view
    }

    func updateNSView(_ nsView: MacHotKeyCaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
        nsView.onFlagsChanged = onFlagsChanged
        nsView.focusIfPossible()
    }
}

private final class MacHotKeyCaptureNSView: NSView, MacKeyboardHintSuppressingResponder {
    var onKeyDown: ((NSEvent) -> Void)?
    var onFlagsChanged: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfPossible()
    }

    func focusIfPossible() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }

    override func flagsChanged(with event: NSEvent) {
        onFlagsChanged?(event)
    }
}

struct MacPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(MacStoreManager.self) private var storeManager

    var body: some View {
        VStack(spacing: 22) {
            Text("Vox.md Unlimited")
                .font(Geist.heading(.title))
                .foregroundColor(Geist.text)
            Text("Unlock unlimited local Capture and private, on-device transcription across Vox.md. No subscription, no server, no ads.")
                .font(Geist.body())
                .foregroundColor(Geist.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !usageTracker.hasUnlocked {
                Text(String(
                    format: "%.1f / 15 min transcription · %d / 10 captures used",
                    usageTracker.minutesUsed,
                    usageTracker.successfulCapturesUsed
                ))
                    .font(Geist.mono(.footnote, medium: true))
                    .foregroundColor(Geist.muted)
            }
            if usageTracker.hasUnlocked {
                Text("Unlimited Unlocked")
                    .font(Geist.label())
                    .foregroundColor(Geist.text)
            } else {
                Button(storeManager.isPurchasing ? "PURCHASING…" : "UNLOCK — \(storeManager.displayPrice)") {
                    Task { await storeManager.purchase() }
                }
                .buttonStyle(GeistButtonStyle(variant: .primary))
                .frame(maxWidth: 360)
                Button(storeManager.isRestoring ? "RESTORING…" : "RESTORE PURCHASE") {
                    Task { await storeManager.restore() }
                }
                .buttonStyle(GeistButtonStyle(variant: .secondary))
                .frame(maxWidth: 360)
            }
            if let error = storeManager.errorMessage {
                Text(error)
                    .font(Geist.caption())
                    .foregroundColor(Geist.error)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .foregroundColor(Geist.muted)
        }
        .padding(36)
        .frame(width: 520)
        .background(Geist.Palette.background100)
    }
}

private struct MacDebugLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText = KeyboardDebugLog.shared.read()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Clear") {
                    KeyboardDebugLog.shared.clear()
                    logText = "(cleared)"
                }
                .foregroundColor(Geist.error)
                Spacer()
                Button("Copy") { copyToPasteboard(logText) }
                Button("Done") { dismiss() }
            }
            .padding(12)
            GeistDivider()
            ScrollView {
                Text(logText.isEmpty ? "(empty)" : logText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Geist.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(width: 760, height: 520)
        .background(Geist.Palette.background100)
    }
}

private extension CapturePresetProcessingMode {
    var helpText: String {
        switch self {
        case .none:
            return "Keeps typed Markdown, OCR, and voice text exactly as captured."
        case .clean:
            return "Improves casing and punctuation on device while preserving meaning and Markdown structure."
        case .todoList:
            return "Turns captured tasks into `- [ ]` Markdown checklist items without inventing new tasks."
        case .meetingNotes:
            return "Builds grounded Markdown meeting notes from typed text, OCR, or voice."
        case .custom:
            return "Follows your instruction on device for any Capture text when enabled."
        }
    }
}

// MARK: - Shared helpers

private func sectionHeader(_ number: String, _ title: LocalizedStringKey) -> some View {
    HStack {
        GeistSectionLabel(number: number, title: title)
        Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.top, 28)
    .padding(.bottom, 16)
    .background(Geist.bg)
}

private func settingsRow(title: String, detail: String, trailing: String) -> some View {
    VStack(spacing: 0) {
        GeistDivider()
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Geist.label())
                    .foregroundColor(Geist.text)
                Text(detail)
                    .font(Geist.caption())
                    .foregroundColor(Geist.muted)
            }
            Spacer()
            if !trailing.isEmpty {
                Text(trailing)
                    .font(Geist.caption())
                    .foregroundColor(Geist.text)
            }
        }
        .padding(20)
        .background(Geist.bg)
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private func formatDurationShort(_ d: TimeInterval) -> String {
    let s = Int(d)
    return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
}

private func relativeDate(_ date: Date) -> String {
    let diff = Date().timeIntervalSince(date)
    if diff < 60 { return "just now" }
    if diff < 3600 { return "\(Int(diff / 60))m ago" }
    if diff < 86400 { return "\(Int(diff / 3600))h ago" }
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .none
    return f.string(from: date)
}
