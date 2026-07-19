import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

private enum MacDestination: String, CaseIterable, Identifiable, Hashable {
    case listen = "Listen"
    case model = "Model"
    case presets = "Presets"
    case history = "History"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .listen: return "mic.fill"
        case .model: return "cpu.fill"
        case .presets: return "slider.horizontal.3"
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
            case .presets:
                MacCapturePresetSettingsView()
            case .history:
                MacHistoryView()
            case .settings:
                MacSettingsView(recorder: recorder)
            }
        }
        .tint(Geist.Palette.gray1000)
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

    @State private var flows: [CapturePreset] = CapturePresetStore.loadFlows()
    @State private var selectedFlowId: String = CapturePresetStore.selectedFlowId()
    @State private var showPaywall = false
    @State private var micPermissionGranted = true
    @State private var isRequestingMicPermission = false
    @State private var exportToastURL: URL?

    var body: some View {
        ZStack {
            Geist.bg.ignoresSafeArea()
            GeistGridBackground().ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                GeistDivider()
                Spacer(minLength: 24)
                centerContent
                    .frame(maxWidth: 720)
                Spacer(minLength: 24)
                GeistDivider()
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
        .onAppear {
            reloadFlows()
            if recorder.needsUnlock {
                recorder.needsUnlock = false
                showPaywall = true
            }
        }
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
                GeistStatusBadge(
                    label: recorder.isRecording ? "Recording" : recorder.isTranscribing ? "Transcribing" : "Ready",
                    isActive: recorder.isRecording || recorder.isTranscribing
                )
                Spacer()
                Text("Vox.md for Mac")
                    .font(Geist.label(.headline))
                    .foregroundColor(Geist.text)
                Spacer()
                Text(modelManager.selectedModel?.name ?? "No Model")
                    .font(Geist.caption())
                    .foregroundColor(Geist.muted)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            HStack(spacing: 10) {
                Text("Preset")
                    .font(Geist.caption())
                    .foregroundColor(Geist.muted)
                Picker("Capture Preset", selection: $selectedFlowId) {
                    ForEach(enabledFlows) { flow in
                        Label(flow.displayName, systemImage: MacFlowIconPickerView.iconName(for: flow.symbolName)).tag(flow.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .onChange(of: selectedFlowId) { _, id in CapturePresetStore.selectFlow(id: id) }

                Spacer()

                if !usageTracker.hasUnlocked {
                    usageMeter
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Geist.surface.opacity(0.45))
        }
    }

    private var usageMeter: some View {
        Button { showPaywall = true } label: {
            HStack(spacing: 10) {
                Text(
                    usageTracker.isAtLimit || usageTracker.isCaptureAtLimit
                        ? "LIMIT REACHED — UNLOCK"
                        : String(
                            format: "%.1f / 15 MIN · %d / 10 CAPTURES",
                            usageTracker.minutesUsed,
                            usageTracker.successfulCapturesUsed
                        )
                )
                    .font(Geist.caption())
                    .foregroundColor(
                        usageTracker.isAtLimit || usageTracker.isCaptureAtLimit ? Geist.error : Geist.muted
                    )
                    .monospacedDigit()
                ProgressView(value: max(usageTracker.fractionUsed, usageTracker.captureFractionUsed))
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                    .tint(
                        usageTracker.isAtLimit || usageTracker.isCaptureAtLimit ? Geist.error : Geist.text
                    )
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var centerContent: some View {
        if !micPermissionGranted {
            VStack(spacing: 20) {
                statusBlock(number: "01", title: "Status", headline: "NO MIC.", detail: "Enable microphone access for Vox.md in macOS Privacy & Security, then start recording again.", color: Geist.error)
                Button("Open Privacy Settings") { openMicrophonePrivacySettings() }
                    .buttonStyle(GeistButtonStyle(variant: .secondary))
                    .frame(maxWidth: 260)
            }
        } else if let error = recorder.lastError, !recorder.isRecording, !recorder.isTranscribing {
            VStack(spacing: 20) {
                statusBlock(number: "01", title: "Status", headline: "ERROR.", detail: error, color: Geist.error)
                HStack(spacing: 12) {
                    if recorder.failedCaptureCount > 0 {
                        Button(recorder.isRetryingCaptures ? "RETRYING…" : "RETRY CAPTURES") {
                            Task { await recorder.processPendingCaptureInbox(retryFailed: true) }
                        }
                        .buttonStyle(GeistButtonStyle(variant: .primary))
                        .disabled(recorder.isRetryingCaptures)
                    }
                    Button("Dismiss Error") { recorder.lastError = nil }
                        .buttonStyle(GeistButtonStyle(variant: .secondary))
                }
                .frame(maxWidth: 440)
            }
        } else if recorder.isRecording {
            VStack(spacing: 24) {
                GeistSectionLabel(number: "01", title: "Status")
                Text("Recording")
                    .font(Geist.display(56))
                    .foregroundColor(Geist.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                Text(formatDuration(recorder.recordingDuration))
                    .font(Geist.display(64))
                    .foregroundColor(Geist.text)
                    .monospacedDigit()
                Text("Audio is captured locally and transcribed on this Mac.")
                    .font(Geist.body())
                    .foregroundColor(Geist.muted)
            }
        } else if recorder.isTranscribing {
            VStack(spacing: 24) {
                GeistSectionLabel(number: "01", title: "Status")
                TranscribingDotsView()
                Text("Processing audio on-device")
                    .font(Geist.body())
                    .foregroundColor(Geist.muted)
            }
        } else if let result = recorder.lastTranscriptionResult {
            VStack(spacing: 24) {
                GeistSectionLabel(number: "01", title: "Status")
                Text("Transcript Ready")
                    .font(Geist.display(56))
                    .foregroundColor(Geist.text)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Transcript")
                            .font(Geist.label())
                            .foregroundColor(Geist.muted)
                        Spacer()
                        Button("Copy") { copyToPasteboard(result) }
                            .font(Geist.label())
                            .foregroundColor(Geist.text)
                            .buttonStyle(.plain)
                        Button("Clear") { recorder.lastTranscriptionResult = nil }
                            .font(Geist.label())
                            .foregroundColor(Geist.muted)
                            .buttonStyle(.plain)
                    }
                    Text(result)
                        .font(Geist.body())
                        .foregroundColor(Geist.text)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
                .padding(16)
                .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))
            }
        } else {
            VStack(spacing: 28) {
                GeistSectionLabel(number: "01", title: "Status")
                Text("Ready to Record")
                    .font(Geist.display(64))
                    .foregroundColor(Geist.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                IdleWaveformView()
                Text("Record in-app or import an audio/video file. Capture Presets, history, local models, and file exports match the iOS app.")
                    .font(Geist.body())
                    .foregroundColor(Geist.muted)
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
                    Label("Stop and Transcribe", systemImage: "stop.fill")
                }
                .buttonStyle(GeistButtonStyle(variant: .destructive))
            } else {
                Button {
                    beginRecording()
                } label: {
                    Label(recordButtonTitle, systemImage: usageTracker.isAtLimit ? "lock.fill" : "mic.fill")
                }
                .buttonStyle(GeistButtonStyle(variant: usageTracker.isAtLimit ? .destructive : .primary))
                .disabled(recorder.isTranscribing || isRequestingMicPermission)
            }

            Button {
                chooseImport()
            } label: {
                Label("Import Audio", systemImage: "waveform")
            }
            .buttonStyle(GeistButtonStyle(variant: .secondary))
            .disabled(recorder.isRecording || recorder.isTranscribing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var enabledFlows: [CapturePreset] {
        let enabled = flows.filter(\.isEnabled)
        return enabled.isEmpty ? CapturePresetStore.defaultFlows : enabled
    }

    private var recordButtonTitle: String {
        if usageTracker.isAtLimit { return "UNLOCK TO RECORD" }
        return isRequestingMicPermission ? "REQUESTING MIC…" : "START RECORDING"
    }

    private func reloadFlows() {
        flows = CapturePresetStore.loadFlows()
        selectedFlowId = CapturePresetStore.selectedFlowId()
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
        if model.isDownloaded {
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
            Button("↓ DOWNLOAD") { modelManager.startDownload(model) }
                .font(Geist.caption())
                .foregroundColor(Geist.text)
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(Rectangle().stroke(Geist.borderHi, lineWidth: 1))
        }
    }
}

// MARK: - Capture Presets

private struct MacCapturePresetSettingsView: View {
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
                Toggle("Apply to Capture Text", isOn: $flow.captureProcessingEnabled)
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

    private func saveOwnedDestination(_ destination: CaptureDestination) async throws {
        guard let url = AppConstants.captureLibraryURL else {
            throw MacCapturePresetDestinationError.storageUnavailable
        }
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
                flow = refreshed
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

private struct MacHistoryView: View {
    @Environment(TranscriptStore.self) private var store

    var body: some View {
        ZStack {
            Geist.bg.ignoresSafeArea()
            if store.transcripts.isEmpty {
                VStack(spacing: 18) {
                    GeistSectionLabel(number: "—", title: "Empty")
                    Text("No Transcripts Yet")
                        .font(Geist.display(44))
                        .foregroundColor(Geist.muted)
                    Text("Record or import audio to build a local transcript history.")
                        .font(Geist.body())
                        .foregroundColor(Geist.muted)
                }
            } else {
                List {
                    ForEach(store.transcripts) { transcript in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(transcript.title ?? relativeDate(transcript.date))
                                    .font(Geist.label(.headline))
                                    .foregroundColor(Geist.text)
                                Spacer()
                                Button("Copy") { copyToPasteboard(transcript.cleanedText ?? transcript.text) }
                                    .font(Geist.caption())
                                    .buttonStyle(.plain)
                                Button("Delete") { delete(transcript) }
                                    .font(Geist.caption())
                                    .foregroundColor(Geist.error)
                                    .buttonStyle(.plain)
                            }
                            Text("\(relativeDate(transcript.date)) · \(transcript.modelUsed) · \(formatDurationShort(transcript.duration))")
                                .font(Geist.caption())
                                .foregroundColor(Geist.muted)
                            Text(transcript.cleanedText ?? transcript.text)
                                .font(Geist.body())
                                .foregroundColor(Geist.text)
                                .lineLimit(6)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 10)
                        .listRowBackground(Geist.bg)
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
                    settingsRow(title: "FILE EXPORT", detail: "Preset destinations, templates, Markdown/YAML/JSON/TXT, and audio attachments are shared with iOS when the App Group is available.", trailing: "ENABLED")
                    settingsRow(title: "KEYBOARD + LOCK SCREEN", detail: "Custom keyboard, widgets, Dynamic Island, and Live Activities remain iOS-specific.", trailing: "IOS")
                    sectionHeader("02", "Global Keybind")
                    hotKeySettings
                    sectionHeader("03", "Visibility")
                    visibilitySettings
                    sectionHeader("04", "About")
                    settingsRow(title: "VERSION", detail: appVersionString, trailing: "")
                    settingsRow(title: "PROCESSING", detail: "Voice and text stay on-device.", trailing: "PRIVATE")
                    sectionHeader("05", "Debug")
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
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start or Stop Listening")
                            .font(Geist.label())
                            .foregroundColor(Geist.text)
                        Text("Press your keybind from anywhere on macOS to start recording; press it again to stop and transcribe.")
                            .font(Geist.caption())
                            .foregroundColor(Geist.muted)
                    }
                    Spacer()
                    Text(currentHotKey?.displayString ?? "OFF")
                        .font(Geist.caption())
                        .foregroundColor(Geist.text)
                }

                HStack(spacing: 12) {
                    Button(currentHotKey == nil ? "SET KEYBIND" : "CHANGE KEYBIND") {
                        showHotKeyRecorder = true
                    }
                    .buttonStyle(GeistButtonStyle(variant: .secondary))

                    Button("Clear") { clearHotKey() }
                        .buttonStyle(.plain)
                        .foregroundColor(Geist.error)
                        .disabled(currentHotKey == nil)
                }

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
                Text("Set Global Keybind")
                    .font(Geist.heading(.title2))
                    .foregroundColor(Geist.text)
                Text("Choose a shortcut Vox.md will listen for while the Mac app is running.")
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

private func statusBlock(number: String, title: LocalizedStringKey, headline: String, detail: String, color: Color) -> some View {
    VStack(spacing: 18) {
        GeistSectionLabel(number: number, title: title)
        Text(headline)
            .font(Geist.display(56))
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.35)
        Text(detail)
            .font(Geist.body())
            .foregroundColor(Geist.muted)
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
                    Text("Export Ready")
                        .font(Geist.caption())
                        .foregroundColor(Geist.muted)
                    Text(url.lastPathComponent)
                        .font(Geist.body())
                        .foregroundColor(Geist.text)
                        .lineLimit(1)
                }
                Text("Reveal File")
                    .font(Geist.label())
                    .foregroundColor(Geist.text)
            }
            .padding(12)
            .background(Geist.surface2)
            .overlay(Rectangle().stroke(Geist.borderHi, lineWidth: 1))
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
