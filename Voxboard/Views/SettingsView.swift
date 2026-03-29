import SwiftUI
import VoxboardShared

struct SettingsView: View {
    @Environment(ModelManager.self) private var modelManager
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(StoreManager.self) private var storeManager
    @Environment(\.dismiss) private var dismiss
    @State private var showDebugLog = false
    @State private var showPaywall = false

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
                        aboutSection
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
                        .font(Brutal.label(13))
                        .foregroundColor(Brutal.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("DONE") { dismiss() }
                        .font(Brutal.label(11))
                        .foregroundColor(Brutal.muted)
                        .buttonStyle(.plain)
                }
            }
            .toolbarBackground(Brutal.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $showDebugLog) {
                KeyboardDebugLogView()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
                    .environment(usageTracker)
                    .environment(storeManager)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Section Header

    private func sectionHeader(_ number: String, _ title: String) -> some View {
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
                            .font(Brutal.label(13))
                            .foregroundColor(Brutal.text)
                        Text("Lifetime access — no limits")
                            .font(Brutal.caption(10))
                            .foregroundColor(Brutal.faint)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Brutal.text)
                            .frame(width: 6, height: 6)
                        Text("PURCHASED")
                            .font(Brutal.caption(10))
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
                                .font(Brutal.label(13))
                                .foregroundColor(Brutal.text)
                            Text(String(format: "%.1f / 15 min free used", usageTracker.minutesUsed))
                                .font(Brutal.caption(10))
                                .foregroundColor(Brutal.faint)
                        }
                        Spacer()
                        Text(storeManager.displayPrice)
                            .font(Brutal.label(14))
                            .foregroundColor(Brutal.text)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    Button(action: { showPaywall = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.open.fill")
                                .font(.system(size: 11))
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
                .font(Brutal.caption(11))
                .foregroundColor(Brutal.faint)
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
                        .font(Brutal.label(13))
                        .foregroundColor(Brutal.text)
                    if model.isBundled {
                        Text("BUNDLED")
                            .font(Brutal.caption(9))
                            .foregroundColor(Brutal.faint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))
                    }
                }
                Text(model.sizeLabel.uppercased())
                    .font(Brutal.caption(10))
                    .foregroundColor(Brutal.faint)
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
                            .font(Brutal.caption(10))
                            .foregroundColor(Brutal.text)
                    }
                } else {
                    Button("SELECT") {
                        modelManager.selectedModelId = model.id
                    }
                    .font(Brutal.caption(10))
                    .foregroundColor(Brutal.muted)
                    .buttonStyle(.plain)
                }

                Button {
                    modelManager.deleteModel(model)
                } label: {
                    Text("DELETE")
                        .font(Brutal.caption(10))
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
                    .font(Brutal.caption(10))
                    .foregroundColor(Brutal.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))
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
                    .font(Brutal.caption(10))
                    .foregroundColor(Brutal.faint)
                    .monospacedDigit()
            }
            Button {
                modelManager.cancelDownload(model)
            } label: {
                Text("✕")
                    .font(Brutal.label(12))
                    .foregroundColor(Brutal.faint)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Language Section

    private var languageSection: some View {
        VStack(spacing: 0) {
            sectionHeader("03", "Language")
            BrutalDivider()

            Picker("Transcription Language", selection: Binding(
                get: { modelManager.selectedLanguage },
                set: { modelManager.selectedLanguage = $0 }
            )) {
                ForEach(ModelManager.supportedLanguages, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 140)
            .background(Brutal.bg)
            .tint(Brutal.text)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(spacing: 0) {
            sectionHeader("04", "About")
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
                        .font(Brutal.caption(11))
                        .foregroundColor(Brutal.faint)
                    Spacer()
                    Text(val)
                        .font(Brutal.caption(11))
                        .foregroundColor(Brutal.text)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Brutal.bg)
                BrutalDivider()
            }
        }
    }

    // MARK: - Debug Section

    private var debugSection: some View {
        VStack(spacing: 0) {
            sectionHeader("05", "Debug")
            BrutalDivider()

            Button {
                showDebugLog = true
            } label: {
                HStack {
                    Text("VIEW KEYBOARD LOG")
                        .font(Brutal.label(12))
                        .foregroundColor(Brutal.text)
                    Spacer()
                    Text("→")
                        .font(Brutal.label(12))
                        .foregroundColor(Brutal.faint)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Brutal.bg)
            }
            .buttonStyle(.plain)
        }
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
                    Text(logText.isEmpty ? "(empty)" : logText)
                        .font(.system(size: 10, design: .monospaced))
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
                    Text("KEYBOARD LOG")
                        .font(Brutal.label(12))
                        .foregroundColor(Brutal.text)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("CLEAR") {
                        KeyboardDebugLog.shared.clear()
                        logText = "(cleared)"
                    }
                    .font(Brutal.label(11))
                    .foregroundColor(Brutal.error)
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            logText = KeyboardDebugLog.shared.read()
                        } label: {
                            Text("↺")
                                .font(Brutal.label(16))
                                .foregroundColor(Brutal.muted)
                        }
                        .buttonStyle(.plain)
                        Button {
                            UIPasteboard.general.string = logText
                        } label: {
                            Text("COPY")
                                .font(Brutal.label(11))
                                .foregroundColor(Brutal.muted)
                        }
                        .buttonStyle(.plain)
                        Button("DONE") { dismiss() }
                            .font(Brutal.label(11))
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
