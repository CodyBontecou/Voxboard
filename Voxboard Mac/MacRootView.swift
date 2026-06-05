import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

private enum MacDestination: String, CaseIterable, Identifiable, Hashable {
    case listen = "Listen"
    case model = "Model"
    case vox = "Vox"
    case history = "History"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .listen: return "mic.fill"
        case .model: return "cpu.fill"
        case .vox: return "waveform.circle.fill"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape.fill"
        }
    }
}

struct MacRootView: View {
    @Bindable var recorder: MacRecorder
    @State private var selection: MacDestination? = .listen

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("VOXBOARD") {
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
        } detail: {
            switch selection ?? .listen {
            case .listen:
                MacHomeView(recorder: recorder)
            case .model:
                MacModelView()
            case .vox:
                MacVoxSettingsView()
            case .history:
                MacHistoryView()
            case .settings:
                MacSettingsView(recorder: recorder)
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 680)
    }
}

// MARK: - Home

private struct MacHomeView: View {
    @Environment(ModelManager.self) private var modelManager
    @Environment(TranscriptStore.self) private var transcriptStore
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(MacStoreManager.self) private var storeManager

    @Bindable var recorder: MacRecorder

    @State private var flows: [RecordingFlow] = RecordingFlowStore.loadFlows()
    @State private var selectedFlowId: String = RecordingFlowStore.selectedFlowId()
    @State private var showPaywall = false
    @State private var micPermissionGranted = true
    @State private var isRequestingMicPermission = false
    @State private var exportToastURL: URL?

    var body: some View {
        ZStack {
            Brutal.bg.ignoresSafeArea()
            BrutalGridBackground().ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                BrutalDivider()
                Spacer(minLength: 24)
                centerContent
                    .frame(maxWidth: 720)
                Spacer(minLength: 24)
                BrutalDivider()
                bottomBar
            }

            if let exportToastURL {
                MacExportToast(url: exportToastURL) {
                    NSWorkspace.shared.activateFileViewerSelecting([exportToastURL])
                    self.exportToastURL = nil
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle("Listen")
        .onAppear { reloadFlows() }
        .sheet(isPresented: $showPaywall) {
            MacPaywallView()
                .environment(usageTracker)
                .environment(storeManager)
        }
        .onChange(of: recorder.needsUnlock) { _, needsUnlock in
            if needsUnlock {
                recorder.needsUnlock = false
                showPaywall = true
            }
        }
        .onChange(of: recorder.lastExportURL) { _, url in
            guard let url else { return }
            exportToastURL = url
        }
    }

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack {
                BrutalStatusBadge(
                    label: recorder.isRecording ? "Recording" : recorder.isTranscribing ? "Transcribing" : "Ready",
                    isActive: recorder.isRecording || recorder.isTranscribing
                )
                Spacer()
                Text("VOXBOARD MAC")
                    .font(Brutal.label(.headline))
                    .foregroundColor(Brutal.text)
                Spacer()
                Text(modelManager.selectedModel?.name.uppercased() ?? "NO MODEL")
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            HStack(spacing: 10) {
                Text("VOX")
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
                Picker("Vox", selection: $selectedFlowId) {
                    ForEach(enabledFlows) { flow in
                        Label(flow.displayName, systemImage: flow.symbolName).tag(flow.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .onChange(of: selectedFlowId) { _, id in RecordingFlowStore.selectFlow(id: id) }

                Spacer()

                if !usageTracker.hasUnlocked {
                    usageMeter
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Brutal.surface.opacity(0.45))
        }
    }

    private var usageMeter: some View {
        Button { showPaywall = true } label: {
            HStack(spacing: 10) {
                Text(usageTracker.isAtLimit ? "LIMIT REACHED — UNLOCK" : String(format: "%.1f / 15 MIN FREE", usageTracker.minutesUsed))
                    .font(Brutal.caption())
                    .foregroundColor(usageTracker.isAtLimit ? Brutal.error : Brutal.muted)
                    .monospacedDigit()
                ProgressView(value: usageTracker.fractionUsed)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                    .tint(usageTracker.isAtLimit ? Brutal.error : Brutal.text)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var centerContent: some View {
        if !micPermissionGranted {
            VStack(spacing: 20) {
                statusBlock(number: "01", title: "Status", headline: "NO MIC.", detail: "Enable microphone access for Voxboard in macOS Privacy & Security, then start recording again.", color: Brutal.error)
                Button("OPEN PRIVACY SETTINGS") { openMicrophonePrivacySettings() }
                    .buttonStyle(BrutalButtonStyle(variant: .secondary))
                    .frame(maxWidth: 260)
            }
        } else if let error = recorder.lastError, !recorder.isRecording, !recorder.isTranscribing {
            VStack(spacing: 20) {
                statusBlock(number: "01", title: "Status", headline: "ERROR.", detail: error, color: Brutal.error)
                Button("DISMISS") { recorder.lastError = nil }
                    .buttonStyle(BrutalButtonStyle(variant: .secondary))
                    .frame(maxWidth: 220)
            }
        } else if recorder.isRecording {
            VStack(spacing: 24) {
                BrutalSectionLabel(number: "01", title: "Status")
                Text("RECORDING.")
                    .font(Brutal.display(56))
                    .foregroundColor(Brutal.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                Text(formatDuration(recorder.recordingDuration))
                    .font(Brutal.display(64))
                    .foregroundColor(Brutal.text)
                    .monospacedDigit()
                Text("Audio is captured locally and transcribed on this Mac.")
                    .font(Brutal.body())
                    .foregroundColor(Brutal.muted)
            }
        } else if recorder.isTranscribing {
            VStack(spacing: 24) {
                BrutalSectionLabel(number: "01", title: "Status")
                TranscribingDotsView()
                Text("Processing audio on-device")
                    .font(Brutal.body())
                    .foregroundColor(Brutal.muted)
            }
        } else if let result = recorder.lastTranscriptionResult {
            VStack(spacing: 24) {
                BrutalSectionLabel(number: "01", title: "Status")
                Text("DONE.")
                    .font(Brutal.display(56))
                    .foregroundColor(Brutal.text)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("TRANSCRIPT")
                            .font(Brutal.label())
                            .foregroundColor(Brutal.muted)
                        Spacer()
                        Button("COPY") { copyToPasteboard(result) }
                            .font(Brutal.label())
                            .foregroundColor(Brutal.text)
                            .buttonStyle(.plain)
                        Button("CLEAR") { recorder.lastTranscriptionResult = nil }
                            .font(Brutal.label())
                            .foregroundColor(Brutal.muted)
                            .buttonStyle(.plain)
                    }
                    Text(result)
                        .font(Brutal.body())
                        .foregroundColor(Brutal.text)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
                .padding(16)
                .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))
            }
        } else {
            VStack(spacing: 28) {
                BrutalSectionLabel(number: "01", title: "Status")
                Text("STANDBY.")
                    .font(Brutal.display(64))
                    .foregroundColor(Brutal.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                IdleWaveformView()
                Text("Record in-app or import an audio/video file. Vox settings, history, local models, and file exports match the iOS app.")
                    .font(Brutal.body())
                    .foregroundColor(Brutal.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if recorder.isRecording {
                Button {
                    recorder.stopAndTranscribe(modelManager: modelManager, flowId: selectedFlowId)
                } label: {
                    Label("STOP + TRANSCRIBE", systemImage: "stop.fill")
                }
                .buttonStyle(BrutalButtonStyle(variant: .destructive))
            } else {
                Button {
                    beginRecording()
                } label: {
                    Label(recordButtonTitle, systemImage: usageTracker.isAtLimit ? "lock.fill" : "mic.fill")
                }
                .buttonStyle(BrutalButtonStyle(variant: usageTracker.isAtLimit ? .destructive : .primary))
                .disabled(recorder.isTranscribing || isRequestingMicPermission)
            }

            Button {
                chooseImport()
            } label: {
                Label("IMPORT AUDIO", systemImage: "waveform")
            }
            .buttonStyle(BrutalButtonStyle(variant: .secondary))
            .disabled(recorder.isRecording || recorder.isTranscribing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var enabledFlows: [RecordingFlow] {
        let enabled = flows.filter(\.isEnabled)
        return enabled.isEmpty ? RecordingFlowStore.defaultFlows : enabled
    }

    private var recordButtonTitle: String {
        if usageTracker.isAtLimit { return "UNLOCK TO RECORD" }
        return isRequestingMicPermission ? "REQUESTING MIC…" : "START RECORDING"
    }

    private func reloadFlows() {
        flows = RecordingFlowStore.loadFlows()
        selectedFlowId = RecordingFlowStore.selectedFlowId()
    }

    private func beginRecording() {
        if usageTracker.isAtLimit {
            showPaywall = true
            return
        }

        isRequestingMicPermission = true
        Task { @MainActor in
            let granted = await AudioRecorder.requestMicrophonePermission()
            micPermissionGranted = granted
            isRequestingMicPermission = false
            guard granted else { return }
            recorder.startRecording(modelManager: modelManager, flowId: selectedFlowId)
        }
    }

    private func openMicrophonePrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            recorder.importAudioFile(from: url, modelManager: modelManager, flowId: selectedFlowId)
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
            Brutal.surface.ignoresSafeArea()
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
    }

    private func pageHeader(_ text: String) -> some View {
        Text(text)
            .font(Brutal.caption())
            .foregroundColor(Brutal.muted)
            .lineSpacing(3)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brutal.bg)
    }

    private func modelSection(_ number: String, _ title: LocalizedStringKey, models: [WhisperModelInfo]) -> some View {
        VStack(spacing: 0) {
            sectionHeader(number, title)
            BrutalDivider()
            ForEach(models) { model in
                modelRow(model)
                BrutalDivider()
            }
        }
    }

    private var languageSection: some View {
        VStack(spacing: 0) {
            sectionHeader("03", "Language")
            BrutalDivider()
            HStack {
                Text("TRANSCRIPTION LANGUAGE")
                    .font(Brutal.label())
                    .foregroundColor(Brutal.text)
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
            .background(Brutal.bg)
        }
    }

    private func modelRow(_ model: WhisperModelInfo) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.name.uppercased())
                        .font(Brutal.label())
                        .foregroundColor(Brutal.text)
                    if model.isBundled {
                        Text("BUNDLED")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
                    }
                    if model.engine.isParakeet {
                        Text("CORE ML")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))
                    }
                }
                Text(model.sizeLabel.uppercased())
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
                if let description = model.modelDescription {
                    Text(description)
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                }
            }
            Spacer()
            modelAction(model)
        }
        .padding(20)
        .background(Brutal.bg)
    }

    @ViewBuilder
    private func modelAction(_ model: WhisperModelInfo) -> some View {
        if model.isDownloaded {
            HStack(spacing: 12) {
                if modelManager.selectedModelId == model.id {
                    Text("SELECTED")
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.text)
                } else {
                    Button("SELECT") { modelManager.selectedModelId = model.id }
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.text)
                        .buttonStyle(.plain)
                }
                Button("DELETE") { modelManager.deleteModel(model) }
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.error)
                    .buttonStyle(.plain)
            }
        } else if modelManager.isDownloading[model.id] == true {
            HStack(spacing: 8) {
                ProgressView(value: modelManager.downloadProgress[model.id] ?? 0)
                    .frame(width: 110)
                    .tint(Brutal.text)
                Text("\(Int((modelManager.downloadProgress[model.id] ?? 0) * 100))%")
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
                Button("CANCEL") { modelManager.cancelDownload(model) }
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.error)
                    .buttonStyle(.plain)
            }
        } else {
            Button("↓ DOWNLOAD") { modelManager.startDownload(model) }
                .font(Brutal.caption())
                .foregroundColor(Brutal.text)
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
        }
    }
}

// MARK: - Vox Settings

private struct MacVoxSettingsView: View {
    @State private var flows: [RecordingFlow] = RecordingFlowStore.loadFlows()
    @State private var selectedFlowId: String = RecordingFlowStore.selectedFlowId()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("YOUR VOX'S")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.text)
                    Spacer()
                    Button { addFlow() } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                }
                .padding(16)
                BrutalDivider()
                List(selection: $selectedFlowId) {
                    ForEach(flows) { flow in
                        Label(flow.displayName, systemImage: flow.symbolName)
                            .tag(flow.id)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: 260)
            BrutalDivider().frame(width: 1)

            if let index = flows.firstIndex(where: { $0.id == selectedFlowId }) {
                MacFlowEditor(flow: $flows[index], onDelete: { delete(flows[index]) })
                    .id(flows[index].id)
            } else {
                Text("Select a Vox")
                    .font(Brutal.body())
                    .foregroundColor(Brutal.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Vox")
        .preferredColorScheme(.dark)
        .onAppear { reload() }
        .onChange(of: flows) { _, newValue in RecordingFlowStore.saveFlows(newValue) }
        .onChange(of: selectedFlowId) { _, id in RecordingFlowStore.selectFlow(id: id) }
    }

    private func reload() {
        flows = RecordingFlowStore.loadFlows()
        selectedFlowId = RecordingFlowStore.selectedFlowId()
    }

    private func addFlow() {
        let flow = RecordingFlowStore.makeCustomFlow()
        flows.append(flow)
        selectedFlowId = flow.id
    }

    private func delete(_ flow: RecordingFlow) {
        guard !flow.isBuiltIn else { return }
        flows.removeAll { $0.id == flow.id }
        selectedFlowId = flows.first?.id ?? RecordingFlowStore.generalId
    }
}

private struct MacFlowEditor: View {
    @Binding var flow: RecordingFlow
    let onDelete: () -> Void
    @State private var frontmatterText: String

    init(flow: Binding<RecordingFlow>, onDelete: @escaping () -> Void) {
        self._flow = flow
        self.onDelete = onDelete
        self._frontmatterText = State(initialValue: Self.renderFrontmatter(flow.wrappedValue.staticFrontmatter))
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $flow.name)
                TextField("SF Symbol", text: $flow.symbolName)
                Toggle("Enabled", isOn: $flow.isEnabled)
            }

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
                Text(flow.postProcessingMode.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("File Export") {
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

            Section("Frontmatter") {
                TextEditor(text: $frontmatterText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
                    .onChange(of: frontmatterText) { _, text in flow.staticFrontmatter = Self.parseFrontmatter(text) }
            }

            Section("Audio Export") {
                Picker("Save Audio", selection: $flow.audioSaveMode) {
                    ForEach(RecordingFlowAudioSaveMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if flow.audioSaveMode == .attachmentsFolder {
                    Button { chooseFolder(.audioFolder) } label: {
                        settingRow("Audio Export Directory", value: flow.exportSettings.audioFolderName, image: "folder")
                    }
                    TextField("Attachments Folder", text: $flow.attachmentsFolderName)
                }
            }

            if !flow.isBuiltIn {
                Section {
                    Button("Delete Vox", role: .destructive, action: onDelete)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 18)
        .navigationTitle(flow.displayName)
        .onAppear { flow.exportSettings.usesCustomExportSettings = true }
        .onDisappear { flow.staticFrontmatter = Self.parseFrontmatter(frontmatterText) }
    }

    private enum BookmarkKind {
        case exportFolder, audioFolder, markdownTemplate
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

// MARK: - History

private struct MacHistoryView: View {
    @Environment(TranscriptStore.self) private var store

    var body: some View {
        ZStack {
            Brutal.bg.ignoresSafeArea()
            if store.transcripts.isEmpty {
                VStack(spacing: 18) {
                    BrutalSectionLabel(number: "—", title: "Empty")
                    Text("NO TRANSCRIPTS.")
                        .font(Brutal.display(44))
                        .foregroundColor(Brutal.muted)
                    Text("Record or import audio to build a local transcript history.")
                        .font(Brutal.body())
                        .foregroundColor(Brutal.muted)
                }
            } else {
                List {
                    ForEach(store.transcripts) { transcript in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(transcript.title?.uppercased() ?? relativeDate(transcript.date).uppercased())
                                    .font(Brutal.label(.headline))
                                    .foregroundColor(Brutal.text)
                                Spacer()
                                Button("COPY") { copyToPasteboard(transcript.cleanedText ?? transcript.text) }
                                    .font(Brutal.caption())
                                    .buttonStyle(.plain)
                                Button("DELETE") { delete(transcript) }
                                    .font(Brutal.caption())
                                    .foregroundColor(Brutal.error)
                                    .buttonStyle(.plain)
                            }
                            Text("\(relativeDate(transcript.date)) · \(transcript.modelUsed) · \(formatDurationShort(transcript.duration))")
                                .font(Brutal.caption())
                                .foregroundColor(Brutal.muted)
                            Text(transcript.cleanedText ?? transcript.text)
                                .font(Brutal.body())
                                .foregroundColor(Brutal.text)
                                .lineLimit(6)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 10)
                        .listRowBackground(Brutal.bg)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("History")
        .toolbar {
            Button("Reload") { store.reload() }
            Button("Clear All", role: .destructive) { store.clear() }
                .disabled(store.transcripts.isEmpty)
        }
        .onAppear { store.reload() }
    }

    private func delete(_ transcript: Transcript) {
        guard let index = store.transcripts.firstIndex(where: { $0.id == transcript.id }) else { return }
        store.delete(at: IndexSet(integer: index))
    }
}

// MARK: - Settings / Paywall

private struct MacSettingsView: View {
    let recorder: MacRecorder
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(MacStoreManager.self) private var storeManager
    @State private var showPaywall = false
    @State private var showDebug = false

    var body: some View {
        ZStack {
            Brutal.surface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    sectionHeader("—", "Voxboard Unlimited")
                    settingsRow(title: usageTracker.hasUnlocked ? "UNLIMITED UNLOCKED" : "UNLOCK UNLIMITED", detail: usageTracker.hasUnlocked ? "Lifetime access — no limits" : String(format: "%.1f / 15 min free used", usageTracker.minutesUsed), trailing: usageTracker.hasUnlocked ? "PURCHASED" : storeManager.displayPrice)
                    if !usageTracker.hasUnlocked {
                        Button("VIEW UPGRADE OPTIONS") { showPaywall = true }
                            .buttonStyle(BrutalButtonStyle(variant: .primary))
                            .padding(20)
                    }
                    sectionHeader("01", "Mac Companion")
                    settingsRow(title: "ON-DEVICE TRANSCRIPTION", detail: "Whisper and Parakeet models run locally with Metal/Core ML acceleration.", trailing: "LOCAL")
                    settingsRow(title: "FILE EXPORT", detail: "Vox folders, templates, Markdown/YAML/JSON/TXT, and audio attachments are shared with iOS settings when the App Group is available.", trailing: "ENABLED")
                    settingsRow(title: "KEYBOARD + LOCK SCREEN", detail: "Custom keyboard, widgets, Dynamic Island, and Live Activities remain iOS-specific.", trailing: "IOS")
                    sectionHeader("02", "About")
                    settingsRow(title: "VERSION", detail: appVersionString, trailing: "")
                    settingsRow(title: "PROCESSING", detail: "Voice and text stay on-device.", trailing: "PRIVATE")
                    sectionHeader("03", "Debug")
                    Button("VIEW DEBUG LOG") { showDebug = true }
                        .buttonStyle(BrutalButtonStyle(variant: .secondary))
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
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

private struct MacPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(MacStoreManager.self) private var storeManager

    var body: some View {
        VStack(spacing: 22) {
            Text("VOXBOARD UNLIMITED")
                .font(Brutal.heading(.title))
                .foregroundColor(Brutal.text)
            Text("Unlock unlimited local transcription across Voxboard. No subscription, no server, no ads.")
                .font(Brutal.body())
                .foregroundColor(Brutal.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if usageTracker.hasUnlocked {
                Text("UNLIMITED UNLOCKED")
                    .font(Brutal.label())
                    .foregroundColor(Brutal.text)
            } else {
                Button(storeManager.isPurchasing ? "PURCHASING…" : "UNLOCK — \(storeManager.displayPrice)") {
                    Task { await storeManager.purchase() }
                }
                .buttonStyle(BrutalButtonStyle(variant: .primary))
                .frame(maxWidth: 360)
                Button(storeManager.isRestoring ? "RESTORING…" : "RESTORE PURCHASE") {
                    Task { await storeManager.restore() }
                }
                .buttonStyle(BrutalButtonStyle(variant: .secondary))
                .frame(maxWidth: 360)
            }
            if let error = storeManager.errorMessage {
                Text(error)
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.error)
            }
            Button("DONE") { dismiss() }
                .buttonStyle(.plain)
                .foregroundColor(Brutal.muted)
        }
        .padding(36)
        .frame(width: 520)
        .background(Brutal.bg)
        .preferredColorScheme(.dark)
    }
}

private struct MacDebugLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText = KeyboardDebugLog.shared.read()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("CLEAR") {
                    KeyboardDebugLog.shared.clear()
                    logText = "(cleared)"
                }
                .foregroundColor(Brutal.error)
                Spacer()
                Button("COPY") { copyToPasteboard(logText) }
                Button("DONE") { dismiss() }
            }
            .padding(12)
            BrutalDivider()
            ScrollView {
                Text(logText.isEmpty ? "(empty)" : logText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Brutal.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(width: 760, height: 520)
        .background(Brutal.bg)
        .preferredColorScheme(.dark)
    }
}

private extension RecordingFlowPostProcessingMode {
    var helpText: String {
        switch self {
        case .none:
            return "Saves the recognized text exactly as transcribed and skips AI enrichment for this Vox."
        case .clean:
            return "Uses the standard cleanup path when enrichment is available. Without enrichment, the transcript remains raw."
        case .todoList:
            return "Turns spoken tasks into `- [ ]` Markdown checklist items without inventing new tasks."
        case .meetingNotes:
            return "Builds Markdown meeting notes with useful sections and best-effort action items."
        case .custom:
            return "Follows your instruction when on-device enrichment is available."
        }
    }
}

// MARK: - Shared helpers

private func sectionHeader(_ number: String, _ title: LocalizedStringKey) -> some View {
    HStack {
        BrutalSectionLabel(number: number, title: title)
        Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.top, 28)
    .padding(.bottom, 16)
    .background(Brutal.bg)
}

private func settingsRow(title: String, detail: String, trailing: String) -> some View {
    VStack(spacing: 0) {
        BrutalDivider()
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Brutal.label())
                    .foregroundColor(Brutal.text)
                Text(detail)
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
            }
            Spacer()
            if !trailing.isEmpty {
                Text(trailing)
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.text)
            }
        }
        .padding(20)
        .background(Brutal.bg)
    }
}

private func statusBlock(number: String, title: LocalizedStringKey, headline: String, detail: String, color: Color) -> some View {
    VStack(spacing: 18) {
        BrutalSectionLabel(number: number, title: title)
        Text(headline)
            .font(Brutal.display(56))
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.35)
        Text(detail)
            .font(Brutal.body())
            .foregroundColor(Brutal.muted)
            .multilineTextAlignment(.center)
    }
}

private struct MacExportToast: View {
    let url: URL
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text("EXPORTED")
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                    Text(url.lastPathComponent)
                        .font(Brutal.body())
                        .foregroundColor(Brutal.text)
                        .lineLimit(1)
                }
                Text("REVEAL")
                    .font(Brutal.label())
                    .foregroundColor(Brutal.text)
            }
            .padding(12)
            .background(Brutal.surface2)
            .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private func formatDuration(_ d: TimeInterval) -> String {
    let m = Int(d) / 60
    let s = Int(d) % 60
    let t = Int((d * 10).truncatingRemainder(dividingBy: 10))
    return String(format: "%d:%02d.%d", m, s, t)
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
