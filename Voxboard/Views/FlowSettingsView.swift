import AppIntents
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import VoxboardShared

/// Manage reusable Capture Presets across text, links, media, scans, files,
/// and voice recordings. A preset owns its processing, metadata, and complete
/// Markdown destination.
struct CapturePresetSettingsView: View {
    @State private var flows: [CapturePreset] = CapturePresetStore.loadFlows()
    @State private var watchStatePublishTask: Task<Void, Never>?

    var body: some View {
        List {
            introSection

            Section {
                ForEach($flows) { $flow in
                    NavigationLink {
                        CapturePresetEditorView(preset: $flow)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: flow.symbolName)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(flow.displayName)
                                Text(
                                    flow.watchOutputMode == .recordingOnly
                                        ? String(localized: "Recording Only (Watch)")
                                        : flow.postProcessingMode.displayName
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if flow.id == CapturePresetProfileStore.selectedProfileID(defaults: AppConstants.sharedDefaults) {
                                Text("Default")
                                    .font(.caption2.monospaced().weight(.semibold))
                                    .foregroundStyle(.secondary)
                            } else if flow.id == CapturePresetStore.selectedFlowId() {
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
                Text("Capture Presets")
            } footer: {
                Text("Each preset owns how captures are processed, formatted, and delivered. Voice-specific audio and legacy export options live in the same preset.")
            }

            Section {
                Button {
                    flows.append(CapturePresetStore.makeCustomFlow())
                } label: {
                    Label("Add Preset", systemImage: "plus")
                }
            }

            Section("Shared Formatting") {
                NavigationLink {
                    CaptureEntryTemplateLibraryView()
                } label: {
                    Label("Entry Templates", systemImage: "doc.text")
                }
            }
        }
        .navigationTitle("Capture Presets")
        .font(Geist.body())
        .tint(Color.accentColor)
        .scrollContentBackground(.hidden)
        .background(Geist.Palette.background200)
        .task { await migrateRoutesAndReload() }
        .onChange(of: flows) { _, newValue in
            CapturePresetStore.saveFlows(newValue)
            if #available(iOS 18.0, *) {
                VoxboardShortcutsProvider.updateAppShortcutParameters()
            }
            scheduleWatchStatePublish()
        }
        .onDisappear {
            watchStatePublishTask?.cancel()
            WatchRecordingController.shared.publishState()
        }
    }

    private func scheduleWatchStatePublish() {
        watchStatePublishTask?.cancel()
        watchStatePublishTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            WatchRecordingController.shared.publishState()
        }
    }

    private func migrateRoutesAndReload() async {
        guard let url = AppConstants.captureLibraryURL else { return }
        let store = CaptureLibraryStore(fileURL: url)
        _ = try? await CapturePresetRouteLibrary.load(from: store)
        flows = CapturePresetStore.loadFlows()
    }

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("What is a Capture Preset?", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Text("A Capture Preset is a complete reusable workflow: what happens to a capture and exactly where it is delivered.")
                Text("Create presets for meetings, journal entries, tasks, ideas, or any setup you use often.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        }
    }

    private func delete(_ flow: CapturePreset) {
        CapturePresetStore.retirePreset(
            id: flow.id,
            ownedRouteID: flow.captureDestinationID
        )
        flows.removeAll { $0.id == flow.id }
        let fallbackID = flows.first?.id ?? CapturePresetStore.generalId
        if CapturePresetStore.selectedFlowId() == flow.id {
            CapturePresetStore.selectFlow(id: fallbackID)
        }
        if CapturePresetProfileStore.selectedProfileID(defaults: AppConstants.sharedDefaults) == flow.id {
            CapturePresetProfileStore.selectCaptureProfile(
                id: fallbackID,
                defaults: AppConstants.sharedDefaults
            )
        }
    }
}

private struct CapturePresetEditorView: View {
    @Environment(\.openURL) private var openURL
    @Binding var flow: CapturePreset
    @State private var frontmatterText: String
    @State private var showBookmarkPicker = false
    @State private var bookmarkPickerKind: BookmarkKind = .exportFolder
    @State private var captureDestinations: [CaptureDestination] = []
    @State private var captureEntryTemplates: [CaptureEntryTemplate] = []
    @State private var captureDestinationLoadError: String?
    @State private var isEditingDestination = false
    @State private var isCaptureProcessingInfoPresented = false
    @State private var recordingDeliveryNotificationsDenied = false

    private enum BookmarkKind {
        case exportFolder
        case audioFolder
        case markdownTemplate
        case watchRecordingFolder

        var allowedContentTypes: [UTType] {
            switch self {
            case .exportFolder, .audioFolder, .watchRecordingFolder:
                return [.folder]
            case .markdownTemplate:
                return [.init(filenameExtension: "md") ?? .plainText, .plainText]
            }
        }
    }

    init(preset: Binding<CapturePreset>) {
        self._flow = preset
        self._frontmatterText = State(initialValue: Self.renderFrontmatter(preset.wrappedValue.staticFrontmatter))
    }

    var body: some View {
        Form {
            identitySection
            watchOutputSection
            if flow.watchOutputMode != .recordingOnly {
                voiceProcessingSection
                postProcessingSection
                ownedDestinationSection
                if flow.captureDestinationID == nil {
                    fileExportSection
                }
                if showsFrontmatterSection {
                    frontmatterSection
                    locationMetadataSection
                }
                audioExportSection
            }
        }
        .navigationTitle(flow.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadCaptureDestinations()
            await refreshRecordingDeliveryNotificationStatus()
        }
        .onAppear {
            // File export now lives on each flow. Mark old flow records as
            // per-flow when the user opens them so later edits do not fall back
            // to the legacy app-wide Files tab settings.
            flow.exportSettings.usesCustomExportSettings = true
        }
        .sheet(isPresented: $isEditingDestination) {
            NavigationStack {
                CaptureDestinationEditorView(
                    existing: ownedDestination,
                    templates: captureEntryTemplates,
                    fixedName: flow.displayName
                ) { destination in
                    try await saveOwnedDestination(destination)
                }
            }
        }
        .sheet(isPresented: $isCaptureProcessingInfoPresented) {
            CaptureTextProcessingInfoView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
                .tint(Color.accentColor)
        }
    }

    private var watchOutputSection: some View {
        Section {
            Picker("Output", selection: $flow.watchOutputMode) {
                ForEach(CapturePresetWatchOutputMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .onChange(of: flow.watchOutputMode) { _, mode in
                guard mode == .recordingOnly else { return }
                requestRecordingDeliveryNotificationsIfNeeded()
            }

            if flow.watchOutputMode == .recordingOnly {
                Button {
                    openBookmarkPicker(.watchRecordingFolder)
                } label: {
                    folderRow(
                        title: "Recording Folder",
                        value: flow.watchRecordingSettings.folderName
                    )
                }
                .buttonStyle(.plain)

                if !flow.watchRecordingSettings.folderName.isEmpty {
                    Button("Clear Recording Folder", role: .destructive) {
                        flow.watchRecordingSettings.folderBookmark = nil
                        flow.watchRecordingSettings.folderName = ""
                    }
                }

                TextField(
                    "Filename Template",
                    text: $flow.watchRecordingSettings.filenameTemplate
                )
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

                Text("Tokens: {timestamp}, {date}, {time}, {YR} (2-digit year), {id8}, {id}, {preset}, {original}")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if flow.watchRecordingSettings.folderBookmark == nil {
                    Label("Choose a Files folder before using this preset from Apple Watch.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Geist.error)
                }

                if recordingDeliveryNotificationsDenied {
                    Label("Notifications are off. Vox.md cannot alert you if an unattended Files delivery needs attention.", systemImage: "bell.slash")
                        .font(.caption)
                        .foregroundStyle(Geist.error)
                    Button("Open Notification Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    }
                }
            }
        } header: {
            Text("Apple Watch Output")
        } footer: {
            if flow.watchOutputMode == .recordingOnly {
                Text("Watch recordings are copied as M4A files to this user-visible Files folder. Transcription, AI processing, and transcription usage are skipped. After one-time folder setup, Vox.md normally saves in the background. iOS may delay delivery, and force-quitting Vox.md prevents background delivery until you reopen it. Recordings remain safely queued for retry.")
            } else {
                Text("Watch recordings use this preset's normal on-device transcription and Capture destination workflow.")
            }
        }
    }

    private var voiceProcessingSection: some View {
        Section {
            Toggle("Identify Speakers", isOn: $flow.speakerDiarizationEnabled)
                .tint(Color.accentColor)

            if flow.speakerDiarizationEnabled {
                Label("Speaker labels are added after transcription.", systemImage: "person.2.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Voice Processing")
        } footer: {
            Text("Detects and labels multiple voices entirely on device. The speaker model downloads the first time this preset uses it. Speaker identification is best-effort; if it cannot run, Vox.md keeps the normal transcript.")
        }
    }

    private var postProcessingSection: some View {
        Section {
            HStack(spacing: 12) {
                Toggle("Apply to Capture Text", isOn: $flow.captureProcessingEnabled)
                    .tint(Color.accentColor)

                Button {
                    isCaptureProcessingInfoPresented = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About Apply to Capture Text")
            }

            Picker("Mode", selection: $flow.postProcessingMode) {
                ForEach(CapturePresetProcessingMode.allCases) { mode in
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

    private var ownedDestinationSection: some View {
        Section {
            if let destination = ownedDestination {
                LabeledContent("Vault / Folder", value: destination.rootName)
                Text(captureDestinationSummary(destination))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Button {
                    isEditingDestination = true
                } label: {
                    Label("Edit Destination", systemImage: "square.and.pencil")
                }
            } else {
                ContentUnavailableView(
                    "Destination Not Configured",
                    systemImage: "folder.badge.plus",
                    description: Text("Choose a vault or folder and define where this preset writes Markdown.")
                )
                Button {
                    isEditingDestination = true
                } label: {
                    Label("Set Up Destination", systemImage: "folder.badge.plus")
                }
            }

            if let captureDestinationLoadError {
                Text(captureDestinationLoadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Destination")
        } footer: {
            Text("This destination belongs to this preset. It includes the note target, placement, entry formatting, attachments folder, and retry behavior.")
        }
    }

    private var frontmatterSection: some View {
        Section("Metadata") {
            Picker("Scope", selection: $flow.metadataScope) {
                ForEach(CapturePresetMetadataScope.allCases) { scope in
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

    private var locationMetadataSection: some View {
        Section {
            Toggle("Use Current Location", isOn: $flow.locationPolicy.isEnabled)
                .tint(Color.accentColor)
                .accessibilityIdentifier("preset_location_enabled")

            if flow.locationPolicy.isEnabled {
                Text("Entry formatting can use {location} without writing additional metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Precision", selection: $flow.locationPolicy.precision) {
                    Text("Exact").tag(CaptureLocationPrecision.exact)
                    Text("City").tag(CaptureLocationPrecision.city)
                }
                .accessibilityIdentifier("preset_location_precision")

                Picker("When Location Is Unavailable", selection: $flow.locationPolicy.unavailableBehavior) {
                    Text("Ask").tag(CaptureLocationUnavailableBehavior.ask)
                    Text("Send Without Location").tag(CaptureLocationUnavailableBehavior.sendWithoutLocation)
                    Text("Cancel Capture").tag(CaptureLocationUnavailableBehavior.cancel)
                }
                .accessibilityIdentifier("preset_location_unavailable_behavior")

                Toggle("Write Location Metadata", isOn: $flow.locationPolicy.metadataOutputEnabled)
                    .tint(Color.accentColor)
                    .accessibilityIdentifier("preset_location_metadata_output_enabled")

                if flow.locationPolicy.metadataOutputEnabled {
                    Picker("Configuration", selection: $flow.locationPolicy.outputMode) {
                        Text("Structured Fields").tag(CaptureLocationOutputMode.structured)
                        Text("Advanced YAML Template")
                            .tag(CaptureLocationOutputMode.advancedTemplate)
                            .disabled(flow.metadataScope == .entry)
                    }
                    .accessibilityIdentifier("preset_location_output_mode")

                    if flow.locationPolicy.outputMode == .advancedTemplate,
                       flow.metadataScope == .entry {
                        Label(
                            String(localized: "Advanced YAML Template") + " · " + String(localized: "Use Note Frontmatter Scope"),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(Geist.error)
                        .accessibilityIdentifier("preset_location_scope_error")
                        Button("Use Note Frontmatter Scope") {
                            flow.metadataScope = .document
                        }
                    }

                    if flow.metadataScope == .document {
                        TextField("Name", text: $flow.locationPolicy.collectionKey)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityIdentifier("preset_location_collection_key")
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
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(field.configurationDisplayName, isOn: locationFieldSelection(field))
                                    .tint(Color.accentColor)
                                if flow.locationPolicy.structuredFields.contains(where: { $0.field == field }) {
                                    TextField("Output", text: locationOutputKey(field))
                                        .textInputAutocapitalization(.never)
                                        .disableAutocorrection(true)
                                        .font(.system(.body, design: .monospaced))
                                        .accessibilityLabel(
                                            String(localized: "Output") + " · " + field.configurationDisplayName
                                        )
                                        .accessibilityIdentifier("preset_location_key_\(field.rawValue)")
                                }
                            }
                        }
                    } else {
                        TextEditor(text: $flow.locationPolicy.advancedTemplate)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 160)
                            .accessibilityLabel("Advanced YAML Template")
                            .accessibilityIdentifier("preset_location_advanced_template")
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
            .accessibilityIdentifier("preset_location_reset_unavailable")

            Button("Reset Location Configuration", role: .destructive) {
                flow.locationPolicy = CapturePresetLocationPolicy()
            }
            .accessibilityIdentifier("preset_location_reset_configuration")
        } header: {
            Text("Location")
        } footer: {
            Text("Location is requested once at Capture send or recording stop. Exact keeps the origin fix; City rounds coordinates and omits a point-of-interest label. Vox.md does not track location in the background.")
        }
    }

    private func locationFieldSelection(_ field: CaptureLocationField) -> Binding<Bool> {
        Binding(
            get: { flow.locationPolicy.structuredFields.contains(where: { $0.field == field }) },
            set: { isSelected in
                flow.locationPolicy.structuredFields.removeAll { $0.field == field }
                if isSelected {
                    flow.locationPolicy.structuredFields.append(CaptureLocationStructuredField(field: field))
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
                guard let index = flow.locationPolicy.structuredFields.firstIndex(where: { $0.field == field }) else {
                    return
                }
                flow.locationPolicy.structuredFields[index].outputKey = value
            }
        )
    }

    @ViewBuilder
    private var locationPolicyPreview: some View {
        switch CaptureLocationConfigurationPreview.result(
            profile: flow.captureProfile,
            source: .app
        ) {
        case .success(let preview):
            VStack(alignment: .leading, spacing: 8) {
                Label("Delivery Preview", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                ScrollView(.horizontal) {
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("preset_location_preview")
        case .failure(let error):
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Geist.error)
                .accessibilityIdentifier("preset_location_validation_error")
        }
    }

    private var fileExportSection: some View {
        Section {
            Toggle("Save Notes to Files", isOn: $flow.exportSettings.exportEnabled)
                .tint(Color.accentColor)
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
                        .tint(Color.accentColor)
                        .onChange(of: flow.exportSettings.mdObsidianEnabled) { _, _ in markPerFlow() }
                }

                if flow.exportSettings.format == .yaml {
                    Toggle("Use .md Extension", isOn: $flow.exportSettings.yamlUsesMarkdownExtension)
                        .tint(Color.accentColor)
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
                    Text("Tokens: {timestamp}, {date}, {time}, {YR} (2-digit year), {id8}, {id}, {model}, {language}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Append Filename", text: $flow.exportSettings.appendFileName)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onChange(of: flow.exportSettings.appendFileName) { _, _ in markPerFlow() }
                }

                Toggle("Use Markdown Template", isOn: $flow.exportSettings.markdownTemplateEnabled)
                    .tint(Color.accentColor)
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
                ForEach(CapturePresetAudioSaveMode.allCases) { mode in
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
                    .tint(Color.accentColor)
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
        } header: {
            Text("Voice Audio")
        } footer: {
            Text(audioExportFooterText)
        }
    }

    private var audioExportFooterText: String {
        switch flow.audioSaveMode {
        case .off:
            return String(localized: "Turn this on to save a copy of the recorded audio when a note is exported.")
        case .alongsideTranscript:
            return flow.captureDestinationID == nil
                ? String(localized: "Saved audio uses the same legacy export directory and base filename as the note.")
                : String(localized: "Saved audio is placed alongside the unified Markdown note.")
        case .attachmentsFolder:
            return flow.captureDestinationID == nil
                ? String(localized: "When no audio export directory is set, saved audio uses this preset’s legacy note export folder.")
                : String(localized: "Saved audio uses a subfolder inside the unified Markdown destination, and that route survives deferred retries.")
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
            return String(localized: "Adds an Obsidian-style audio link to the unified Markdown note at the selected position.")
        }
        guard markdownAudioEmbedAvailable else {
            return String(localized: "Audio embeds require a Markdown note export. Switch this preset to MD, a Markdown template, or YAML with the .md extension.")
        }
        return String(localized: "Adds an Obsidian-style `![[recording.m4a]]` link to the note so you can replay the recording while reviewing the transcript.")
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
            .tint(Color.accentColor)
            .disabled(flow.exportSettings.yamlProperties.count == 1 && flow.exportSettings.yamlProperties.contains(property))
        }
    }

    private var ownedDestination: CaptureDestination? {
        guard let id = flow.captureDestinationID else { return nil }
        return captureDestinations.first(where: { $0.id == id })
    }

    private func saveOwnedDestination(_ submittedDestination: CaptureDestination) async throws {
        guard let url = AppConstants.captureLibraryURL else {
            throw CapturePresetDestinationError.storageUnavailable
        }
        let destination = CapturePresetStore.migratingLegacyMarkdownTemplate(
            into: submittedDestination,
            from: flow.exportSettings
        )
        let store = CaptureLibraryStore(fileURL: url)
        let library = try await store.update { library in
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
                // Route migration may have assigned ownership while this editor
                // was open. Merge only those migration-owned fields so a task
                // restart cannot overwrite in-progress identity or policy edits.
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
        switch kind {
        case .watchRecordingFolder:
            break
        default:
            markPerFlow()
        }
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
        switch kind {
        case .watchRecordingFolder:
            break
        default:
            markPerFlow()
        }
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
        case .watchRecordingFolder:
            flow.watchRecordingSettings.folderBookmark = bookmark
            flow.watchRecordingSettings.folderName = url.lastPathComponent
            requestRecordingDeliveryNotificationsIfNeeded()
        }
    }

    private func requestRecordingDeliveryNotificationsIfNeeded() {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
                recordingDeliveryNotificationsDenied = !granted
            case .denied:
                recordingDeliveryNotificationsDenied = true
            case .authorized, .provisional, .ephemeral:
                recordingDeliveryNotificationsDenied = false
            @unknown default:
                recordingDeliveryNotificationsDenied = true
            }
        }
    }

    private func refreshRecordingDeliveryNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        recordingDeliveryNotificationsDenied = settings.authorizationStatus == .denied
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

private struct CaptureTextProcessingInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(Geist.Palette.gray1000)
                        .accessibilityHidden(true)

                    Text("When this setting is on, Vox.md uses on-device Apple Intelligence to edit captured text using the selected mode before updating your Markdown file.")

                    VStack(alignment: .leading, spacing: 12) {
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("Apply to Capture Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .font(Geist.body())
        .tint(Color.accentColor)
    }

    private func infoRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum CapturePresetDestinationError: Error, LocalizedError {
    case storageUnavailable

    var errorDescription: String? {
        "Shared capture storage is unavailable."
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
        .tint(Color.accentColor)
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
        let title = allOptions.first(where: { $0.symbolName == iconName })?.title ?? iconName
        return title == "Waveform"
            ? String(localized: "Waveform", bundle: .main)
            : title
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

private extension CapturePresetProcessingMode {
    var helpTitle: String {
        switch self {
        case .none:
            return String(localized: "Preserves captured text")
        case .clean:
            return String(localized: "Cleans prose without changing intent")
        case .todoList:
            return String(localized: "Creates a Markdown checklist")
        case .meetingNotes:
            return String(localized: "Formats notes and action items")
        case .custom:
            return String(localized: "Uses your custom instruction")
        }
    }

    var helpText: String {
        switch self {
        case .none:
            return String(localized: "Keeps typed Markdown, OCR, and voice text exactly as captured. Static frontmatter and route settings still apply.")
        case .clean:
            return String(localized: "Fixes casing and punctuation while preserving meaning and Markdown structure. Without on-device enrichment, the original text is retained.")
        case .todoList:
            return String(localized: "Turns captured tasks into `- [ ]` Markdown items without inventing new work. A deterministic local fallback is always available.")
        case .meetingNotes:
            return String(localized: "Builds Markdown meeting notes with useful sections and grounded action items from typed text, OCR, or voice.")
        case .custom:
            return String(localized: "When on-device AI is available, Vox.md follows your instruction for captured text. Use it for standups, journal prompts, summaries, or call follow-ups.")
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
