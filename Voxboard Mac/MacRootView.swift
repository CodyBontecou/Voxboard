import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

extension Notification.Name {
    static let macNavigate = Notification.Name("VoxboardMacNavigate")
    static let macShowCapture = Notification.Name("VoxboardMacShowCapture")
    static let macChooseCaptureFiles = Notification.Name("VoxboardMacChooseCaptureFiles")
    static let macClearCaptureDraft = Notification.Name("VoxboardMacClearCaptureDraft")
}

enum MacDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case capture = "Capture"
    case queue = "Recording Queue"
    case history = "History"
    case models = "Transcription Models"
    case presets = "Capture Presets"
    case templates = "Entry Templates"

    static let workDestinations: [MacDestination] = [.capture, .queue, .history]
    static let configureDestinations: [MacDestination] = [.models, .presets, .templates]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: String(localized: "Capture")
        case .queue: String(localized: "Recording Queue")
        case .history: String(localized: "History")
        case .models: String(localized: "Transcription Models")
        case .presets: String(localized: "Capture Presets")
        case .templates: String(localized: "Entry Templates")
        }
    }

    var symbol: String {
        switch self {
        case .capture: return "square.and.pencil"
        case .queue: return "waveform.circle"
        case .history: return "clock.arrow.circlepath"
        case .models: return "cpu"
        case .presets: return "slider.horizontal.3"
        case .templates: return "doc.badge.plus"
        }
    }
}

struct MacNavigationRequest: Sendable {
    let windowToken: String
    let destination: MacDestination
}

@MainActor
@Observable
final class MacNavigationState {
    var selectedDestination: MacDestination?

    init(selectedDestination: MacDestination = .capture) {
        self.selectedDestination = selectedDestination
    }

    var destination: MacDestination {
        selectedDestination ?? .capture
    }

    func select(_ destination: MacDestination) {
        selectedDestination = destination
    }
}

struct MacRootView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(ModelManager.self) private var modelManager
    @Bindable var recorder: MacRecorder
    @Bindable var quickCaptureViewModel: QuickCaptureViewModel
    let windowCoordinator: MacWindowCoordinator
    @State private var navigationState: MacNavigationState
    @State private var windowToken = UUID().uuidString

    #if DEBUG
    private static var localizationScreenshotStory: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--localization-screenshot"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    #endif

    init(
        recorder: MacRecorder,
        quickCaptureViewModel: QuickCaptureViewModel,
        windowCoordinator: MacWindowCoordinator
    ) {
        self.recorder = recorder
        self.quickCaptureViewModel = quickCaptureViewModel
        self.windowCoordinator = windowCoordinator
        #if DEBUG
        let initialDestination: MacDestination = switch Self.localizationScreenshotStory {
        case "02-history": .history
        case "04-models": .models
        case "05-presets": .presets
        default: .capture
        }
        #else
        let initialDestination: MacDestination = .capture
        #endif
        _navigationState = State(
            initialValue: MacNavigationState(selectedDestination: initialDestination)
        )
    }

    var body: some View {
        @Bindable var navigation = navigationState

        NavigationSplitView {
            List(selection: $navigation.selectedDestination) {
                navigationSection("WORK", destinations: MacDestination.workDestinations)
                navigationSection("CONFIGURE", destinations: MacDestination.configureDestinations)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
        } detail: {
            #if DEBUG
            if Self.localizationScreenshotStory == "03-settings" {
                MacSettingsView(
                    recorder: recorder,
                    usesLocalizationScreenshotLayout: true
                )
            } else {
                selectedDetail
            }
            #else
            selectedDetail
            #endif
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
        .onReceive(NotificationCenter.default.publisher(for: .macNavigate)) { notification in
            guard let request = notification.object as? MacNavigationRequest,
                  request.windowToken == windowToken else { return }
            navigationState.select(request.destination)
        }
    }

    @ViewBuilder
    private var selectedDetail: some View {
        switch navigationState.destination {
        case .capture:
            MacCaptureWorkspaceView(
                viewModel: quickCaptureViewModel,
                recorder: recorder,
                windowToken: windowToken,
                windowCoordinator: windowCoordinator,
                openHistory: { navigationState.select(.history) },
                openSettings: { openSettings() },
                openModels: { navigationState.select(.models) }
            )
        case .queue:
            RecordingQueueView(
                queue: recorder.recordingQueue,
                recoveryPresets: CapturePresetStore.loadFlows()
            ) { job, delivery in
                await recorder.recordingQueue.retry(
                    job,
                    modelID: modelManager.selectedModelId,
                    fallbackModelID: modelManager.preferredFallbackModelID,
                    replaceFallbackModelID: true,
                    language: modelManager.selectedLanguage,
                    delivery: delivery
                )
            }
        case .history:
            MacHistoryView(viewModel: quickCaptureViewModel)
        case .models:
            MacModelView()
        case .presets:
            MacCapturePresetSettingsView()
        case .templates:
            MacEntryTemplateLibraryView()
        }
    }

    private func navigationSection(
        _ title: LocalizedStringKey,
        destinations: [MacDestination]
    ) -> some View {
        Section(title) {
            ForEach(destinations) { destination in
                NavigationLink(value: destination) {
                    Label(destination.title, systemImage: destination.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .tag(destination)
            }
        }
    }
}

#if DEBUG
/// Hosts the real Mac feature surfaces without the vibrancy-backed sidebar,
/// which AppKit omits from off-screen view-cache screenshots.
struct MacLocalizationScreenshotRoot: View {
    @Bindable var recorder: MacRecorder
    @Bindable var quickCaptureViewModel: QuickCaptureViewModel
    let windowCoordinator: MacWindowCoordinator
    @State private var windowToken = UUID().uuidString

    private var story: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--localization-screenshot"),
              arguments.indices.contains(index + 1) else { return "01-capture" }
        return arguments[index + 1]
    }

    @ViewBuilder
    var body: some View {
        switch story {
        case "02-history":
            NavigationStack {
                MacHistoryView(
                    viewModel: quickCaptureViewModel,
                    screenshotFixture: .localization
                )
            }
        case "03-settings":
            MacSettingsView(
                recorder: recorder,
                usesLocalizationScreenshotLayout: true
            )
        case "04-models":
            NavigationStack { MacModelView() }
        case "05-presets":
            NavigationStack { MacCapturePresetSettingsView() }
        case "06-recording-queue":
            NavigationStack {
                RecordingQueueView(
                    queue: recorder.recordingQueue,
                    recoveryPresets: CapturePresetStore.loadFlows()
                )
            }
            .frame(minWidth: 1_180, minHeight: 760)
        case "07-capture-route-inspector":
            HStack(spacing: 0) {
                MacCaptureWorkspaceView(
                    viewModel: quickCaptureViewModel,
                    recorder: recorder,
                    windowToken: windowToken,
                    windowCoordinator: windowCoordinator,
                    openHistory: {},
                    openSettings: {},
                    openModels: {}
                )
                GeistDivider().frame(width: 1)
                MacCaptureRouteInspector(viewModel: quickCaptureViewModel)
                    .frame(width: 440)
            }
        default:
            MacCaptureWorkspaceView(
                viewModel: quickCaptureViewModel,
                recorder: recorder,
                windowToken: windowToken,
                windowCoordinator: windowCoordinator,
                openHistory: {},
                openSettings: {},
                openModels: {}
            )
        }
    }
}
#endif

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
                    pageHeader("Use a compatible model already stored on this Mac, or download a model into Vox.md. Whisper models run through whisper.cpp + Metal.")
                    if let error = modelManager.modelOperationError {
                        modelErrorBanner(error)
                    }
                    languageSection
                    modelSection("02", "Whisper Models", models: whisperModels)
                    modelSection("03", "Parakeet Models", models: parakeetModels)
                }
            }
        }
        .navigationTitle("Transcription Models")
    }

    private func pageHeader(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Geist.caption())
            .foregroundColor(Geist.muted)
            .lineSpacing(3)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Geist.bg)
    }

    private func modelErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Geist.error)
            VStack(alignment: .leading, spacing: 3) {
                Text("Model Operation Failed")
                    .font(Geist.label())
                    .foregroundStyle(Geist.text)
                Text(message)
                    .font(Geist.caption())
                    .foregroundStyle(Geist.muted)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Dismiss") {
                modelManager.modelOperationError = nil
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Geist.Palette.red100)
        .overlay(alignment: .bottom) { GeistDivider() }
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
            sectionHeader("01", "Language")
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
        let installationSource = modelManager.installationSource(for: model)
        return HStack(spacing: 12) {
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
                    if installationSource == .external {
                        Text("Existing Install")
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
                if let description = model.localizedModelDescription {
                    Text(description)
                        .font(Geist.caption())
                        .foregroundColor(Geist.muted)
                }
            }
            Spacer()
            modelAction(model, installationSource: installationSource)
        }
        .padding(20)
        .background(Geist.bg)
    }

    @ViewBuilder
    private func modelAction(
        _ model: WhisperModelInfo,
        installationSource: ModelInstallationSource?
    ) -> some View {
        if modelManager.isModelDownloaded(model) {
            HStack(spacing: 12) {
                if modelManager.selectedModelId == model.id {
                    Text("Selected")
                        .font(Geist.caption())
                        .foregroundColor(Geist.text)
                } else {
                    Button("Select") { modelManager.selectModel(model) }
                        .font(Geist.caption())
                        .foregroundColor(Geist.text)
                        .buttonStyle(.plain)
                }
                if installationSource == .external {
                    Button("Stop Using") { modelManager.forgetExternalModel(model) }
                        .font(Geist.caption())
                        .foregroundColor(Geist.error)
                        .buttonStyle(.plain)
                        .help("Stops using this model without deleting it from your Mac.")
                } else {
                    Button("Remove") { modelManager.deleteModel(model) }
                        .font(Geist.caption())
                        .foregroundColor(Geist.error)
                        .buttonStyle(.plain)
                }
            }
        } else if let state = modelManager.downloadState(for: model.id) {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 4) {
                    Group {
                        if let progress = state.fractionCompleted {
                            ProgressView(value: progress)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .frame(width: 110)
                    .tint(Geist.text)

                    Text(downloadStatusText(state))
                        .font(Geist.caption())
                        .foregroundColor(Geist.muted)
                    Text("Keep Vox.md open")
                        .font(Geist.caption(.caption))
                        .foregroundColor(Geist.faint)
                }
                Button("Cancel") { modelManager.cancelDownload(model) }
                    .font(Geist.caption())
                    .foregroundColor(Geist.error)
                    .buttonStyle(.plain)
                    .disabled(state.isCancelling)
            }
        } else {
            HStack(spacing: 8) {
                Button {
                    chooseExistingModel(model)
                } label: {
                    Text("Use Existing…")
                        .font(Geist.caption())
                        .foregroundColor(Geist.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .overlay(Rectangle().stroke(Geist.borderHi, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button {
                    modelManager.startDownload(model)
                } label: {
                    Text("Download")
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

    private func chooseExistingModel(_ model: WhisperModelInfo) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Use Existing \(model.name) Model")
        panel.prompt = String(localized: "Use Model")
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        if model.engine.isParakeet {
            panel.message = String(localized: "Choose the folder containing Preprocessor.mlmodelc, Encoder.mlmodelc, Decoder.mlmodelc, JointDecision.mlmodelc, and parakeet_vocab.json.")
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
        } else {
            panel.message = String(localized: "Choose the existing GGML .bin file for \(model.name). Vox.md will use it in place without copying it.")
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelManager.useExistingModel(model, at: url)
    }

    private func downloadStatusText(_ state: ModelDownloadState) -> String {
        switch state.phase {
        case .preparing:
            return String(localized: "Preparing…")
        case .listingFiles:
            return String(localized: "Finding files…")
        case .verifying:
            return String(localized: "Verifying…")
        case .cancelling:
            return String(localized: "Cancelling…")
        case .transferring:
            if let fileProgressDescription = state.fileProgressDescription {
                return fileProgressDescription
            }
            if let progress = state.fractionCompleted {
                return progress.formatted(.percent.precision(.fractionLength(0)))
            }
            return String(localized: "Downloading…")
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
            .background(Geist.surface)
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
        .background(Geist.surface)
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
                TextField(
                    "Name",
                    text: Binding(
                        get: { flow.displayName },
                        set: { flow.name = $0 }
                    )
                )
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
                TextField(
                    "Empty Capture Prompt",
                    text: Binding(
                        get: { flow.displayCapturePrompt },
                        set: { flow.capturePrompt = $0 }
                    )
                )
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

            Section("Location") {
                Toggle("Use Current Location", isOn: $flow.locationPolicy.isEnabled)
                    .accessibilityIdentifier("mac_preset_location_enabled")

                if flow.locationPolicy.isEnabled {
                    Text("Entry formatting can use {location} without writing additional metadata.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Precision", selection: $flow.locationPolicy.precision) {
                        Text("Exact").tag(CaptureLocationPrecision.exact)
                        Text("City").tag(CaptureLocationPrecision.city)
                    }
                    .accessibilityIdentifier("mac_preset_location_precision")
                    Picker("When Location Is Unavailable", selection: $flow.locationPolicy.unavailableBehavior) {
                        Text("Ask").tag(CaptureLocationUnavailableBehavior.ask)
                        Text("Send Without Location").tag(CaptureLocationUnavailableBehavior.sendWithoutLocation)
                        Text("Cancel Capture").tag(CaptureLocationUnavailableBehavior.cancel)
                    }
                    .accessibilityIdentifier("mac_preset_location_unavailable_behavior")
                    Toggle("Write Location Metadata", isOn: $flow.locationPolicy.metadataOutputEnabled)
                        .accessibilityIdentifier("mac_preset_location_metadata_output_enabled")

                    if flow.locationPolicy.metadataOutputEnabled {
                        Picker("Configuration", selection: $flow.locationPolicy.outputMode) {
                            Text("Structured Fields").tag(CaptureLocationOutputMode.structured)
                            Text("Advanced YAML Template")
                                .tag(CaptureLocationOutputMode.advancedTemplate)
                                .disabled(flow.metadataScope == .entry)
                        }
                        .accessibilityIdentifier("mac_preset_location_output_mode")

                        if flow.locationPolicy.outputMode == .advancedTemplate,
                           flow.metadataScope == .entry {
                            Label(
                                String(localized: "Advanced YAML Template") + " · " + String(localized: "Use Note Frontmatter Scope"),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("mac_preset_location_scope_error")
                            Button("Use Note Frontmatter Scope") {
                                flow.metadataScope = .document
                            }
                        }

                        if flow.metadataScope == .document {
                            TextField("Name", text: $flow.locationPolicy.collectionKey)
                                .font(.system(.body, design: .monospaced))
                                .accessibilityIdentifier("mac_preset_location_collection_key")
                            Text("Each Capture is appended to this collection by Capture ID, so a note can retain multiple locations without replacing earlier ones.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Inline Entry Fields writes the selected `key:: value` fields beside each captured entry. No frontmatter collection is written.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if flow.locationPolicy.outputMode == .structured {
                            ForEach(CaptureLocationField.allCases, id: \.self) { field in
                                Toggle(field.configurationDisplayName, isOn: locationFieldSelection(field))
                                if flow.locationPolicy.structuredFields.contains(where: { $0.field == field }) {
                                    TextField("Output", text: locationOutputKey(field))
                                        .font(.system(.body, design: .monospaced))
                                        .accessibilityLabel(
                                            String(localized: "Output") + " · " + field.configurationDisplayName
                                        )
                                        .accessibilityIdentifier("mac_preset_location_key_\(field.rawValue)")
                                }
                            }
                        } else {
                            TextEditor(text: $flow.locationPolicy.advancedTemplate)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 160)
                                .accessibilityLabel("Advanced YAML Template")
                                .accessibilityIdentifier("mac_preset_location_advanced_template")
                            Text("Nested mappings and list items are supported. Use placeholders such as `{{coordinates}}`, `{{city}}`, `{{timestamp}}`, and `{{id}}`.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        locationPolicyPreview

                        Text("Place, city, region, and country use Apple's system reverse geocoder only when selected and may make a network request.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No frontmatter collection or inline location fields will be written. The {location} template token still works.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Provider links disclose the privacy-adjusted coordinates to Apple, Google, or OpenStreetMap only when you open a link.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Reset Location Unavailable Choice") {
                    flow.locationPolicy.unavailableBehavior = .ask
                }
                .disabled(flow.locationPolicy.unavailableBehavior == .ask)
                .accessibilityIdentifier("mac_preset_location_reset_unavailable")

                Button("Reset Location Configuration", role: .destructive) {
                    flow.locationPolicy = CapturePresetLocationPolicy()
                }
                .accessibilityIdentifier("mac_preset_location_reset_configuration")
                Text("Location is requested once at Capture send or recording stop. Exact keeps the origin fix; City rounds coordinates and omits a point-of-interest label. Vox.md does not track location in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Voice Processing") {
                Toggle("Identify Speakers", isOn: $flow.speakerDiarizationEnabled)
                    .accessibilityIdentifier("mac_preset_identify_speakers")
                if flow.speakerDiarizationEnabled {
                    Label("Speaker labels are added after transcription.", systemImage: "person.2.wave.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Detects and labels multiple voices entirely on device. The speaker model downloads the first time this preset uses it. Identification is best-effort; if it cannot run, Vox.md keeps the normal transcript and shows why in History.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func locationFieldSelection(_ field: CaptureLocationField) -> Binding<Bool> {
        Binding(
            get: { flow.locationPolicy.structuredFields.contains(where: { $0.field == field }) },
            set: { isSelected in
                flow.locationPolicy.structuredFields.removeAll { $0.field == field }
                if isSelected {
                    flow.locationPolicy.structuredFields.append(
                        CaptureLocationStructuredField(field: field)
                    )
                }
            }
        )
    }

    private func locationOutputKey(_ field: CaptureLocationField) -> Binding<String> {
        Binding(
            get: {
                flow.locationPolicy.structuredFields.first(where: { $0.field == field })?.outputKey
                    ?? field.rawValue
            },
            set: { value in
                guard let index = flow.locationPolicy.structuredFields.firstIndex(where: {
                    $0.field == field
                }) else { return }
                flow.locationPolicy.structuredFields[index].outputKey = value
            }
        )
    }

    @ViewBuilder
    private var locationPolicyPreview: some View {
        switch CaptureLocationConfigurationPreview.result(
            profile: flow.captureProfile,
            source: .mac
        ) {
        case .success(let preview):
            VStack(alignment: .leading, spacing: 6) {
                Label("Delivery Preview", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("mac_preset_location_preview")
        case .failure(let error):
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("mac_preset_location_validation_error")
        }
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
            captureDestinationLoadError = String(localized: "Shared capture storage is unavailable.")
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
        case .rollingNote(let path, let period):
            target = String(localized: "\(period.rawValue.capitalized): \(path)")
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

    private func settingRow(_ title: LocalizedStringKey, value: String, image: String) -> some View {
        HStack {
            Label(title, systemImage: image)
            Spacer()
            Text(value.isEmpty ? String(localized: "Not set") : value)
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
            return String(localized: "Adds an Obsidian-style audio link to the unified Markdown note at the selected position.")
        }
        guard markdownAudioEmbedAvailable else {
            return String(localized: "Audio embeds require a Markdown note export. Switch this preset to MD, a Markdown template, or YAML with the .md extension.")
        }
        return String(localized: "Adds an Obsidian-style `![[recording.m4a]]` link to the note so you can replay the recording while reviewing the transcript.")
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

    private func infoRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
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
        let title = allOptions.first(where: { $0.symbolName == iconName })?.title ?? iconName
        return title == "Waveform"
            ? String(localized: "Waveform", bundle: .main)
            : title
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
    #if DEBUG
    private let screenshotFixture: MacHistoryScreenshotFixture?
    #endif
    @State private var searchText = ""
    @State private var showsClearConfirmation = false
    @State private var isClearingHistory = false
    @State private var selectedItemID: UUID?

    #if DEBUG
    fileprivate init(
        viewModel: QuickCaptureViewModel,
        screenshotFixture: MacHistoryScreenshotFixture? = nil
    ) {
        self.viewModel = viewModel
        self.screenshotFixture = screenshotFixture
    }
    #else
    init(viewModel: QuickCaptureViewModel) {
        self.viewModel = viewModel
    }
    #endif

    private var historyTranscripts: [Transcript] {
        #if DEBUG
        if let screenshotFixture { return screenshotFixture.transcripts }
        #endif
        return store.transcripts
    }

    private var historyRecords: [CaptureHistoryRecord] {
        #if DEBUG
        if let screenshotFixture { return screenshotFixture.records }
        #endif
        return viewModel.historyRecords
    }

    private var usesScreenshotFixture: Bool {
        #if DEBUG
        screenshotFixture != nil
        #else
        false
        #endif
    }

    private var unifiedItems: [MacUnifiedHistoryItem] {
        var captureByID: [UUID: CaptureHistoryRecord] = [:]
        for record in historyRecords { captureByID[record.requestID] = record }
        let transcriptIDs = Set(historyTranscripts.map(\.id))
        let transcripts = historyTranscripts.map {
            MacUnifiedHistoryItem.transcript($0, delivery: captureByID[$0.id])
        }
        let captures = historyRecords
            .filter { !transcriptIDs.contains($0.requestID) }
            .map(MacUnifiedHistoryItem.capture)
        return (transcripts + captures).sorted { $0.date > $1.date }
    }

    private var filteredItems: [MacUnifiedHistoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? unifiedItems : unifiedItems.filter { $0.matches(query) }
    }

    private var selectedItem: MacUnifiedHistoryItem? {
        guard let selectedItemID else { return nil }
        return unifiedItems.first(where: { $0.id == selectedItemID })
    }

    var body: some View {
        HStack(spacing: 0) {
            historyCollection
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 420)
            GeistDivider().frame(width: 1)
            historyDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Geist.Palette.background200)
        .navigationTitle("History")
        .toolbar {
            Button("Reload", systemImage: "arrow.clockwise") {
                reloadHistory()
            }
            Button("Clear All", systemImage: "trash", role: .destructive) {
                showsClearConfirmation = true
            }
            .disabled(unifiedItems.isEmpty)
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                isClearingHistory = true
                selectedItemID = nil
                store.clear()
                Task {
                    await viewModel.clearHistory()
                    isClearingHistory = false
                    reconcileSelection()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears transcript content and Capture delivery metadata. Exported Markdown notes and attachments are not deleted.")
        }
        .onAppear {
            guard !usesScreenshotFixture else {
                reconcileSelection()
                return
            }
            store.reload()
            reconcileSelection()
        }
        .task {
            guard !usesScreenshotFixture else {
                reconcileSelection()
                return
            }
            await viewModel.refreshHistory()
            reconcileSelection()
        }
        .onChange(of: searchText) { _, _ in
            reconcileSelection(requiringVisibleItem: true)
        }
        .onChange(of: unifiedItems.map(\.id)) { _, _ in
            reconcileSelection(requiringVisibleItem: true)
        }
    }

    private var historyCollection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("HISTORY")
                    .font(Geist.label())
                    .foregroundStyle(Geist.text)
                Spacer()
                if !unifiedItems.isEmpty {
                    Text(unifiedItems.count, format: .number)
                        .font(Geist.caption())
                        .foregroundStyle(Geist.muted)
                }
            }
            .padding(16)
            GeistDivider()

            Group {
                if unifiedItems.isEmpty && viewModel.failedInboxCount == 0 {
                    ContentUnavailableView(
                        "No History Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Record or send a Capture to create your first history item.")
                    )
                } else if filteredItems.isEmpty && viewModel.failedInboxCount == 0 {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(selection: $selectedItemID) {
                        if viewModel.failedInboxCount > 0 {
                            Section("Needs Attention") {
                                Button {
                                    Task { await viewModel.retryFailedInbox() }
                                } label: {
                                    Label(
                                        viewModel.failedInboxCount == 1
                                            ? String(localized: "Retry 1 queued capture")
                                            : String(localized: "Retry \(viewModel.failedInboxCount) queued captures"),
                                        systemImage: "arrow.clockwise.circle"
                                    )
                                }
                            }
                        }

                        if !filteredItems.isEmpty {
                            Section("Recent") {
                                ForEach(filteredItems) { item in
                                    historyRow(item)
                                        .tag(item.id)
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Geist.surface)
        .searchable(text: $searchText, prompt: "Search history")
    }

    @ViewBuilder
    private var historyDetail: some View {
        if let selectedItem {
            switch selectedItem {
            case .transcript(let transcript, let delivery):
                MacTranscriptDetailView(
                    transcript: transcript,
                    delivery: delivery,
                    onReveal: { record in reveal(record) },
                    onDelete: { deleteTranscript(transcript) }
                )
            case .capture(let record):
                MacCaptureHistoryDetailView(
                    record: record,
                    onReveal: { reveal(record) },
                    onDelete: { deleteCapture(record) }
                )
            }
        } else {
            ContentUnavailableView(
                unifiedItems.isEmpty ? "No History Yet" : "Select a History Item",
                systemImage: unifiedItems.isEmpty ? "clock.arrow.circlepath" : "sidebar.left",
                description: Text(
                    unifiedItems.isEmpty
                        ? "Record or send a Capture to create your first history item."
                        : "Choose a transcript or delivery record from the list."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func historyRow(_ item: MacUnifiedHistoryItem) -> some View {
        switch item {
        case .transcript(let transcript, let delivery):
            HStack(alignment: .top, spacing: Geist.Spacing.three) {
                Image(systemName: "waveform")
                    .foregroundStyle(historyRowSecondaryColor(for: item))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                    Text(transcript.title ?? relativeDate(transcript.date))
                        .font(Geist.label())
                        .lineLimit(1)
                    Text("\(relativeDate(transcript.date)) · \(formatDurationShort(transcript.duration))")
                        .font(Geist.caption())
                        .foregroundStyle(historyRowSecondaryColor(for: item))
                        .lineLimit(1)
                    Text(transcript.cleanedText ?? transcript.text)
                        .font(Geist.caption())
                        .foregroundStyle(historyRowTertiaryColor(for: item))
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if let delivery {
                    Image(systemName: delivery.outcome == .delivered
                          ? "checkmark.circle.fill"
                          : "exclamationmark.triangle.fill")
                        .foregroundStyle(
                            selectedItemID == item.id
                                ? Color.white.opacity(0.9)
                                : (delivery.outcome == .delivered ? Geist.muted : Geist.error)
                        )
                        .help(delivery.outcome == .delivered ? "Delivered" : "Failed")
                }
            }
            .padding(.vertical, Geist.Spacing.two)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)

        case .capture(let record):
            HStack(alignment: .top, spacing: Geist.Spacing.three) {
                Image(systemName: record.outcome == .delivered
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
                    .foregroundStyle(
                        selectedItemID == item.id
                            ? Color.white.opacity(0.9)
                            : (record.outcome == .delivered ? Geist.muted : Geist.error)
                    )
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                    Text(record.destinationName)
                        .font(Geist.label())
                        .lineLimit(1)
                    Text(record.deliveredAt ?? record.createdAt, style: .relative)
                        .font(Geist.caption())
                        .foregroundStyle(historyRowSecondaryColor(for: item))
                    Text(record.relativeNotePath
                         ?? record.failureCategory?.displayName
                         ?? String(localized: "Capture delivery"))
                        .font(Geist.caption())
                        .foregroundStyle(
                            selectedItemID == item.id
                                ? Color.white.opacity(0.82)
                                : (record.failureCategory == nil ? Geist.faint : Geist.error)
                        )
                        .lineLimit(2)
                }
            }
            .padding(.vertical, Geist.Spacing.two)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
    }

    private func historyRowSecondaryColor(for item: MacUnifiedHistoryItem) -> Color {
        selectedItemID == item.id ? Color.white.opacity(0.9) : Geist.muted
    }

    private func historyRowTertiaryColor(for item: MacUnifiedHistoryItem) -> Color {
        selectedItemID == item.id ? Color.white.opacity(0.78) : Geist.faint
    }

    private func reloadHistory() {
        store.reload()
        reconcileSelection(requiringVisibleItem: true)
        Task {
            await viewModel.refreshHistory()
            reconcileSelection(requiringVisibleItem: true)
        }
    }

    private func deleteTranscript(_ transcript: Transcript) {
        selectFallback(removing: transcript.id)
        store.delete(ids: [transcript.id])
        Task {
            await viewModel.deleteHistory(requestID: transcript.id)
            reconcileSelection(requiringVisibleItem: true)
        }
    }

    private func deleteCapture(_ record: CaptureHistoryRecord) {
        selectFallback(removing: record.requestID)
        Task {
            await viewModel.deleteHistory(requestID: record.requestID)
            reconcileSelection(requiringVisibleItem: true)
        }
    }

    private func selectFallback(removing itemID: UUID) {
        let candidates = filteredItems
        guard let index = candidates.firstIndex(where: { $0.id == itemID }) else {
            selectedItemID = candidates.first(where: { $0.id != itemID })?.id
            return
        }
        let remaining = candidates.filter { $0.id != itemID }
        guard !remaining.isEmpty else {
            selectedItemID = nil
            return
        }
        selectedItemID = remaining[min(index, remaining.count - 1)].id
    }

    private func reconcileSelection(requiringVisibleItem: Bool = false) {
        guard !isClearingHistory else {
            selectedItemID = nil
            return
        }
        let candidates = requiringVisibleItem ? filteredItems : unifiedItems
        guard !candidates.isEmpty else {
            selectedItemID = nil
            return
        }
        if let selectedItemID,
           candidates.contains(where: { $0.id == selectedItemID }) {
            return
        }
        self.selectedItemID = candidates.first?.id
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
    let transcript: Transcript
    let delivery: CaptureHistoryRecord?
    let onReveal: (CaptureHistoryRecord) -> Void
    let onDelete: () -> Void

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
            return String(localized: "Transcript")
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
                    if let delivery {
                        MacCaptureDeliveryMetadataView(record: delivery, onReveal: onReveal)
                    }
                    transcriptSection(
                        cleanedText == nil
                            ? String(localized: "Transcript")
                            : String(localized: "Cleaned Transcript"),
                        text: primaryText
                    )
                    if showsRawTranscript {
                        transcriptSection(String(localized: "Raw Transcript"), text: transcript.text)
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(Geist.Spacing.six)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("History Detail")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            HStack(alignment: .top, spacing: Geist.Spacing.four) {
                Text(displayTitle)
                    .font(Geist.heading(.title))
                    .foregroundStyle(Geist.text)
                    .textSelection(.enabled)
                Spacer()
                copyControl
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }

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
                if transcript.speakerCount > 0 {
                    Label("\(transcript.speakerCount) speaker\(transcript.speakerCount == 1 ? "" : "s")", systemImage: "person.2.wave.2")
                }
            }
            .font(Geist.caption())
            .foregroundStyle(Geist.muted)

            if let reason = transcript.speakerDiarizationSkipReason {
                Label(reason.displayText, systemImage: "exclamationmark.triangle")
                    .font(Geist.caption())
                    .foregroundStyle(Geist.error)
            }

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

private struct MacCaptureHistoryDetailView: View {
    let record: CaptureHistoryRecord
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack {
            Geist.Palette.background200.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Geist.Spacing.six) {
                    HStack(alignment: .top, spacing: Geist.Spacing.four) {
                        VStack(alignment: .leading, spacing: Geist.Spacing.two) {
                            Text(record.destinationName)
                                .font(Geist.heading(.title))
                                .foregroundStyle(Geist.text)
                                .textSelection(.enabled)
                            Label(
                                record.outcome == .delivered
                                    ? String(localized: "Delivered")
                                    : String(localized: "Failed"),
                                systemImage: record.outcome == .delivered
                                    ? "checkmark.circle.fill"
                                    : "exclamationmark.triangle.fill"
                            )
                            .font(Geist.label())
                            .foregroundStyle(record.outcome == .delivered ? Geist.muted : Geist.error)
                        }
                        Spacer()
                        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                    MacCaptureDeliveryMetadataView(record: record) { _ in onReveal() }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(Geist.Spacing.six)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Capture Delivery")
    }
}

private struct MacCaptureDeliveryMetadataView: View {
    let record: CaptureHistoryRecord
    let onReveal: (CaptureHistoryRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            HStack {
                Text("DELIVERY")
                    .font(Geist.mono(.caption, medium: true))
                    .foregroundStyle(Geist.faint)
                Spacer()
                if record.outcome == .delivered, record.relativeNotePath != nil {
                    Button("Reveal in Finder", systemImage: "folder") {
                        onReveal(record)
                    }
                    .buttonStyle(.plain)
                }
            }
            LabeledContent("Status") {
                Label(
                    record.outcome == .delivered
                        ? String(localized: "Delivered")
                        : String(localized: "Failed"),
                    systemImage: record.outcome == .delivered
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(record.outcome == .delivered ? Geist.muted : Geist.error)
            }
            LabeledContent("Destination", value: record.destinationName)
            LabeledContent("Created", value: record.createdAt.formatted(date: .long, time: .shortened))
            if let deliveredAt = record.deliveredAt {
                LabeledContent("Delivered", value: deliveredAt.formatted(date: .long, time: .shortened))
            }
            LabeledContent("Source", value: record.source.rawValue.capitalized)
            if let preset = record.voxName {
                LabeledContent("Capture Preset", value: preset)
            }
            if let path = record.relativeNotePath {
                LabeledContent("Note Path") {
                    Text(path)
                        .font(Geist.mono())
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Attachments", value: record.attachmentCount.formatted())
            if let failure = record.failureCategory {
                LabeledContent("Failure") {
                    Text(failure.displayName)
                        .foregroundStyle(Geist.error)
                }
            }
        }
        .font(Geist.body())
        .geistCard(padding: Geist.Spacing.six)
    }
}

#if DEBUG
private struct MacHistoryScreenshotFixture {
    let transcripts: [Transcript]
    let records: [CaptureHistoryRecord]

    static let localization: MacHistoryScreenshotFixture = {
        let transcriptID = UUID(uuidString: "2D94C0A1-1E73-4D82-A669-92D872E3AE25")!
        let captureOnlyID = UUID(uuidString: "C0296E2C-52DE-4025-B7AA-382236D4224C")!
        let destinationID = UUID(uuidString: "7E3E8CC2-405C-4399-B45B-674BE10F59E5")!
        let transcriptDate = Date().addingTimeInterval(-18 * 60)
        let transcript = Transcript(
            id: transcriptID,
            text: "so we need to ship the mac navigation update this week and then verify the screenshots",
            date: transcriptDate,
            duration: 94,
            modelUsed: "Parakeet v2",
            language: "en",
            speakerTurns: [
                TranscriptSpeakerTurn(
                    speaker: 0,
                    text: "We need to ship the Mac navigation update this week.",
                    startTime: 0,
                    endTime: 4.2
                ),
                TranscriptSpeakerTurn(
                    speaker: 1,
                    text: "Then verify the screenshots.",
                    startTime: 4.4,
                    endTime: 6.8
                ),
            ],
            title: "Mac navigation review",
            tags: ["macos", "release"],
            category: "Work",
            cleanedText: "We need to ship the Mac navigation update this week, then verify the screenshots."
        )
        let delivered = try! CaptureHistoryRecord(
            requestID: transcriptID,
            createdAt: transcriptDate,
            deliveredAt: transcriptDate.addingTimeInterval(98),
            source: .voice,
            outcome: .delivered,
            destinationID: destinationID,
            destinationName: "Product Notes",
            voxID: "meeting-notes",
            voxName: "Meeting Notes",
            relativeNotePath: "Meetings/2026-08-31.md",
            attachmentCount: 1
        )
        let failed = try! CaptureHistoryRecord(
            requestID: captureOnlyID,
            createdAt: Date().addingTimeInterval(-52 * 60),
            deliveredAt: nil,
            source: .mac,
            outcome: .failed,
            destinationID: destinationID,
            destinationName: "Daily Notes",
            voxID: "quick-note",
            voxName: "Quick Note",
            relativeNotePath: nil,
            attachmentCount: 2,
            failureCategory: .permissionDenied
        )
        return MacHistoryScreenshotFixture(
            transcripts: [transcript],
            records: [delivered, failed]
        )
    }()
}
#endif

private enum MacUnifiedHistoryItem: Identifiable {
    case transcript(Transcript, delivery: CaptureHistoryRecord?)
    case capture(CaptureHistoryRecord)

    /// Transcript and delivery records share the same request UUID, so
    /// selection survives a reload that promotes a capture-only row into a
    /// full transcript without changing identity.
    var id: UUID {
        switch self {
        case .transcript(let transcript, _): transcript.id
        case .capture(let record): record.requestID
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
        case .destinationMissing: String(localized: "The Capture destination no longer exists.")
        case .permissionExpired: String(localized: "Folder permission expired. Reauthorize the destination in Capture Presets.")
        }
    }
}

// MARK: - Settings / Paywall

private enum MacSettingsDestination: String, CaseIterable, Identifiable {
    case access
    case general
    case shortcuts
    case diagnostics
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .access: String(localized: "Access")
        case .general: String(localized: "General")
        case .shortcuts: String(localized: "Shortcuts")
        case .diagnostics: String(localized: "Diagnostics")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .access: "person.badge.key"
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
}

struct MacSettingsView: View {
    let recorder: MacRecorder
    #if DEBUG
    private let usesLocalizationScreenshotLayout: Bool
    #endif
    @Environment(MacStoreManager.self) private var storeManager
    @AppStorage(MacAppVisibilityMode.storageKey, store: AppConstants.sharedDefaults)
    private var visibilityModeRaw = MacAppVisibilityMode.dockAndMenuBar.rawValue
    @State private var selectedDestination: MacSettingsDestination = .access
    @State private var hotKeyFlows = CapturePresetStore.loadFlows()
    @State private var hotKeyDestinations: [CaptureDestination] = []
    @State private var hotKeyBindings: [MacHotKeyTarget: MacHotKeyShortcut] = [:]
    @State private var editingHotKeyTarget: MacHotKeyTarget?
    @State private var hotKeyStatusMessage: String?

    #if DEBUG
    init(
        recorder: MacRecorder,
        usesLocalizationScreenshotLayout: Bool = false
    ) {
        self.recorder = recorder
        self.usesLocalizationScreenshotLayout = usesLocalizationScreenshotLayout
    }
    #else
    init(recorder: MacRecorder) {
        self.recorder = recorder
    }
    #endif

    @ViewBuilder
    var body: some View {
        #if DEBUG
        if usesLocalizationScreenshotLayout {
            localizationScreenshotSettings
        } else {
            settingsNavigation
        }
        #else
        settingsNavigation
        #endif
    }

    private var settingsNavigation: some View {
        NavigationSplitView {
            List(selection: $selectedDestination) {
                ForEach(MacSettingsDestination.allCases) { destination in
                    Label(destination.title, systemImage: destination.symbol)
                        .tag(destination)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            selectedSettingsDetail
        }
        .frame(minWidth: 900, minHeight: 640)
        .onChange(of: selectedDestination) { _, destination in
            if destination != .shortcuts {
                editingHotKeyTarget = nil
            }
        }
        .task { await reloadHotKeyConfiguration() }
        // Settings may open before the app-level StoreKit task completes.
        // Refresh here so existing owners always see the Family upgrade.
        .task { await storeManager.prepareForPurchases() }
    }

    #if DEBUG
    private var localizationScreenshotSettings: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("SETTINGS")
                    .font(Geist.label())
                    .foregroundStyle(Geist.text)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GeistDivider()
                VStack(spacing: Geist.Spacing.one) {
                    ForEach(MacSettingsDestination.allCases) { destination in
                        Button {
                            selectedDestination = destination
                        } label: {
                            HStack(spacing: Geist.Spacing.three) {
                                Image(systemName: destination.symbol)
                                    .frame(width: 24)
                                Text(destination.title)
                                Spacer()
                            }
                            .font(Geist.label())
                            .foregroundStyle(Geist.text)
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .background(
                                selectedDestination == destination
                                    ? Geist.Palette.gray200
                                    : Color.clear
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                Spacer()
            }
            .frame(width: 220)
            .background(Geist.surface)
            GeistDivider().frame(width: 1)
            selectedSettingsDetail
        }
        .frame(minWidth: 900, minHeight: 640)
        .task { await reloadHotKeyConfiguration() }
        .task { await storeManager.prepareForPurchases() }
    }
    #endif

    @ViewBuilder
    private var selectedSettingsDetail: some View {
        switch selectedDestination {
        case .access:
            accessSettings
        case .general:
            generalSettings
        case .shortcuts:
            shortcutsSettings
        case .diagnostics:
            MacDebugLogView()
                .navigationTitle("Diagnostics")
        case .about:
            aboutSettings
        }
    }

    private var accessSettings: some View {
        ScrollView {
            MacPaywallView(context: .settings, embeddedInSettings: true)
                .frame(maxWidth: 760)
                .padding(.vertical, Geist.Spacing.four)
                .frame(maxWidth: .infinity)
        }
        .background(Geist.Palette.background100)
        .navigationTitle("Access")
    }

    private var generalSettings: some View {
        ScrollView {
            VStack(spacing: 0) {
                settingsPageHeader(
                    title: "General",
                    detail: "Choose how Vox.md appears and review the Mac companion capabilities available on this device."
                )
                sectionHeader("01", "Mac Companion")
                settingsRow(
                    title: String(localized: "ON-DEVICE TRANSCRIPTION"),
                    detail: String(localized: "Whisper and Parakeet models run locally with Metal/Core ML acceleration."),
                    trailing: String(localized: "LOCAL")
                )
                settingsRow(
                    title: String(localized: "APPLE INTELLIGENCE"),
                    detail: appleIntelligenceDetail,
                    trailing: appleIntelligenceStatus
                )
                settingsRow(
                    title: String(localized: "FILE EXPORT"),
                    detail: String(localized: "Presets, templates, Markdown exports, and attachments use local app storage. Folder permissions stay on this Mac."),
                    trailing: String(localized: "ENABLED")
                )
                settingsRow(
                    title: String(localized: "KEYBOARD + LOCK SCREEN"),
                    detail: String(localized: "Custom keyboard, widgets, Dynamic Island, and Live Activities remain iOS-specific."),
                    trailing: String(localized: "IOS")
                )
                sectionHeader("02", "Visibility")
                visibilitySettings
            }
        }
        .background(Geist.surface)
        .navigationTitle("General")
    }

    @ViewBuilder
    private var shortcutsSettings: some View {
        if let target = editingHotKeyTarget {
            MacHotKeyRecorderView(
                title: hotKeyTitle(for: target),
                detail: hotKeyDetail(for: target),
                currentShortcut: hotKeyBindings[target],
                conflictingBindingName: { shortcut in
                    conflictingBindingName(for: shortcut, excluding: target)
                },
                onCancel: { editingHotKeyTarget = nil },
                onSave: { shortcut in saveHotKey(shortcut, for: target) },
                onClear: { clearHotKey(for: target) }
            )
            .id(target.id)
            .navigationTitle("Shortcuts")
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    settingsPageHeader(
                        title: "Shortcuts",
                        detail: "Start and stop on-device transcription or a Capture Preset from anywhere while Vox.md is running."
                    )
                    hotKeySettings
                }
            }
            .background(Geist.surface)
            .navigationTitle("Shortcuts")
        }
    }

    private var aboutSettings: some View {
        ScrollView {
            VStack(spacing: 0) {
                settingsPageHeader(
                    title: "Vox.md",
                    detail: "Private capture and on-device transcription for Markdown workflows."
                )
                sectionHeader("01", "About")
                settingsRow(title: String(localized: "VERSION"), detail: appVersionString, trailing: "")
                settingsRow(
                    title: String(localized: "PROCESSING"),
                    detail: String(localized: "Voice and text stay on-device."),
                    trailing: String(localized: "PRIVATE")
                )
                settingsRow(
                    title: String(localized: "STORAGE"),
                    detail: String(localized: "Capture drafts, history, presets, templates, and diagnostics remain in local app storage."),
                    trailing: String(localized: "LOCAL")
                )
            }
        }
        .background(Geist.surface)
        .navigationTitle("About")
    }

    private func settingsPageHeader(
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.two) {
            Text(title)
                .font(Geist.heading(.title))
                .foregroundStyle(Geist.text)
            Text(detail)
                .font(Geist.body())
                .foregroundStyle(Geist.muted)
        }
        .padding(Geist.Spacing.four)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Geist.bg)
    }

    private var visibilityMode: MacAppVisibilityMode {
        MacAppVisibilityMode(rawValue: visibilityModeRaw) ?? .dockAndMenuBar
    }

    private var visibilityFootnote: String {
        switch visibilityMode {
        case .dockAndMenuBar:
            return String(localized: "Default. Click “Show Vox.md” from the menu bar or use Cmd-Tab.")
        case .menuBarOnly:
            return String(localized: "No Dock icon or Cmd-Tab entry. Click the menu bar item to reveal Vox.md.")
        case .dockOnly:
            return String(localized: "Use the Dock icon or Cmd-Tab to bring Vox.md forward.")
        case .hidden:
            return String(localized: "Fully hidden. Reopen Vox.md from Spotlight, Finder, or Launchpad to access it again.")
        }
    }

    private var appleIntelligenceStatus: String {
        if #available(macOS 26, *) {
            return FoundationModelsBackend.isAvailable
                ? String(localized: "READY")
                : String(localized: "UNAVAILABLE")
        }
        return String(localized: "MACOS 26+")
    }

    private var appleIntelligenceDetail: String {
        if #available(macOS 26, *) {
            return String(localized: "Foundation Models cleans transcripts, adds titles/tags/categories, and powers smart folder routing on-device.")
        }
        return String(localized: "Requires macOS 26+ on an Apple Intelligence-capable Mac.")
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
                    title: String(localized: "Transcribe to Clipboard"),
                    detail: String(localized: "Copy immediately when processed now. Deferred results wait in Recording Queue so they never overwrite your clipboard later.")
                )

                hotKeyRow(
                    target: .selectedPreset,
                    title: String(localized: "Selected Capture Preset"),
                    detail: String(localized: "Use whichever preset is currently selected in Capture.")
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

            Text(shortcut?.displayString ?? String(localized: "OFF"))
                .font(Geist.mono(.caption, medium: true))
                .foregroundColor(shortcut == nil ? Geist.faint : Geist.text)
                .frame(minWidth: 72, alignment: .trailing)

            Button(shortcut == nil ? String(localized: "Set") : String(localized: "Change")) {
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
            return String(localized: "Transcribe to Clipboard")
        case .selectedPreset:
            return String(localized: "Selected Capture Preset")
        case .preset(let presetID):
            return hotKeyFlows.first(where: { $0.id == presetID })?.displayName
                ?? String(localized: "Capture Preset")
        }
    }

    private func hotKeyDetail(for target: MacHotKeyTarget) -> String {
        switch target {
        case .transcriptionOnly:
            return String(localized: "Start or stop a temporary transcription. Immediate results are copied; deferred results wait for an explicit Copy action in Recording Queue.")
        case .selectedPreset:
            return String(localized: "Start or stop recording with whichever Capture Preset is currently selected.")
        case .preset(let presetID):
            guard let flow = hotKeyFlows.first(where: { $0.id == presetID }) else {
                return String(localized: "Start or stop recording with this Capture Preset.")
            }
            return hotKeyRouteSummary(for: flow)
        }
    }

    private func hotKeyRouteSummary(for flow: CapturePreset) -> String {
        guard let destinationID = flow.captureDestinationID,
              let destination = hotKeyDestinations.first(where: { $0.id == destinationID }) else {
            return String(localized: "Destination not configured.")
        }

        switch destination.noteTarget {
        case .newNote(let pathTemplate):
            return String(localized: "Create a new note at \(pathTemplate) in \(destination.rootName).")
        case .rollingNote(let pathTemplate, let period):
            return String(localized: "Write to the \(period.rawValue) rolling note at \(pathTemplate).")
        case .existingNote(let relativePath):
            let verb: String
            switch destination.placement {
            case .append: verb = String(localized: "Append to")
            case .prepend: verb = String(localized: "Prepend to")
            case .beneathHeading: verb = String(localized: "Insert into")
            }
            return String(localized: "\(verb) \(relativePath) in \(destination.rootName).")
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

private struct MacHotKeyRecorderView: View {
    let title: String
    let detail: String
    let currentShortcut: MacHotKeyShortcut?
    let conflictingBindingName: (MacHotKeyShortcut) -> String?
    let onCancel: () -> Void
    let onSave: (MacHotKeyShortcut) -> Void
    let onClear: () -> Void

    @State private var capturedShortcut: MacHotKeyShortcut?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack {
                    Button("Back", systemImage: "chevron.left", action: onCancel)
                    Spacer()
                }
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
                    Text(capturedShortcut?.displayString ?? String(localized: "PRESS A KEYBIND"))
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
                    Button("Cancel", action: onCancel)
                        .buttonStyle(GeistButtonStyle(variant: .secondary))

                    Button("Clear", action: onClear)
                        .buttonStyle(.plain)
                        .foregroundColor(Geist.error)
                        .disabled(currentShortcut == nil && capturedShortcut == nil)

                    Spacer()

                    Button("Save Keybind") {
                        guard let capturedShortcut else { return }
                        if let conflict = conflictingBindingName(capturedShortcut) {
                            errorMessage = String(localized: "\(capturedShortcut.displayString) is already assigned to \(conflict).")
                            return
                        }
                        onSave(capturedShortcut)
                    }
                    .buttonStyle(GeistButtonStyle(variant: .primary))
                    .disabled(capturedShortcut == nil)
                }
            }
            .padding(30)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
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
            onCancel()
            return
        }

        guard let shortcut = MacHotKeyShortcut(event: event) else {
            errorMessage = String(localized: "Press one non-modifier key with Control, Option, or Command.")
            return
        }
        if let conflict = conflictingBindingName(shortcut) {
            capturedShortcut = nil
            errorMessage = String(localized: "\(shortcut.displayString) is already assigned to \(conflict).")
            return
        }

        capturedShortcut = shortcut
        errorMessage = nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(MacHotKeyShortcut.allowedModifierFlags)
        guard !modifiers.isEmpty else { return }

        if modifiers.intersection([.command, .option, .control]).isEmpty {
            errorMessage = String(localized: "Shift alone cannot be used. Add Control, Option, or Command plus one non-modifier key.")
        } else {
            errorMessage = String(localized: "Now press a letter, number, Space, arrow, or function key to finish the shortcut.")
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

private enum MacPaywallPresentation {
    case modal
    case embeddedSettings
}

struct MacPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(MacStoreManager.self) private var storeManager

    let context: OnboardingAnalyticsPaywallContext
    fileprivate let presentation: MacPaywallPresentation

    init(context: OnboardingAnalyticsPaywallContext = .settings) {
        self.context = context
        self.presentation = .modal
    }

    fileprivate init(
        context: OnboardingAnalyticsPaywallContext,
        embeddedInSettings: Bool
    ) {
        self.context = context
        self.presentation = embeddedInSettings ? .embeddedSettings : .modal
    }

    @ViewBuilder
    var body: some View {
        if presentation == .modal {
            paywallContent
                .frame(width: 620)
                .background(Geist.Palette.background100)
                .task { await storeManager.prepareForPurchases() }
        } else {
            paywallContent
                .frame(maxWidth: 760)
                .background(Geist.Palette.background100)
                .task { await storeManager.prepareForPurchases() }
        }
    }

    private var paywallContent: some View {
        VStack(spacing: 22) {
            Text(paywallTitle)
                .font(Geist.heading(.title))
                .foregroundColor(Geist.text)
            Text(paywallDetail)
                .font(Geist.body())
                .foregroundColor(Geist.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            if !usageTracker.hasUnlocked {
                Text(String(
                    format: String(localized: "%.1f / 15 min transcription · %d / 10 captures used"),
                    locale: Locale.current,
                    usageTracker.minutesUsed,
                    usageTracker.successfulCapturesUsed
                ))
                .font(Geist.mono(.footnote, medium: true))
                .foregroundColor(Geist.muted)
            }

            purchaseOptions

            Button(storeManager.isRestoring
                   ? String(localized: "RESTORING…")
                   : String(localized: "RESTORE PURCHASES")) {
                Task { await storeManager.restore() }
            }
            .buttonStyle(GeistButtonStyle(variant: .secondary))
            .frame(maxWidth: 440)
            .disabled(storeManager.isRestoring || storeManager.isPurchasing)

            if let error = storeManager.errorMessage {
                Text(error)
                    .font(Geist.caption())
                    .foregroundColor(Geist.error)
            }
            if presentation == .modal {
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(Geist.muted)
            }
        }
        .padding(36)
    }

    @ViewBuilder
    private var purchaseOptions: some View {
        if !storeManager.isEntitlementStateReady {
            HStack(spacing: 10) {
                ProgressView()
                Text("CHECKING PURCHASES…")
                    .font(Geist.caption())
                    .foregroundColor(Geist.muted)
            }
            .frame(maxWidth: 440)
        } else {
            availablePurchaseOptions
        }
    }

    @ViewBuilder
    private var availablePurchaseOptions: some View {
        switch usageTracker.accessLevel {
        case .free:
            HStack(alignment: .top, spacing: 16) {
                macOffer(
                    product: .individual,
                    title: "INDIVIDUAL UNLIMITED",
                    detail: "Lifetime access on devices using your Apple Account."
                )
                macOffer(
                    product: .family,
                    title: "FAMILY UNLIMITED",
                    detail: "Lifetime access for your Apple Family Sharing group."
                )
            }
        case .individual:
            macOffer(
                product: .familyUpgrade,
                title: "UPGRADE TO FAMILY",
                detail: "Add Apple Family Sharing to your existing Unlimited purchase."
            )
            .frame(maxWidth: 440)
        case .family:
            Label("Family Unlimited Unlocked", systemImage: "person.3.fill")
                .font(Geist.label())
                .foregroundColor(Geist.text)
                .padding(18)
                .frame(maxWidth: 440)
                .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))
        }
    }

    private func macOffer(
        product: VoxboardPurchaseProduct,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Geist.label())
                .foregroundColor(Geist.text)
            Text(storeManager.displayPrice(for: product) ?? String(localized: "PRICE UNAVAILABLE"))
                .font(Geist.heading(.title2))
                .foregroundColor(Geist.text)
            Text(detail)
                .font(Geist.caption())
                .foregroundColor(Geist.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(purchaseButtonTitle(for: product)) {
                Task { await storeManager.purchase(product, context: context) }
            }
            .buttonStyle(GeistButtonStyle(variant: .primary))
            .disabled(storeManager.isPurchasing || storeManager.product(for: product) == nil)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
        .overlay(Rectangle().stroke(Geist.border, lineWidth: 1))
    }

    private func purchaseButtonTitle(for product: VoxboardPurchaseProduct) -> String {
        if storeManager.purchasingProductID == product.rawValue {
            return String(localized: "PURCHASING…")
        }
        return switch product {
        case .individual: String(localized: "UNLOCK INDIVIDUAL")
        case .family: String(localized: "UNLOCK FAMILY")
        case .familyUpgrade: String(localized: "UPGRADE TO FAMILY")
        }
    }

    private var paywallTitle: String {
        switch usageTracker.accessLevel {
        case .free: String(localized: "Choose Vox.md Unlimited")
        case .individual: String(localized: "Share Unlimited with Family")
        case .family: String(localized: "Vox.md Family Unlimited")
        }
    }

    private var paywallDetail: String {
        switch usageTracker.accessLevel {
        case .free:
            String(localized: "Unlock unlimited local Capture and private, on-device transcription. Pay once with no subscription.")
        case .individual:
            String(localized: "You already own lifetime Unlimited. Upgrade once to support Apple Family Sharing.")
        case .family:
            String(localized: "Your lifetime Unlimited access supports Apple Family Sharing.")
        }
    }
}

private struct MacDebugLogView: View {
    @State private var logText = KeyboardDebugLog.shared.read()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Diagnostics")
                        .font(Geist.heading(.title2))
                    Text("Review local hotkey, recording, export, and purchase restore diagnostics.")
                        .font(Geist.caption())
                        .foregroundStyle(Geist.muted)
                }
                Spacer()
                Button("Clear") {
                    KeyboardDebugLog.shared.clear()
                    logText = "(cleared)"
                }
                .foregroundColor(Geist.error)
                Button("Refresh", systemImage: "arrow.clockwise") {
                    refresh()
                }
                Button("Copy", systemImage: "doc.on.doc") {
                    copyToPasteboard(logText)
                }
                if AppConstants.sharedContainerURL != nil {
                    Button("Reveal Data Folder", systemImage: "folder") {
                        revealDataFolder()
                    }
                }
            }
            .padding(Geist.Spacing.four)
            GeistDivider()
            ScrollView {
                Text(logText.isEmpty ? String(localized: "(empty)") : logText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Geist.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Geist.Spacing.four)
            }
        }
        .background(Geist.Palette.background100)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        logText = KeyboardDebugLog.shared.read()
    }

    private func revealDataFolder() {
        guard let url = AppConstants.sharedContainerURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private extension CapturePresetProcessingMode {
    var helpText: String {
        switch self {
        case .none:
            return String(localized: "Keeps typed Markdown, OCR, and voice text exactly as captured.")
        case .clean:
            return String(localized: "Improves casing and punctuation on device while preserving meaning and Markdown structure.")
        case .todoList:
            return String(localized: "Turns captured tasks into `- [ ]` Markdown checklist items without inventing new tasks.")
        case .meetingNotes:
            return String(localized: "Builds grounded Markdown meeting notes from typed text, OCR, or voice.")
        case .custom:
            return String(localized: "Follows your instruction on device for any Capture text when enabled.")
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
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.allowedUnits = d < 60 ? [.second] : [.minute, .second]
    formatter.maximumUnitCount = 2
    return formatter.string(from: max(0, d)) ?? String(localized: "0 sec")
}

private func relativeDate(_ date: Date) -> String {
    let now = Date()
    if now.timeIntervalSince(date) < 86_400 {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .none
    return f.string(from: date)
}
