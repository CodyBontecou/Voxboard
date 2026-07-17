import SwiftUI
import VoxboardShared

/// Download and select the on-device speech recognition model.
struct ModelTabView: View {
    @Environment(ModelManager.self) private var modelManager

    private var whisperModels: [WhisperModelInfo] {
        WhisperModelInfo.availableModels.filter { !$0.engine.isParakeet }
    }

    private var parakeetModels: [WhisperModelInfo] {
        WhisperModelInfo.availableModels.filter { $0.engine.isParakeet }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Geist.Spacing.eight) {
                header
                modelSection(title: "Whisper", description: "General-purpose multilingual models.", models: whisperModels)
                modelSection(title: "Parakeet", description: "Fast, optimized speech recognition models.", models: parakeetModels)
                languageSection
            }
            .padding(.horizontal, Geist.Spacing.four)
            .padding(.vertical, Geist.Spacing.six)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Geist.Palette.background200.ignoresSafeArea())
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Geist.Palette.background100, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.two) {
            Text("On-Device Models")
                .font(Geist.heading(.title))
                .tracking(-0.96)
                .foregroundStyle(Geist.text)
            Text("Choose the model Vox.md uses for transcription. Larger downloads can improve accuracy but need more memory and load more slowly.")
                .font(Geist.body())
                .foregroundStyle(Geist.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modelSection(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        models: [WhisperModelInfo]
    ) -> some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                Text(title)
                    .font(Geist.heading(.headline))
                    .foregroundStyle(Geist.text)
                Text(description)
                    .font(Geist.caption())
                    .foregroundStyle(Geist.muted)
            }

            VStack(spacing: 0) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    modelRow(for: model)
                    if index < models.count - 1 { GeistDivider() }
                }
            }
            .background(Geist.Palette.background100)
            .overlay(
                RoundedRectangle(cornerRadius: Geist.Radius.medium, style: .continuous)
                    .stroke(Geist.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.medium, style: .continuous))
        }
    }

    private func modelRow(for model: WhisperModelInfo) -> some View {
        HStack(alignment: .center, spacing: Geist.Spacing.four) {
            VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                HStack(spacing: Geist.Spacing.two) {
                    Text(model.name)
                        .font(Geist.label(.body))
                        .foregroundStyle(Geist.text)
                    if model.isBundled {
                        Text("Bundled")
                            .font(Geist.caption(.caption))
                            .foregroundStyle(Geist.muted)
                            .padding(.horizontal, Geist.Spacing.two)
                            .frame(height: 24)
                            .background(Geist.Palette.gray100)
                            .clipShape(Capsule())
                    }
                }

                Text(model.sizeLabel)
                    .font(Geist.mono())
                    .foregroundStyle(Geist.muted)

                if let modelDescription = model.modelDescription {
                    Text(modelDescription)
                        .font(Geist.caption())
                        .foregroundStyle(Geist.muted)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: Geist.Spacing.two)
            modelActionView(for: model)
        }
        .padding(Geist.Spacing.four)
        .frame(minHeight: 88)
    }

    @ViewBuilder
    private func modelActionView(for model: WhisperModelInfo) -> some View {
        if model.isDownloaded {
            HStack(spacing: Geist.Spacing.two) {
                if modelManager.selectedModelId == model.id {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .font(Geist.caption())
                        .foregroundStyle(Geist.Palette.blue900)
                        .padding(.horizontal, Geist.Spacing.three)
                        .frame(height: Geist.ControlHeight.small)
                        .background(Geist.Palette.blue100)
                        .clipShape(Capsule())
                } else {
                    Button("Select Model") {
                        modelManager.selectedModelId = model.id
                        OnboardingAnalyticsClient.shared.trackModelSetupCompleted(
                            metadata: OnboardingAnalyticsModelMetadata(model: model)
                        )
                    }
                    .buttonStyle(GeistButtonStyle(variant: .secondary, size: .small))
                    .frame(width: 104)
                }

                Button {
                    modelManager.deleteModel(model)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(GeistButtonStyle(variant: .tertiary, size: .small))
                .frame(width: Geist.ControlHeight.small)
                .accessibilityLabel("Delete \(model.name) model")
            }
        } else if modelManager.isDownloading[model.id] == true {
            downloadingView(for: model)
        } else {
            Button("Download Model") {
                modelManager.startDownload(model)
            }
            .buttonStyle(GeistButtonStyle(variant: .secondary, size: .small))
            .frame(width: 128)
        }
    }

    private func downloadingView(for model: WhisperModelInfo) -> some View {
        let progress = modelManager.downloadProgress[model.id] ?? 0
        return HStack(spacing: Geist.Spacing.two) {
            VStack(alignment: .trailing, spacing: Geist.Spacing.one) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Geist.Palette.blue700)
                    .frame(width: 88)
                Text("\(Int(progress * 100))%")
                    .font(Geist.mono())
                    .foregroundStyle(Geist.muted)
            }
            Button {
                modelManager.cancelDownload(model)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(GeistButtonStyle(variant: .tertiary, size: .small))
            .frame(width: Geist.ControlHeight.small)
            .accessibilityLabel("Cancel \(model.name) download")
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            Text("Transcription Language")
                .font(Geist.heading(.headline))
                .foregroundStyle(Geist.text)

            Group {
                if modelManager.selectedModel?.engine.isParakeet == true {
                    Text("Parakeet detects language automatically. Manual language hints are unavailable for this engine.")
                        .font(Geist.body())
                        .foregroundStyle(Geist.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .geistCard(padding: Geist.Spacing.four)
                } else {
                    Picker("Transcription Language", selection: Binding(
                        get: { modelManager.selectedLanguage },
                        set: { modelManager.selectedLanguage = $0 }
                    )) {
                        ForEach(modelManager.availableLanguages, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(Geist.body())
                    .tint(Geist.text)
                    .frame(maxWidth: .infinity, minHeight: Geist.ControlHeight.large, alignment: .leading)
                    .padding(.horizontal, Geist.Spacing.four)
                    .background(Geist.Palette.background100)
                    .overlay(
                        RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous)
                            .stroke(Geist.border, lineWidth: 1)
                    )
                }
            }
        }
    }
}
