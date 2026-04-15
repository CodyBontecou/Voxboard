import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

struct SettingsView: View {
    @Environment(ModelManager.self) private var modelManager
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(StoreManager.self) private var storeManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showDebugLog = false
    @State private var showPaywall = false
#if os(iOS)
    @State private var showMailCompose = false
#endif
    @State private var showFolderPicker = false
    @State private var fileExportEnabled: Bool = AppConstants.sharedDefaults?.bool(forKey: AppConstants.fileExportEnabledKey) ?? false
    @State private var fileExportFormat: ExportFileFormat = {
        let raw = AppConstants.sharedDefaults?.string(forKey: AppConstants.fileExportFormatKey) ?? "txt"
        return ExportFileFormat(rawValue: raw) ?? .txt
    }()
    @State private var fileExportMode: ExportFileMode = {
        let raw = AppConstants.sharedDefaults?.string(forKey: AppConstants.fileExportModeKey) ?? "newFile"
        return ExportFileMode(rawValue: raw) ?? .newFile
    }()
    @State private var newFileNameTemplate: String = {
        AppConstants.sharedDefaults?.string(forKey: AppConstants.fileExportNewFileNameTemplateKey)
            ?? TranscriptFileExporter.defaultNewFileNameTemplate
    }()
    @State private var appendFileName: String = {
        AppConstants.sharedDefaults?.string(forKey: AppConstants.fileExportAppendFileNameKey)
            ?? TranscriptFileExporter.defaultAppendFileName
    }()
    @State private var yamlProperties: Set<ExportYAMLProperty> = {
        guard let raw = AppConstants.sharedDefaults?.array(forKey: AppConstants.fileExportYAMLPropertiesKey) as? [String] else {
            return ExportYAMLProperty.defaultSelection
        }
        let parsed = Set(raw.compactMap(ExportYAMLProperty.init(rawValue:)))
        return parsed.isEmpty ? ExportYAMLProperty.defaultSelection : parsed
    }()
    @State private var yamlObsidianBasesEnabled: Bool =
        AppConstants.sharedDefaults?.bool(forKey: AppConstants.fileExportYAMLObsidianBasesKey) ?? false
    @State private var mdObsidianEnabled: Bool =
        AppConstants.sharedDefaults?.bool(forKey: AppConstants.fileExportMDObsidianKey) ?? false
    @State private var selectedFolderName: String = {
        guard let data = AppConstants.sharedDefaults?.data(forKey: AppConstants.fileExportBookmarkKey),
              var isStale = Optional(false),
              let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else {
            return ""
        }
        return url.lastPathComponent
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                Brutal.surface.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        upgradeSection
                        BrutalDivider()
                        modelsSection
                        BrutalDivider()
                        languageSection
                        BrutalDivider()
                        fileExportSection
                        BrutalDivider()
                        aboutSection
                        BrutalDivider()
                        feedbackSection
                        BrutalDivider()
                        debugSection
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("SETTINGS")
                        .font(Brutal.label(.headline))
                        .foregroundColor(Brutal.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") { dismiss() }
                        .font(Brutal.label())
                        .foregroundColor(Brutal.muted)
                        .buttonStyle(.plain)
                }
            }
            .toolbarBackground(Brutal.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $showDebugLog) {
                KeyboardDebugLogView()
            }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let bookmark = try? url.bookmarkData(
                        options: .minimalBookmark,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        AppConstants.sharedDefaults?.set(bookmark, forKey: AppConstants.fileExportBookmarkKey)
                        selectedFolderName = url.lastPathComponent
                    }
                case .failure:
                    break
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
                    .environment(usageTracker)
                    .environment(storeManager)
            }
#if os(iOS)
            .sheet(isPresented: $showMailCompose) {
                MailComposeView()
            }
#endif
        }
        .preferredColorScheme(.dark)
    }

    private func toggleYAMLProperty(_ property: ExportYAMLProperty, enabled: Bool) {
        if enabled {
            yamlProperties.insert(property)
        } else {
            guard yamlProperties.count > 1 else { return }
            yamlProperties.remove(property)
        }

        let raw = ExportYAMLProperty.allCases
            .filter { yamlProperties.contains($0) }
            .map(\.rawValue)
        AppConstants.sharedDefaults?.set(raw, forKey: AppConstants.fileExportYAMLPropertiesKey)
    }

    private func persistYAMLObsidianBasesEnabled(_ enabled: Bool) {
        AppConstants.sharedDefaults?.set(enabled, forKey: AppConstants.fileExportYAMLObsidianBasesKey)
    }

    private func persistNewFileNameTemplate(_ value: String) {
        AppConstants.sharedDefaults?.set(value, forKey: AppConstants.fileExportNewFileNameTemplateKey)
    }

    private func persistAppendFileName(_ value: String) {
        AppConstants.sharedDefaults?.set(value, forKey: AppConstants.fileExportAppendFileNameKey)
    }

    // MARK: - Section Header

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

    // MARK: - Upgrade Section

    private var upgradeSection: some View {
        VStack(spacing: 0) {
            sectionHeader("—", "Voxboard Unlimited")
            BrutalDivider()

            if usageTracker.hasUnlocked {
                // Already purchased
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UNLIMITED UNLOCKED")
                            .font(Brutal.label())
                            .foregroundColor(Brutal.text)
                        Text("Lifetime access — no limits")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.muted)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Brutal.text)
                            .frame(width: 6, height: 6)
                        Text("PURCHASED")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.text)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Brutal.bg)
            } else {
                // Not purchased — show upgrade prompt
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("UNLOCK UNLIMITED")
                                .font(Brutal.label())
                                .foregroundColor(Brutal.text)
                            Text(String(format: String(localized: "%.1f / 15 min free used"), usageTracker.minutesUsed))
                                .font(Brutal.caption())
                                .foregroundColor(Brutal.muted)
                        }
                        Spacer()
                        Text(storeManager.displayPrice)
                            .font(Brutal.label(.headline))
                            .foregroundColor(Brutal.text)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    Button(action: { showPaywall = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.open.fill")
                                .font(.system(.subheadline))
                            Text("VIEW UPGRADE OPTIONS")
                        }
                    }
                    .buttonStyle(BrutalButtonStyle(variant: .primary))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .background(Brutal.bg)
            }
        }
    }

    // MARK: - Models Section

    private var whisperModels: [WhisperModelInfo] {
        WhisperModelInfo.availableModels.filter { !$0.engine.isParakeet }
    }

    private var parakeetModels: [WhisperModelInfo] {
        WhisperModelInfo.availableModels.filter { $0.engine.isParakeet }
    }

    private var modelsSection: some View {
        VStack(spacing: 0) {
            sectionHeader("01", "Whisper Models")
            BrutalDivider()
            ForEach(whisperModels) { model in
                modelRow(for: model)
                BrutalDivider()
            }
            sectionHeader("02", "Parakeet Models")
            BrutalDivider()
            ForEach(parakeetModels) { model in
                modelRow(for: model)
                BrutalDivider()
            }

            // Footer note
            Text("Tiny is best for the keyboard extension. Larger models are more accurate but use more memory.")
                .font(Brutal.caption())
                .foregroundColor(Brutal.muted)
                .lineSpacing(3)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brutal.bg)
        }
    }

    private func modelRow(for model: WhisperModelInfo) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
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
                }
                Text(model.sizeLabel.uppercased())
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)

                if let modelDescription = model.modelDescription {
                    Text(modelDescription)
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                        .lineLimit(2)
                }
            }

            Spacer()

            modelActionView(for: model)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Brutal.bg)
    }

    @ViewBuilder
    private func modelActionView(for model: WhisperModelInfo) -> some View {
        if model.isDownloaded {
            HStack(spacing: 12) {
                if modelManager.selectedModelId == model.id {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Brutal.text)
                            .frame(width: 6, height: 6)
                        Text("SELECTED")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.text)
                    }
                } else {
                    Button("SELECT") {
                        modelManager.selectedModelId = model.id
                    }
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
                    .buttonStyle(.plain)
                }

                Button {
                    modelManager.deleteModel(model)
                } label: {
                    Text("DELETE")
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.error)
                }
                .buttonStyle(.plain)
            }
        } else if modelManager.isDownloading[model.id] == true {
            downloadingView(for: model)
        } else {
            Button {
                modelManager.startDownload(model)
            } label: {
                Text("↓ DOWNLOAD")
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func downloadingView(for model: WhisperModelInfo) -> some View {
        let pct = Int((modelManager.downloadProgress[model.id] ?? 0) * 100)
        return HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 4) {
                // Brutal progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Brutal.border).frame(height: 2)
                        Rectangle()
                            .fill(Brutal.text)
                            .frame(width: geo.size.width * CGFloat(modelManager.downloadProgress[model.id] ?? 0), height: 2)
                    }
                }
                .frame(width: 72, height: 2)

                Text("\(pct)%")
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
                    .monospacedDigit()
            }
            Button {
                modelManager.cancelDownload(model)
            } label: {
                Text("✕")
                    .font(Brutal.label())
                    .foregroundColor(Brutal.muted)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Language Section

    private var languageSection: some View {
        VStack(spacing: 0) {
            sectionHeader("03", "Language")
            BrutalDivider()

            if modelManager.selectedModel?.engine.isParakeet == true {
                Text("Parakeet currently auto-detects language in Voxboard. Manual language hints are not yet supported by the current engine API.")
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
                    .lineSpacing(3)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brutal.bg)
            } else {
                Picker("Transcription Language", selection: Binding(
                    get: { modelManager.selectedLanguage },
                    set: { modelManager.selectedLanguage = $0 }
                )) {
                    ForEach(modelManager.availableLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 140)
                .background(Brutal.bg)
                .tint(Brutal.text)
            }
        }
    }

    // MARK: - File Export Section

    private var fileExportSection: some View {
        VStack(spacing: 0) {
            sectionHeader("04", "File Export")
            BrutalDivider()

            // Toggle
            HStack {
                Text("AUTO-SAVE TO FILE")
                    .font(Brutal.label())
                    .foregroundColor(Brutal.text)
                Spacer()
                Toggle("", isOn: $fileExportEnabled)
                    .labelsHidden()
                    .tint(Brutal.muted)
                    .onChange(of: fileExportEnabled) { _, val in
                        AppConstants.sharedDefaults?.set(val, forKey: AppConstants.fileExportEnabledKey)
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Brutal.bg)
            BrutalDivider()

            if fileExportEnabled {
                // Folder picker
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SAVE LOCATION")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.muted)
                        Text(selectedFolderName.isEmpty ? String(localized: "Not set") : selectedFolderName)
                            .font(Brutal.label())
                            .foregroundColor(selectedFolderName.isEmpty ? Brutal.muted : Brutal.text)
                    }
                    Spacer()
                    Button("CHOOSE") {
                        showFolderPicker = true
                    }
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Brutal.bg)
                BrutalDivider()

                // Format picker
                HStack {
                    Text("FORMAT")
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                    Spacer()
                    Picker("", selection: $fileExportFormat) {
                        Text("TXT").tag(ExportFileFormat.txt)
                        Text("MD").tag(ExportFileFormat.md)
                        Text("JSON").tag(ExportFileFormat.json)
                        Text("YAML").tag(ExportFileFormat.yaml)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    .onChange(of: fileExportFormat) { _, val in
                        AppConstants.sharedDefaults?.set(val.rawValue, forKey: AppConstants.fileExportFormatKey)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Brutal.bg)

                if fileExportFormat == .md {
                    BrutalDivider()

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OBSIDIAN BASES")
                                .font(Brutal.label())
                                .foregroundColor(Brutal.text)
                            Text("All fields in YAML frontmatter, empty body")
                                .font(Brutal.caption())
                                .foregroundColor(Brutal.muted)
                        }
                        Spacer()
                        Toggle("", isOn: $mdObsidianEnabled)
                            .labelsHidden()
                            .tint(Brutal.muted)
                            .onChange(of: mdObsidianEnabled) { _, val in
                                AppConstants.sharedDefaults?.set(val, forKey: AppConstants.fileExportMDObsidianKey)
                            }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Brutal.bg)
                }

                BrutalDivider()

                // Mode picker
                HStack {
                    Text("MODE")
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                    Spacer()
                    Picker("", selection: $fileExportMode) {
                        Text("APPEND").tag(ExportFileMode.append)
                        Text("NEW FILE").tag(ExportFileMode.newFile)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .onChange(of: fileExportMode) { _, val in
                        AppConstants.sharedDefaults?.set(val.rawValue, forKey: AppConstants.fileExportModeKey)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Brutal.bg)

                BrutalDivider()

                if fileExportMode == .newFile {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("FILE NAME TEMPLATE")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.muted)

                        TextField("", text: $newFileNameTemplate)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .font(Brutal.label())
                            .foregroundColor(Brutal.text)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
                            .onChange(of: newFileNameTemplate) { _, val in
                                persistNewFileNameTemplate(val)
                            }

                        Text("TOKENS: {timestamp} {date} {time} {id8} {id} {model} {language}")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.muted)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Brutal.bg)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("APPEND FILE NAME")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.muted)

                        TextField("", text: $appendFileName)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .font(Brutal.label())
                            .foregroundColor(Brutal.text)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
                            .onChange(of: appendFileName) { _, val in
                                persistAppendFileName(val)
                            }

                        Text("Extension is added automatically")
                            .font(Brutal.caption())
                            .foregroundColor(Brutal.muted)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Brutal.bg)
                }

                if fileExportFormat == .yaml {
                    BrutalDivider()

                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("OBSIDIAN BASES")
                                    .font(Brutal.label())
                                    .foregroundColor(Brutal.text)
                                Text("Use .md extension for YAML files")
                                    .font(Brutal.caption())
                                    .foregroundColor(Brutal.muted)
                            }
                            Spacer()
                            Toggle("", isOn: $yamlObsidianBasesEnabled)
                                .labelsHidden()
                                .tint(Brutal.muted)
                                .onChange(of: yamlObsidianBasesEnabled) { _, val in
                                    persistYAMLObsidianBasesEnabled(val)
                                }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Brutal.bg)

                        BrutalDivider()

                        HStack {
                            Text("YAML PROPERTIES")
                                .font(Brutal.caption())
                                .foregroundColor(Brutal.muted)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Brutal.bg)

                        ForEach(ExportYAMLProperty.allCases, id: \.rawValue) { property in
                            HStack {
                                Text(property.displayName.uppercased())
                                    .font(Brutal.label())
                                    .foregroundColor(Brutal.text)
                                Spacer()
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { yamlProperties.contains(property) },
                                        set: { toggleYAMLProperty(property, enabled: $0) }
                                    )
                                )
                                .labelsHidden()
                                .tint(Brutal.muted)
                                .disabled(yamlProperties.count == 1 && yamlProperties.contains(property))
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Brutal.bg)

                            if property != ExportYAMLProperty.allCases.last {
                                BrutalDivider()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(spacing: 0) {
            sectionHeader("05", "About")
            BrutalDivider()

            let rows: [(String, String)] = [
                ("Whisper engine", "whisper.cpp"),
                ("Parakeet engine", "FluidAudio (CoreML)"),
                ("Processing", "On-device"),
                ("Privacy", "Zero data leaves device"),
            ]

            ForEach(rows, id: \.0) { key, val in
                HStack {
                    Text(key.uppercased())
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                    Spacer()
                    Text(val)
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.text)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Brutal.bg)
                BrutalDivider()
            }
        }
    }

    // MARK: - Feedback Section

    private var feedbackSection: some View {
        VStack(spacing: 0) {
            sectionHeader("06", "Feedback")
            BrutalDivider()

            Button(action: sendFeedback) {
                HStack {
                    Text("SEND FEEDBACK")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.text)
                    Spacer()
                    Text("→")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.muted)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Brutal.bg)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send Feedback")
            .accessibilityHint("Opens an email draft to contact support with app diagnostics")
        }
    }

    // MARK: - Debug Section

    private var debugSection: some View {
        VStack(spacing: 0) {
            sectionHeader("07", "Debug")
            BrutalDivider()

            Button {
                showDebugLog = true
            } label: {
                HStack {
                    Text("VIEW DEBUG LOG")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.text)
                    Spacer()
                    Text("→")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.muted)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Brutal.bg)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func sendFeedback() {
        let payload = FeedbackHelper.makePayload()

#if os(iOS)
        if FeedbackHelper.canSendMail {
            showMailCompose = true
            return
        }
#endif

        guard let url = FeedbackHelper.mailtoURL(payload: payload) else { return }
        openURL(url)
    }
}

// MARK: - Debug Log Viewer

private struct KeyboardDebugLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    Text(logText.isEmpty ? String(localized: "(empty)") : logText)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(Brutal.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("DEBUG LOG")
                        .font(Brutal.label(.headline))
                        .foregroundColor(Brutal.text)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("CLEAR") {
                        KeyboardDebugLog.shared.clear()
                        logText = String(localized: "(cleared)")
                    }
                    .font(Brutal.label())
                    .foregroundColor(Brutal.error)
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            logText = KeyboardDebugLog.shared.read()
                        } label: {
                            Text("↺")
                                .font(Brutal.label(.title3))
                                .foregroundColor(Brutal.muted)
                        }
                        .buttonStyle(.plain)
                        Button {
                            UIPasteboard.general.string = logText
                        } label: {
                            Text("COPY")
                                .font(Brutal.label())
                                .foregroundColor(Brutal.muted)
                        }
                        .buttonStyle(.plain)
                        Button("DONE") { dismiss() }
                            .font(Brutal.label())
                            .foregroundColor(Brutal.muted)
                            .buttonStyle(.plain)
                    }
                }
            }
            .toolbarBackground(Brutal.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear { logText = KeyboardDebugLog.shared.read() }
    }
}
