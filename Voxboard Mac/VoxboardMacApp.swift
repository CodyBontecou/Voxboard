import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxboardShared

@main
struct VoxboardMacApp: App {
    @NSApplicationDelegateAdaptor(VoxboardMacAppDelegate.self) private var appDelegate
    @State private var modelManager = ModelManager()
    @State private var transcriptStore: TranscriptStore
    @State private var usageTracker: UsageTracker
    @State private var storeManager: MacStoreManager
    @State private var recorder: MacRecorder
    @AppStorage(MacAppVisibilityMode.storageKey, store: AppConstants.sharedDefaults)
    private var visibilityModeRaw = MacAppVisibilityMode.dockAndMenuBar.rawValue

    init() {
        let store = TranscriptStore()
        let usage = UsageTracker()
        let storeManager = MacStoreManager(usageTracker: usage)

        // Match the iOS app's on-device Apple Intelligence enrichment path on
        // macOS 26+ when Foundation Models is available for this Mac/user.
        let enricher: TranscriptEnricher?
        if #available(macOS 26, *), FoundationModelsBackend.isAvailable {
            enricher = TranscriptEnricher(backend: FoundationModelsBackend())
        } else {
            enricher = nil
        }

        let recorder = MacRecorder(
            transcriptStore: store,
            usageTracker: usage,
            transcriptEnricher: enricher
        )

        _transcriptStore = State(initialValue: store)
        _usageTracker = State(initialValue: usage)
        _storeManager = State(initialValue: storeManager)
        _recorder = State(initialValue: recorder)
    }

    private var visibilityMode: MacAppVisibilityMode {
        MacAppVisibilityMode(rawValue: visibilityModeRaw) ?? .dockAndMenuBar
    }

    private var menuBarVisibilityBinding: Binding<Bool> {
        Binding(
            get: { visibilityMode.showsMenuBar },
            set: { _ in /* read-only mirror of `visibilityMode` */ }
        )
    }

    var body: some Scene {
        WindowGroup("Voxboard", id: "main") {
            MacRootView(recorder: recorder)
                .environment(modelManager)
                .environment(transcriptStore)
                .environment(usageTracker)
                .environment(storeManager)
                .onAppear {
                    modelManager.copyBundledModelIfNeeded()
                    storeManager.start()
                    transcriptStore.reload()
                    usageTracker.reload()
                }
                .onChange(of: visibilityModeRaw) { _, _ in
                    visibilityMode.apply()
                }
        }
        .commands {
            CommandMenu("Voxboard") {
                Button("Reveal Data Folder") {
                    if let url = AppConstants.sharedContainerURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }

                Divider()

                Menu("Visibility") {
                    ForEach(MacAppVisibilityMode.allCases) { mode in
                        Button {
                            visibilityModeRaw = mode.rawValue
                            mode.apply()
                        } label: {
                            if visibilityMode == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                }
            }
        }

        MenuBarExtra(isInserted: menuBarVisibilityBinding) {
            MacMenuBarMenu(recorder: recorder)
                .environment(modelManager)
                .environment(transcriptStore)
                .environment(usageTracker)
                .environment(storeManager)
        } label: {
            Image(systemName: menuBarSymbolName)
                .help(menuBarStatusText)
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarSymbolName: String {
        if recorder.isRecording { return "record.circle.fill" }
        if recorder.isTranscribing { return "waveform.circle.fill" }
        return "mic.circle"
    }

    private var menuBarStatusText: String {
        if recorder.isRecording { return "Voxboard is recording" }
        if recorder.isTranscribing { return "Voxboard is transcribing" }
        return "Voxboard"
    }
}

enum MacAppVisibilityMode: String, CaseIterable, Identifiable {
    case dockAndMenuBar
    case menuBarOnly
    case dockOnly
    case hidden

    var id: String { rawValue }

    static let storageKey = "macAppVisibilityMode"

    var title: String {
        switch self {
        case .dockAndMenuBar: return "Dock + Menu Bar"
        case .menuBarOnly: return "Menu Bar Only"
        case .dockOnly: return "Dock Only"
        case .hidden: return "Hidden"
        }
    }

    var summary: String {
        switch self {
        case .dockAndMenuBar: return "Dock icon, Cmd-Tab, and menu bar"
        case .menuBarOnly: return "Menu bar only — hidden from Dock and Cmd-Tab"
        case .dockOnly: return "Dock icon and Cmd-Tab — no menu bar"
        case .hidden: return "Invisible — reopen from Spotlight or Finder"
        }
    }

    var systemImage: String {
        switch self {
        case .dockAndMenuBar: return "macwindow.on.rectangle"
        case .menuBarOnly: return "menubar.rectangle"
        case .dockOnly: return "dock.rectangle"
        case .hidden: return "eye.slash"
        }
    }

    var showsMenuBar: Bool {
        switch self {
        case .dockAndMenuBar, .menuBarOnly: return true
        case .dockOnly, .hidden: return false
        }
    }

    var activationPolicy: NSApplication.ActivationPolicy {
        switch self {
        case .dockAndMenuBar, .dockOnly: return .regular
        case .menuBarOnly, .hidden: return .accessory
        }
    }

    static var current: MacAppVisibilityMode {
        let raw = (AppConstants.sharedDefaults ?? .standard).string(forKey: storageKey) ?? ""
        return MacAppVisibilityMode(rawValue: raw) ?? .dockAndMenuBar
    }

    func apply() {
        let target = activationPolicy
        DispatchQueue.main.async {
            if NSApp.activationPolicy() != target {
                NSApp.setActivationPolicy(target)
            }
        }
    }

    func applyImmediately() {
        if NSApp.activationPolicy() != activationPolicy {
            NSApp.setActivationPolicy(activationPolicy)
        }
    }
}

final class VoxboardMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MacAppVisibilityMode.current.applyImmediately()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

private struct MacMenuBarMenu: View {
    @Environment(ModelManager.self) private var modelManager
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(TranscriptStore.self) private var transcriptStore
    @Environment(\.openWindow) private var openWindow

    @Bindable var recorder: MacRecorder
    @AppStorage(RecordingFlowStore.selectedFlowIdKey, store: AppConstants.sharedDefaults)
    private var selectedFlowId = RecordingFlowStore.generalId

    var body: some View {
        Text(statusTitle)
            .onAppear {
                usageTracker.reload()
                transcriptStore.reload()
            }

        if recorder.isRecording {
            Text("Recording: \(formatMenuDuration(recorder.recordingDuration))")
        } else if let error = recorder.lastError, !error.isEmpty {
            Text("Error: \(error)")
        } else if let modelName = modelManager.selectedModel?.name {
            Text("Model: \(modelName)")
        } else {
            Text("No model selected")
        }

        Divider()

        if recorder.isRecording {
            Button {
                recorder.stopAndTranscribe(modelManager: modelManager, flowId: selectedFlowId)
            } label: {
                Label("Stop + Transcribe", systemImage: "stop.fill")
            }
        } else {
            Button {
                beginRecording()
            } label: {
                Label(recordButtonTitle, systemImage: usageTracker.isAtLimit ? "lock.fill" : "mic.fill")
            }
            .disabled(recorder.isTranscribing)
        }

        Button {
            chooseImport()
        } label: {
            Label("Import Audio…", systemImage: "waveform")
        }
        .disabled(recorder.isRecording || recorder.isTranscribing || usageTracker.isAtLimit)

        if let result = recorder.lastTranscriptionResult, !result.isEmpty {
            Button {
                copyToPasteboard(result)
            } label: {
                Label("Copy Last Transcript", systemImage: "doc.on.doc")
            }
        }

        if let exportURL = recorder.lastExportURL {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([exportURL])
            } label: {
                Label("Reveal Last Export", systemImage: "folder")
            }
        }

        Divider()

        Picker("Vox", selection: $selectedFlowId) {
            ForEach(enabledFlows) { flow in
                Label(flow.displayName, systemImage: iconName(for: flow.symbolName))
                    .tag(flow.id)
            }
        }

        Button {
            showMainWindow()
        } label: {
            Label("Show Voxboard", systemImage: "macwindow")
        }
        .keyboardShortcut("0")

        Button {
            if let url = AppConstants.sharedContainerURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } label: {
            Label("Reveal Data Folder", systemImage: "externaldrive")
        }

        Divider()

        Button("Quit Voxboard") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var enabledFlows: [RecordingFlow] {
        let enabled = RecordingFlowStore.loadFlows().filter(\.isEnabled)
        return enabled.isEmpty ? RecordingFlowStore.defaultFlows : enabled
    }

    private var statusTitle: String {
        if recorder.isRecording { return "Voxboard — Recording" }
        if recorder.isTranscribing { return "Voxboard — Transcribing" }
        return "Voxboard — Ready"
    }

    private var recordButtonTitle: String {
        if usageTracker.isAtLimit { return "Unlock to Record" }
        if recorder.isTranscribing { return "Transcribing…" }
        return "Start Recording"
    }

    private func beginRecording() {
        guard !usageTracker.isAtLimit else {
            recorder.needsUnlock = true
            showMainWindow()
            return
        }

        Task { @MainActor in
            let granted = await AudioRecorder.requestMicrophonePermission()
            guard granted else {
                recorder.lastError = "Could not access the microphone. Check macOS Privacy & Security settings."
                showMainWindow()
                return
            }
            recorder.startRecording(modelManager: modelManager, flowId: selectedFlowId)
        }
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

    private func showMainWindow() {
        MacAppVisibilityMode.current.apply()
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func iconName(for symbolName: String) -> String {
        let trimmed = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "questionmark.square" : trimmed
    }

    private func formatMenuDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
