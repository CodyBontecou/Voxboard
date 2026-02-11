import SwiftUI
import VoxboardShared

/// Settings screen: model selection (download / select / delete) and language picker.
struct SettingsView: View {
    @Environment(ModelManager.self) private var modelManager
    @Environment(\.dismiss) private var dismiss
    @State private var showDebugLog = false

    var body: some View {
        @Bindable var mm = modelManager

        NavigationStack {
            List {
                modelSection
                languageSection
                debugSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showDebugLog) {
                KeyboardDebugLogView()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Models

    private var modelSection: some View {
        Section {
            ForEach(WhisperModelInfo.availableModels) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(model.name)
                                .font(.body)
                            if model.isBundled {
                                Text("Bundled")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(.systemGray5))
                                    .clipShape(Capsule())
                            }
                        }
                        Text(model.sizeLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    modelActionView(for: model)
                }
                .swipeActions(edge: .trailing) {
                    if model.isDownloaded && !model.isBundled {
                        Button("Delete", role: .destructive) {
                            modelManager.deleteModel(model)
                        }
                    }
                }
            }
        } header: {
            Text("Whisper Model")
        } footer: {
            Text("Larger models are more accurate but use more memory and take longer. The Tiny model is recommended for keyboard use.")
        }
    }

    @ViewBuilder
    private func modelActionView(for model: WhisperModelInfo) -> some View {
        if model.isDownloaded {
            if modelManager.selectedModelId == model.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: 20))
            } else {
                Button("Select") {
                    modelManager.selectedModelId = model.id
                }
                .buttonStyle(.borderless)
                .font(.system(size: 14, weight: .medium))
            }
        } else if modelManager.isDownloading[model.id] == true {
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView(value: modelManager.downloadProgress[model.id] ?? 0)
                    .frame(width: 80)
                let pct = Int((modelManager.downloadProgress[model.id] ?? 0) * 100)
                Text("\(pct)%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } else {
            Button {
                Task { await modelManager.downloadModel(model) }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Language

    private var languageSection: some View {
        Section("Language") {
            Picker("Transcription Language", selection: Binding(
                get: { modelManager.selectedLanguage },
                set: { modelManager.selectedLanguage = $0 }
            )) {
                ForEach(ModelManager.supportedLanguages, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
        }
    }

    // MARK: - Debug

    private var debugSection: some View {
        Section("Keyboard Debug") {
            Button {
                showDebugLog = true
            } label: {
                Label("View Keyboard Log", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Engine", value: "whisper.cpp")
            LabeledContent("Processing", value: "On-device")
            LabeledContent("Privacy", value: "No data leaves your device")
        }
    }
}

// MARK: - Debug Log Viewer

private struct KeyboardDebugLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(logText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .background(Color.black)
            .navigationTitle("Keyboard Debug Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        KeyboardDebugLog.shared.clear()
                        logText = "(cleared)"
                    }
                    .foregroundColor(.red)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            logText = KeyboardDebugLog.shared.read()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        Button {
                            UIPasteboard.general.string = logText
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            logText = KeyboardDebugLog.shared.read()
        }
    }
}
