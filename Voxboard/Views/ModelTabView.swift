import SwiftUI
import VoxboardShared

// MARK: - ModelTabView

/// Tab 2 — download, select, and delete Whisper / Parakeet models;
/// also exposes the transcription language picker.
struct ModelTabView: View {
    @Environment(ModelManager.self) private var modelManager

    @State private var enrichmentEnabled: Bool = AppConstants.enrichmentEnabled

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
                    pageHeader
                    BrutalDivider()
                    whisperSection
                    BrutalDivider()
                    parakeetSection
                    BrutalDivider()
                    languageSection
                    BrutalDivider()
                    appleIntelligenceSection
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("MODEL")
                    .font(Brutal.label(.headline))
                    .foregroundColor(Brutal.text)
            }
        }
        .toolbarBackground(Brutal.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    // MARK: - Page header

    private var pageHeader: some View {
        Text("Download and select the speech recognition model used for transcription. Larger models are more accurate but require more memory and take longer to load.")
            .font(Brutal.caption())
            .foregroundColor(Brutal.muted)
            .lineSpacing(3)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brutal.bg)
    }

    // MARK: - Section header helper

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

    // MARK: - Whisper models

    private var whisperSection: some View {
        VStack(spacing: 0) {
            sectionHeader("01", "Whisper Models")
            BrutalDivider()
            ForEach(whisperModels) { model in
                modelRow(for: model)
                BrutalDivider()
            }
        }
    }

    // MARK: - Parakeet models

    private var parakeetSection: some View {
        VStack(spacing: 0) {
            sectionHeader("02", "Parakeet Models")
            BrutalDivider()
            ForEach(parakeetModels) { model in
                modelRow(for: model)
                BrutalDivider()
            }
        }
    }

    // MARK: - Language picker

    private var languageSection: some View {
        VStack(spacing: 0) {
            sectionHeader("03", "Language")
            BrutalDivider()

            if modelManager.selectedModel?.engine.isParakeet == true {
                footerNote("Parakeet currently auto-detects language in Voxboard. Manual language hints are not yet supported by the current engine API.")
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

    // MARK: - Apple Intelligence

    private var appleIntelligenceSection: some View {
        VStack(spacing: 0) {
            sectionHeader("04", "Apple Intelligence")
            BrutalDivider()

            if #available(iOS 26, *), FoundationModelsBackend.isAvailable {
                Text("Uses Apple's on-device foundation model to generate a title, tags, category, and cleaned-up text for each transcription. Runs privately on your device after a recording is saved.")
                    .font(Brutal.caption())
                    .foregroundColor(Brutal.muted)
                    .lineSpacing(3)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brutal.bg)
                BrutalDivider()

                HStack {
                    Text("ENRICH TRANSCRIPTIONS")
                        .font(Brutal.label())
                        .foregroundColor(Brutal.text)
                    Spacer()
                    Toggle("", isOn: $enrichmentEnabled)
                        .labelsHidden()
                        .tint(Brutal.muted)
                        .onChange(of: enrichmentEnabled) { _, val in
                            AppConstants.sharedDefaults?.set(val, forKey: AppConstants.enrichmentEnabledKey)
                        }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Brutal.bg)
            } else {
                footerNote("Apple Intelligence is unavailable on this device. Enrichment requires iOS 26 or later on a supported device with Apple Intelligence enabled in Settings.")
            }
        }
    }

    // MARK: - Row builders

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
                        OnboardingAnalyticsClient.shared.trackModelSetupCompleted(
                            metadata: OnboardingAnalyticsModelMetadata(model: model)
                        )
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
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Brutal.border).frame(height: 2)
                        Rectangle()
                            .fill(Brutal.text)
                            .frame(
                                width: geo.size.width * CGFloat(modelManager.downloadProgress[model.id] ?? 0),
                                height: 2
                            )
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

    // MARK: - Helpers

    private func footerNote(_ text: String) -> some View {
        Text(text)
            .font(Brutal.caption())
            .foregroundColor(Brutal.muted)
            .lineSpacing(3)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brutal.bg)
    }
}
