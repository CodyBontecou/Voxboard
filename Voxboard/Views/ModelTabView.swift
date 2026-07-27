import SwiftUI
import VoxboardShared

/// Download and select the on-device speech recognition model.
struct ModelTabView: View {
    @Environment(ModelManager.self) private var modelManager
    @State private var automaticAvailability: SystemTranscriptionAvailability = .unavailable
    @State private var parakeetAutoStopEnabled = AppConstants.parakeetKeyboardAutoStopEnabled
    @State private var parakeetPauseDuration = AppConstants.parakeetKeyboardPauseDuration

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
                automaticSection
                modelSection(title: "Whisper", description: "Optional local models you can download and select explicitly.", models: whisperModels)
                modelSection(title: "Parakeet", description: "Optional optimized local models you can download and select explicitly.", models: parakeetModels)
                parakeetAutoStopSection
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
        .task(id: "\(modelManager.selectedModelId)|\(modelManager.selectedLanguage)|\(modelManager.installedModelsRevision)") {
            let service = AppTranscriptionServices.shared
            automaticAvailability = await service.availability(
                modelID: TranscriptionBackendID.automatic,
                language: modelManager.selectedLanguage
            )
            if modelManager.isAutomaticSelection, automaticAvailability == .supported {
                try? await service.prepare(
                    modelID: TranscriptionBackendID.automatic,
                    fallbackModelID: modelManager.preferredFallbackModelID,
                    language: modelManager.selectedLanguage
                )
                automaticAvailability = await service.availability(
                    modelID: TranscriptionBackendID.automatic,
                    language: modelManager.selectedLanguage
                )
            }
            if modelManager.isAutomaticSelection {
                let ready = await service.canTranscribe(
                    modelID: TranscriptionBackendID.automatic,
                    fallbackModelID: modelManager.preferredFallbackModelID,
                    language: modelManager.selectedLanguage
                )
                AppConstants.sharedDefaults?.set(ready, forKey: AppConstants.automaticBackendReadyKey)
            }
        }
        .onChange(of: parakeetAutoStopEnabled) { _, enabled in
            AppConstants.parakeetKeyboardAutoStopEnabled = enabled
        }
        .onChange(of: parakeetPauseDuration) { _, duration in
            AppConstants.parakeetKeyboardPauseDuration = duration
        }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.two) {
            Text("On-Device Models")
                .font(Geist.heading(.title))
                .tracking(-0.96)
                .foregroundStyle(Geist.text)
            Text("Automatic uses Apple Speech on supported iOS 26 devices. Whisper and Parakeet downloads are optional local overrides and fallbacks.")
                .font(Geist.body())
                .foregroundStyle(Geist.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var automaticSection: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                Text("Native")
                    .font(Geist.heading(.headline))
                    .foregroundStyle(Geist.text)
                Text("Uses Apple's system-managed, on-device speech recognizer when this device and language support it.")
                    .font(Geist.caption())
                    .foregroundStyle(Geist.muted)
            }

            HStack(alignment: .center, spacing: Geist.Spacing.four) {
                VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                    Text("Automatic")
                        .font(Geist.label(.body))
                        .foregroundStyle(Geist.text)
                    Text("System managed · No app model download")
                        .font(Geist.mono())
                        .foregroundStyle(Geist.muted)
                    Text("Falls back only to a model you have chosen to download.")
                        .font(Geist.caption())
                        .foregroundStyle(Geist.muted)
                    Label(automaticAvailabilityLabel, systemImage: automaticAvailabilityIcon)
                        .font(Geist.caption())
                        .foregroundStyle(automaticAvailability == .unavailable ? Geist.Palette.amber900 : Geist.muted)
                }
                Spacer(minLength: Geist.Spacing.two)
                if modelManager.isAutomaticSelection {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .font(Geist.caption())
                        .foregroundStyle(Geist.Palette.blue900)
                        .padding(.horizontal, Geist.Spacing.three)
                        .frame(height: Geist.ControlHeight.small)
                        .background(Geist.Palette.blue100)
                        .clipShape(Capsule())
                } else {
                    Button("Use Automatic") {
                        modelManager.selectAutomatic()
                        OnboardingAnalyticsClient.shared.trackModelSetupCompleted(
                            metadata: OnboardingAnalyticsModelMetadata(
                                engine: .appleSpeech,
                                sizeBucket: .unknown
                            )
                        )
                    }
                    .buttonStyle(GeistButtonStyle(variant: .secondary, size: .small))
                }
            }
            .padding(Geist.Spacing.four)
            .frame(minHeight: 88)
            .background(Geist.Palette.background100)
            .overlay(
                RoundedRectangle(cornerRadius: Geist.Radius.medium, style: .continuous)
                    .stroke(Geist.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.medium, style: .continuous))
        }
    }

    private var automaticAvailabilityLabel: String {
        switch automaticAvailability {
        case .ready: return "Apple Speech ready for this language"
        case .supported: return "Apple Speech available; system asset may need preparation"
        case .unavailable: return "Apple Speech unavailable; a downloaded fallback is required"
        }
    }

    private var automaticAvailabilityIcon: String {
        switch automaticAvailability {
        case .ready: return "checkmark.circle.fill"
        case .supported: return "arrow.down.circle"
        case .unavailable: return "exclamationmark.triangle"
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
        if modelManager.isModelDownloaded(model) {
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
                        modelManager.selectModel(model)
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

    private var parakeetAutoStopSection: some View {
        let modelID = VoiceActivityModelAsset.id
        let isDownloaded = modelManager.isVoiceActivityModelDownloaded
        let isDownloading = modelManager.isDownloading[modelID] == true
        let progress = modelManager.downloadProgress[modelID] ?? 0

        return VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                Text("Parakeet Keyboard Auto-Stop")
                    .font(Geist.heading(.headline))
                    .foregroundStyle(Geist.text)
                Text("A small local voice detector can stop a Parakeet keyboard recording after you finish speaking, so the transcript appears without a second mic tap.")
                    .font(Geist.caption())
                    .foregroundStyle(Geist.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Geist.Spacing.three) {
                HStack(spacing: Geist.Spacing.three) {
                    VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                        Text("Voice Pause Detection")
                            .font(Geist.label(.body))
                            .foregroundStyle(Geist.text)
                        Text(isDownloaded ? "Installed · Runs on device" : "Optional companion model · About 1 MB")
                            .font(Geist.mono())
                            .foregroundStyle(Geist.muted)
                    }
                    Spacer(minLength: Geist.Spacing.two)

                    if isDownloaded {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(Geist.caption())
                            .foregroundStyle(Geist.Palette.blue900)

                        Button {
                            modelManager.deleteVoiceActivityModel()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(GeistButtonStyle(variant: .tertiary, size: .small))
                        .frame(width: Geist.ControlHeight.small)
                        .accessibilityLabel("Delete voice pause detection model")
                    } else if isDownloading {
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
                            modelManager.cancelVoiceActivityDownload()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(GeistButtonStyle(variant: .tertiary, size: .small))
                        .frame(width: Geist.ControlHeight.small)
                        .accessibilityLabel("Cancel voice pause detection download")
                    } else {
                        Button("Download Auto-Stop") {
                            modelManager.startVoiceActivityDownload()
                        }
                        .buttonStyle(GeistButtonStyle(variant: .secondary, size: .small))
                    }
                }

                GeistDivider()

                Toggle("Stop Parakeet after a pause", isOn: $parakeetAutoStopEnabled)
                    .font(Geist.body())
                    .foregroundStyle(Geist.text)
                    .disabled(!isDownloaded)

                Picker("Pause Length", selection: $parakeetPauseDuration) {
                    Text("0.5 seconds").tag(0.5)
                    Text("0.75 seconds").tag(0.75)
                    Text("1 second").tag(1.0)
                    Text("1.5 seconds").tag(1.5)
                    Text("2 seconds").tag(2.0)
                }
                .pickerStyle(.menu)
                .font(Geist.body())
                .tint(Geist.text)
                .disabled(!isDownloaded || !parakeetAutoStopEnabled)

                Text(isDownloaded
                    ? "Applies only when Parakeet v2 or v3 is explicitly selected in the keyboard. Pause timing is approximate; Automatic and Whisper are unchanged."
                    : "Until this companion is downloaded, Parakeet keeps using manual stop.")
                    .font(Geist.caption())
                    .foregroundStyle(Geist.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Geist.Spacing.four)
            .background(Geist.Palette.background100)
            .overlay(
                RoundedRectangle(cornerRadius: Geist.Radius.medium, style: .continuous)
                    .stroke(Geist.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.medium, style: .continuous))
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
                    VStack(alignment: .leading, spacing: Geist.Spacing.two) {
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

                        if modelManager.isAutomaticSelection {
                            Text("System Language follows your device language. Choose a language explicitly when the recording uses another language.")
                                .font(Geist.caption())
                                .foregroundStyle(Geist.muted)
                        }
                    }
                }
            }
        }
    }
}
