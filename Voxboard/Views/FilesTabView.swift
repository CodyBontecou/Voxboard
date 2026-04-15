import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

// MARK: - FilesTabView

/// Tab 3 — configure automatic transcript file export.
/// Mirrors the "File Export" section from the old SettingsView,
/// now promoted to a first-class destination.
struct FilesTabView: View {
    // MARK: Persisted state

    @State private var fileExportEnabled: Bool = {
        AppConstants.sharedDefaults?.bool(forKey: AppConstants.fileExportEnabledKey) ?? false
    }()

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

    @State private var yamlObsidianBasesEnabled: Bool = {
        AppConstants.sharedDefaults?.bool(forKey: AppConstants.fileExportYAMLObsidianBasesKey) ?? false
    }()

    @State private var mdObsidianEnabled: Bool = {
        AppConstants.sharedDefaults?.bool(forKey: AppConstants.fileExportMDObsidianKey) ?? false
    }()

    // Apple Intelligence enrichment toggles — only shown when the master
    // enrichment toggle is on and the device supports FoundationModels.
    @State private var exportUseEnrichedTitleInFilename: Bool = AppConstants.exportUseEnrichedTitleInFilename
    @State private var enrichedFilenameStyle: EnrichedFilenameStyle = AppConstants.exportEnrichedFilenameStyle
    @State private var exportUseCleanedText: Bool = AppConstants.exportUseCleanedText
    @State private var exportIncludeTags: Bool = AppConstants.exportIncludeTags

    @State private var selectedFolderName: String = {
        guard let data = AppConstants.sharedDefaults?.data(forKey: AppConstants.fileExportBookmarkKey),
              var isStale = Optional(false),
              let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else {
            return ""
        }
        return url.lastPathComponent
    }()

    @State private var showFolderPicker = false

    // Smart folder routing
    @State private var smartFoldersEnabled: Bool = AppConstants.smartFoldersEnabled
    @State private var smartFolders: [SmartFolder] = AppConstants.loadSmartFolders()
    @State private var showAddSmartFolderSheet = false

    // Auto-organize
    @State private var autoOrganizeEnabled: Bool = AppConstants.autoOrganizeEnabled

    // MARK: Body

    var body: some View {
        ZStack {
            Brutal.surface.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    mainSection
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("FILES")
                    .font(Brutal.label(.headline))
                    .foregroundColor(Brutal.text)
            }
        }
        .toolbarBackground(Brutal.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result)
        }
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

    // MARK: - Main section

    @ViewBuilder
    private var mainSection: some View {
        sectionHeader("01", "Auto-Save to File")
        BrutalDivider()

        // ── Enable toggle ──────────────────────────────────────────────────
        HStack {
            Text("ENABLED")
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

        if fileExportEnabled {
            BrutalDivider()
            folderPickerRow
            BrutalDivider()
            formatPickerRow
            if fileExportFormat == .md {
                BrutalDivider()
                mdObsidianSection
            }
            BrutalDivider()
            modePickerRow
            BrutalDivider()
            fileNameRow
            if fileExportFormat == .yaml {
                BrutalDivider()
                yamlOptionsSection
            }
            if #available(iOS 26, *), FoundationModelsBackend.isAvailable, AppConstants.enrichmentEnabled {
                BrutalDivider()
                enrichmentOptionsSection
            }
            if #available(iOS 26, *), FoundationModelsBackend.isAvailable {
                BrutalDivider()
                smartFoldersSection
            }
        }

        BrutalDivider()

        // Footer hint
        Text("Transcripts are saved automatically after each session ends.")
            .font(Brutal.caption())
            .foregroundColor(Brutal.muted)
            .lineSpacing(3)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brutal.bg)
    }

    // MARK: - Folder picker row

    private var folderPickerRow: some View {
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
            Button("CHOOSE") { showFolderPicker = true }
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
    }

    // MARK: - Format picker row

    private var formatPickerRow: some View {
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
    }

    // MARK: - Mode picker row

    private var modePickerRow: some View {
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
    }

    // MARK: - File name row

    @ViewBuilder
    private var fileNameRow: some View {
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
                        AppConstants.sharedDefaults?.set(val, forKey: AppConstants.fileExportNewFileNameTemplateKey)
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
                        AppConstants.sharedDefaults?.set(val, forKey: AppConstants.fileExportAppendFileNameKey)
                    }
                Text("Extension is added automatically")
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Brutal.bg)
        }
    }

    // MARK: - MD Obsidian section

    private var mdObsidianSection: some View {
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

    // MARK: - YAML options section

    private var yamlOptionsSection: some View {
        VStack(spacing: 0) {
            // Obsidian Bases toggle
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
                        AppConstants.sharedDefaults?.set(val, forKey: AppConstants.fileExportYAMLObsidianBasesKey)
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

    // MARK: - Apple Intelligence enrichment options

    private var enrichmentOptionsSection: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("APPLE INTELLIGENCE")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.text)
                    Text("Applies enrichment to your exported files.")
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Brutal.bg)

            BrutalDivider()

            enrichmentToggleRow(
                title: "ENRICHED FILENAME",
                subtitle: "Apply the generated title to the filename",
                isOn: $exportUseEnrichedTitleInFilename,
                key: AppConstants.exportUseEnrichedTitleInFilenameKey
            )

            if exportUseEnrichedTitleInFilename {
                BrutalDivider()
                HStack {
                    Text("FILENAME STYLE")
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                    Spacer()
                    Picker("", selection: $enrichedFilenameStyle) {
                        Text("PREFIX").tag(EnrichedFilenameStyle.prefix)
                        Text("FULL NAME").tag(EnrichedFilenameStyle.fullName)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .onChange(of: enrichedFilenameStyle) { _, val in
                        AppConstants.sharedDefaults?.set(val.rawValue, forKey: AppConstants.exportEnrichedFilenameStyleKey)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Brutal.bg)
            }

            BrutalDivider()
            enrichmentToggleRow(
                title: "REWRITTEN TRANSCRIPTION",
                subtitle: "Use the cleaned, punctuated text",
                isOn: $exportUseCleanedText,
                key: AppConstants.exportUseCleanedTextKey
            )
            BrutalDivider()
            enrichmentToggleRow(
                title: "INCLUDE TAGS",
                subtitle: "Append generated tags to the file",
                isOn: $exportIncludeTags,
                key: AppConstants.exportIncludeTagsKey
            )
            BrutalDivider()
            enrichmentToggleRow(
                title: "AUTO-ORGANIZE",
                subtitle: "AI creates subfolders under your export folder based on content",
                isOn: $autoOrganizeEnabled,
                key: AppConstants.autoOrganizeEnabledKey
            )
        }
    }

    private func enrichmentToggleRow(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        isOn: Binding<Bool>,
        key: String
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Brutal.label())
                    .foregroundColor(Brutal.text)
                Text(subtitle)
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Brutal.muted)
                .onChange(of: isOn.wrappedValue) { _, val in
                    AppConstants.sharedDefaults?.set(val, forKey: key)
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Brutal.bg)
    }

    // MARK: - Helpers

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

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
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
    }

    // MARK: - Smart Folders Section

    @available(iOS 26, *)
    private var smartFoldersSection: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SMART FOLDERS")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.text)
                    Text("AI routes each file to the best matching folder.")
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                }
                Spacer()
                Toggle("", isOn: $smartFoldersEnabled)
                    .labelsHidden()
                    .tint(Brutal.muted)
                    .onChange(of: smartFoldersEnabled) { _, val in
                        AppConstants.sharedDefaults?.set(val, forKey: AppConstants.smartFoldersEnabledKey)
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Brutal.bg)

            if smartFoldersEnabled {
                BrutalDivider()

                ForEach(smartFolders) { folder in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(folder.name.uppercased())
                                .font(Brutal.label())
                                .foregroundColor(Brutal.text)
                            Text(folder.folderDescription)
                                .font(Brutal.caption())
                                .foregroundColor(Brutal.muted)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button {
                            deleteSmartFolder(id: folder.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Brutal.muted)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Brutal.bg)

                    BrutalDivider()
                }

                Button {
                    showAddSmartFolderSheet = true
                } label: {
                    HStack {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("ADD FOLDER")
                            .font(Brutal.caption())
                    }
                    .foregroundColor(Brutal.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Brutal.bg)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showAddSmartFolderSheet) {
                    AddSmartFolderSheet { newFolder in
                        smartFolders.append(newFolder)
                        AppConstants.saveSmartFolders(smartFolders)
                    }
                }
            }
        }
    }

    @available(iOS 26, *)
    private func deleteSmartFolder(id: UUID) {
        smartFolders.removeAll { $0.id == id }
        AppConstants.saveSmartFolders(smartFolders)
    }
}

// MARK: - AddSmartFolderSheet

@available(iOS 26, *)
private struct AddSmartFolderSheet: View {
    let onAdd: (SmartFolder) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folderDescription = ""
    @State private var chosenFolderName: String = ""
    @State private var chosenBookmark: Data? = nil
    @State private var showFolderPicker = false

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !folderDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        chosenBookmark != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brutal.surface.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        BrutalDivider()
                        fieldRow(label: "NAME", placeholder: "e.g. App Development", text: $name)
                        BrutalDivider()
                        fieldRow(label: "DESCRIPTION", placeholder: "e.g. Notes and ideas about my iOS apps", text: $folderDescription)
                        BrutalDivider()
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("FOLDER")
                                    .font(Brutal.caption())
                                    .foregroundColor(Brutal.muted)
                                Text(chosenFolderName.isEmpty ? String(localized: "Not chosen") : chosenFolderName)
                                    .font(Brutal.label())
                                    .foregroundColor(chosenFolderName.isEmpty ? Brutal.muted : Brutal.text)
                            }
                            Spacer()
                            Button("CHOOSE") { showFolderPicker = true }
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
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("ADD SMART FOLDER")
                        .font(Brutal.label(.headline))
                        .foregroundColor(Brutal.text)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("CANCEL") { dismiss() }
                        .font(Brutal.caption())
                        .foregroundColor(Brutal.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("ADD") {
                        guard let bookmark = chosenBookmark else { return }
                        let folder = SmartFolder(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            folderDescription: folderDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                            bookmarkData: bookmark
                        )
                        onAdd(folder)
                        dismiss()
                    }
                    .font(Brutal.caption())
                    .foregroundColor(canAdd ? Brutal.text : Brutal.muted)
                    .disabled(!canAdd)
                }
            }
            .toolbarBackground(Brutal.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleFolderPick(result)
            }
        }
    }

    private func fieldRow(label: LocalizedStringKey, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(Brutal.caption())
                .foregroundColor(Brutal.muted)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.words)
                .font(Brutal.label())
                .foregroundColor(Brutal.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Brutal.bg)
    }

    private func handleFolderPick(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        if let bookmark = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            chosenBookmark = bookmark
            chosenFolderName = url.lastPathComponent
        }
    }
}
