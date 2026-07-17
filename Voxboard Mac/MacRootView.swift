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
                Text("VOX.MD MAC")
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
                        Label(flow.displayName, systemImage: MacFlowIconPickerView.iconName(for: flow.symbolName)).tag(flow.id)
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
                statusBlock(number: "01", title: "Status", headline: "NO MIC.", detail: "Enable microphone access for Vox.md in macOS Privacy & Security, then start recording again.", color: Brutal.error)
                Button("OPEN PRIVACY SETTINGS") { openMicrophonePrivacySettings() }
                    .buttonStyle(BrutalButtonStyle(variant: .secondary))
                    .frame(maxWidth: 260)
            }
        } else if let error = recorder.lastError, !recorder.isRecording, !recorder.isTranscribing {
            VStack(spacing: 20) {
                statusBlock(number: "01", title: "Status", headline: "ERROR.", detail: error, color: Brutal.error)
                HStack(spacing: 12) {
                    if recorder.failedCaptureCount > 0 {
                        Button(recorder.isRetryingCaptures ? "RETRYING…" : "RETRY CAPTURES") {
                            Task { await recorder.processPendingCaptureInbox(retryFailed: true) }
                        }
                        .buttonStyle(BrutalButtonStyle(variant: .primary))
                        .disabled(recorder.isRetryingCaptures)
                    }
                    Button("DISMISS") { recorder.lastError = nil }
                        .buttonStyle(BrutalButtonStyle(variant: .secondary))
                }
                .frame(maxWidth: 440)
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
                        Label(flow.displayName, systemImage: MacFlowIconPickerView.iconName(for: flow.symbolName))
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
    @State private var isIconPickerPresented = false
    @State private var captureDestinations: [CaptureDestination] = []
    @State private var captureDestinationLoadError: String?
    @State private var isManagingCaptureDestinations = false

    init(flow: Binding<RecordingFlow>, onDelete: @escaping () -> Void) {
        self._flow = flow
        self.onDelete = onDelete
        self._frontmatterText = State(initialValue: Self.renderFrontmatter(flow.wrappedValue.staticFrontmatter))
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

            Section("Unified Capture Route") {
                Picker("Markdown Route", selection: $flow.captureDestinationID) {
                    Text("Legacy Vox Export").tag(Optional<UUID>.none)
                    ForEach(captureDestinations) { destination in
                        Text(destination.name).tag(Optional(destination.id))
                    }
                }
                if let destinationID = flow.captureDestinationID,
                   let destination = captureDestinations.first(where: { $0.id == destinationID }) {
                    Text("\(destination.rootName) · \(captureDestinationSummary(destination))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if flow.captureDestinationID != nil {
                    Text("This destination is missing. Choose another route or use Legacy Vox Export.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let captureDestinationLoadError {
                    Text(captureDestinationLoadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("Manage Capture Routes…") {
                    isManagingCaptureDestinations = true
                }
                Text("Unified routes add rolling notes, prepend, heading insertion, conflict-safe writes, and durable retries on this Mac and iOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if flow.captureDestinationID == nil {
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
        .sheet(isPresented: $isIconPickerPresented) {
            MacFlowIconPickerView(symbolName: $flow.symbolName)
                .frame(minWidth: 540, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $isManagingCaptureDestinations, onDismiss: {
            Task { await loadCaptureDestinations() }
        }) {
            MacCaptureDestinationLibraryView()
                .frame(minWidth: 760, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .task { await loadCaptureDestinations() }
        .onAppear { flow.exportSettings.usesCustomExportSettings = true }
        .onDisappear { flow.staticFrontmatter = Self.parseFrontmatter(frontmatterText) }
    }

    private enum BookmarkKind {
        case exportFolder, audioFolder, markdownTemplate
    }

    private func loadCaptureDestinations() async {
        guard let url = AppConstants.captureLibraryURL else {
            captureDestinationLoadError = "Shared capture storage is unavailable."
            return
        }
        do {
            captureDestinations = try await CaptureLibraryStore(fileURL: url).load().destinations
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
            return "Audio embeds require a Markdown note export. Switch this Vox to MD, a Markdown template, or YAML with the .md extension."
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

private struct MacFlowIconPickerView: View {
    @Binding var symbolName: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            BrutalDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    selectedIconPreview

                    if filteredCategories.isEmpty {
                        Text("No matching icons")
                            .font(Brutal.body())
                            .foregroundColor(Brutal.muted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 48)
                    } else {
                        ForEach(filteredCategories) { category in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(category.title.uppercased())
                                    .font(Brutal.caption())
                                    .foregroundColor(Brutal.faint)

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
            .background(Brutal.bg)
        }
        .background(Brutal.bg)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose Icon")
                    .font(Brutal.label(.title3))
                    .foregroundColor(Brutal.text)
                Text("Pick the symbol shown for this Vox.")
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
            }

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Brutal.faint)
                TextField("Search icons", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Brutal.body(.callout))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 230)
            .background(Brutal.surface2)
            .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))

            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(20)
        .background(Brutal.surface)
    }

    private var filteredCategories: [MacFlowIconCategory] {
        Self.filteredCategories(matching: searchText)
    }

    private var selectedIconPreview: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.iconName(for: symbolName))
                .font(.title2)
                .foregroundColor(Brutal.text)
                .frame(width: 48, height: 48)
                .background(Brutal.surface2)
                .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text("Selected Icon")
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
                Text(Self.title(for: symbolName))
                    .font(Brutal.label())
                    .foregroundColor(Brutal.text)
            }
            Spacer()
        }
        .padding(14)
        .background(Brutal.surface)
        .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))
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
                    .font(Brutal.caption())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .foregroundColor(selected ? Brutal.text : Brutal.muted)
            .frame(maxWidth: .infinity, minHeight: 82)
            .padding(.vertical, 8)
            .background(selected ? Brutal.surface2 : Brutal.surface)
            .overlay(Rectangle().stroke(selected ? Brutal.text : Brutal.border, lineWidth: selected ? 2 : 1))
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
    @AppStorage(MacHotKeyStore.storageKey, store: AppConstants.sharedDefaults)
    private var hotKeyStorage = ""
    @AppStorage(MacAppVisibilityMode.storageKey, store: AppConstants.sharedDefaults)
    private var visibilityModeRaw = MacAppVisibilityMode.dockAndMenuBar.rawValue
    @State private var showPaywall = false
    @State private var showDebug = false
    @State private var showHotKeyRecorder = false
    @State private var hotKeyStatusMessage: String?

    var body: some View {
        ZStack {
            Brutal.surface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    sectionHeader("—", "Vox.md Unlimited")
                    settingsRow(title: usageTracker.hasUnlocked ? "UNLIMITED UNLOCKED" : "UNLOCK UNLIMITED", detail: usageTracker.hasUnlocked ? "Lifetime access — no limits" : String(format: "%.1f / 15 min free used", usageTracker.minutesUsed), trailing: usageTracker.hasUnlocked ? "PURCHASED" : storeManager.displayPrice)
                    if !usageTracker.hasUnlocked {
                        Button("VIEW UPGRADE OPTIONS") { showPaywall = true }
                            .buttonStyle(BrutalButtonStyle(variant: .primary))
                            .padding(20)
                    }
                    sectionHeader("01", "Mac Companion")
                    settingsRow(title: "ON-DEVICE TRANSCRIPTION", detail: "Whisper and Parakeet models run locally with Metal/Core ML acceleration.", trailing: "LOCAL")
                    settingsRow(title: "APPLE INTELLIGENCE", detail: appleIntelligenceDetail, trailing: appleIntelligenceStatus)
                    settingsRow(title: "FILE EXPORT", detail: "Vox folders, templates, Markdown/YAML/JSON/TXT, and audio attachments are shared with iOS settings when the App Group is available.", trailing: "ENABLED")
                    settingsRow(title: "KEYBOARD + LOCK SCREEN", detail: "Custom keyboard, widgets, Dynamic Island, and Live Activities remain iOS-specific.", trailing: "IOS")
                    sectionHeader("02", "Global Keybind")
                    hotKeySettings
                    sectionHeader("03", "Visibility")
                    visibilitySettings
                    sectionHeader("04", "About")
                    settingsRow(title: "VERSION", detail: appVersionString, trailing: "")
                    settingsRow(title: "PROCESSING", detail: "Voice and text stay on-device.", trailing: "PRIVATE")
                    sectionHeader("05", "Debug")
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
        .sheet(isPresented: $showHotKeyRecorder) {
            MacHotKeyRecorderSheet(
                currentShortcut: currentHotKey,
                onSave: saveHotKey,
                onClear: clearHotKey
            )
        }
    }

    private var currentHotKey: MacHotKeyShortcut? {
        MacHotKeyStore.decode(hotKeyStorage)
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

    private var visibilitySettings: some View {
        VStack(spacing: 0) {
            BrutalDivider()
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose where Vox.md appears. macOS controls the Dock icon and Cmd-Tab entry together.")
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)

                VStack(spacing: 8) {
                    ForEach(MacAppVisibilityMode.allCases) { mode in
                        visibilityModeRow(mode)
                    }
                }

                Text(visibilityFootnote)
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.faint)
            }
            .padding(20)
            .background(Brutal.bg)
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
                    .foregroundColor(isSelected ? Brutal.bg : Brutal.faint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title.uppercased())
                        .font(Brutal.label())
                        .foregroundColor(isSelected ? Brutal.bg : Brutal.text)
                    Text(mode.summary)
                        .font(Brutal.caption())
                        .foregroundColor(isSelected ? Brutal.bg.opacity(0.72) : Brutal.muted)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Brutal.bg)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isSelected ? Brutal.text : Brutal.surface)
            .overlay(Rectangle().stroke(isSelected ? Brutal.text : Brutal.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var hotKeySettings: some View {
        VStack(spacing: 0) {
            BrutalDivider()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("START / STOP LISTENING")
                            .font(Brutal.label())
                            .foregroundColor(Brutal.text)
                        Text("Press your keybind from anywhere on macOS to start recording; press it again to stop and transcribe.")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.muted)
                    }
                    Spacer()
                    Text(currentHotKey?.displayString ?? "OFF")
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.text)
                }

                HStack(spacing: 12) {
                    Button(currentHotKey == nil ? "SET KEYBIND" : "CHANGE KEYBIND") {
                        showHotKeyRecorder = true
                    }
                    .buttonStyle(BrutalButtonStyle(variant: .secondary))

                    Button("CLEAR") { clearHotKey() }
                        .buttonStyle(.plain)
                        .foregroundColor(Brutal.error)
                        .disabled(currentHotKey == nil)
                }

                if let hotKeyStatusMessage {
                    Text(hotKeyStatusMessage)
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.error)
                }
            }
            .padding(20)
            .background(Brutal.bg)
        }
    }

    private func saveHotKey(_ shortcut: MacHotKeyShortcut) {
        MacHotKeyStore.save(shortcut)
        hotKeyStorage = MacHotKeyStore.encode(shortcut) ?? ""
        MacGlobalHotKeyCenter.shared.reloadRegistration()
        hotKeyStatusMessage = MacGlobalHotKeyCenter.shared.lastRegistrationError
        showHotKeyRecorder = false
    }

    private func clearHotKey() {
        MacHotKeyStore.clear()
        hotKeyStorage = ""
        MacGlobalHotKeyCenter.shared.reloadRegistration()
        hotKeyStatusMessage = nil
        showHotKeyRecorder = false
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

private struct MacHotKeyRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let currentShortcut: MacHotKeyShortcut?
    let onSave: (MacHotKeyShortcut) -> Void
    let onClear: () -> Void

    @State private var capturedShortcut: MacHotKeyShortcut?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("SET GLOBAL KEYBIND")
                    .font(Brutal.heading(.title2))
                    .foregroundColor(Brutal.text)
                Text("Choose a shortcut Vox.md will listen for while the Mac app is running.")
                    .font(Brutal.body())
                    .foregroundColor(Brutal.muted)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Text(capturedShortcut?.displayString ?? "PRESS A KEYBIND")
                    .font(Brutal.display(42))
                    .foregroundColor(Brutal.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .background(Brutal.surface2)
                    .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 2))

                Text("Use a letter, number, Space, arrow, or function key with ⌃ Control, ⌥ Option, or ⌘ Command. ⇧ Shift can be combined. Press Esc to cancel.")
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
                    .multilineTextAlignment(.center)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.error)
            }

            HStack(spacing: 12) {
                Button("CANCEL") { dismiss() }
                    .buttonStyle(BrutalButtonStyle(variant: .secondary))

                Button("CLEAR") { onClear() }
                    .buttonStyle(.plain)
                    .foregroundColor(Brutal.error)
                    .disabled(currentShortcut == nil && capturedShortcut == nil)

                Spacer()

                Button("SAVE") {
                    guard let capturedShortcut else { return }
                    onSave(capturedShortcut)
                }
                .buttonStyle(BrutalButtonStyle(variant: .primary))
                .disabled(capturedShortcut == nil)
            }
        }
        .padding(30)
        .frame(width: 560)
        .background(Brutal.bg)
        .background(
            MacHotKeyCaptureView(
                onKeyDown: handleKeyDown,
                onFlagsChanged: handleFlagsChanged
            )
            .frame(width: 0, height: 0)
        )
        .preferredColorScheme(.dark)
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

private final class MacHotKeyCaptureNSView: NSView {
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

private struct MacPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(MacStoreManager.self) private var storeManager

    var body: some View {
        VStack(spacing: 22) {
            Text("VOX.MD UNLIMITED")
                .font(Brutal.heading(.title))
                .foregroundColor(Brutal.text)
            Text("Unlock unlimited local transcription across Vox.md. No subscription, no server, no ads.")
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
            return "Saves the recognized text exactly as transcribed and skips Apple Intelligence enrichment for this Vox."
        case .clean:
            return "Uses Apple Intelligence cleanup when available. Without enrichment, the transcript remains raw."
        case .todoList:
            return "Turns spoken tasks into `- [ ]` Markdown checklist items without inventing new tasks."
        case .meetingNotes:
            return "Builds Markdown meeting notes with useful sections and best-effort action items."
        case .custom:
            return "Follows your instruction when Apple Intelligence enrichment is available."
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
